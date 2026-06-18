# =============================================================================
#  TcFltPkgMgr — SSH Executor
#  Posh-SSH wrapper for parallel remote tcpkg execution.
#  Handles: jitter, hosts.json retry, timeout classification, status polling.
# =============================================================================

# Ensure Posh-SSH is installed and imported. Returns $true if ready.
function Ensure-FltPoshSsh {
    if ($Script:FltPoshSshAvailable) { return $true }
    if (Get-Module -Name Posh-SSH) { $Script:FltPoshSshAvailable = $true; return $true }

    if (-not (Get-Module -Name Posh-SSH -ListAvailable)) {
        Write-Host ''
        Write-Host '  Posh-SSH is required for parallel SSH mode.' -ForegroundColor Yellow
        Write-Host '  Install it once with: Install-Module Posh-SSH -Scope CurrentUser' -ForegroundColor Yellow
        $r = (Read-Host '  Install Posh-SSH now?  [1] Yes  [0] No  (default 0)').Trim()
        if ($r -ne '1') {
            Write-Host '  Parallel SSH not available.' -ForegroundColor Yellow
            return $false
        }
        try {
            Write-Host '  Installing Posh-SSH...' -ForegroundColor Cyan
            Install-Module Posh-SSH -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host '  Posh-SSH installed.' -ForegroundColor Green
        } catch {
            Write-Host ("  Install failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            return $false
        }
    }

    try {
        Import-Module Posh-SSH -ErrorAction Stop
        $Script:FltPoshSshAvailable = $true
        return $true
    } catch {
        Write-Host ("  Could not import Posh-SSH: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

# Execute a command on multiple remote targets simultaneously via SSH.
# Status updates are written to a ConcurrentDictionary; the caller polls it
# to update the UI. All Write-Host inside the parallel block is forbidden —
# only the dict is written.
#
# Returns [BatchResult[]]
function Invoke-FltSshBatch {
    param(
        [FleetTarget[]] $Targets,
        [string]        $RemoteCommand,    # the full command string to run on each remote
        [string]        $Action,           # 'install' | 'upgrade' | 'uninstall' | 'repair'
        [string]        $PackageSpec,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string]        $KeyFile           = '',
        [int]           $TimeoutSecs       = 1800,
        # ThrottleLimit controls how many parallel SSH connections are opened simultaneously.
        # Default matches ssh.throttleLimit in settings.default.json (25).
        # Values above 50 risk exhausting the operator machine's TCP connection pool,
        # particularly on Windows where ephemeral port exhaustion can occur under load.
        [int]           $ThrottleLimit     = 25,
        [hashtable]     $InitialNotes      = $null,   # TargetName -> note to preserve in dict
        # Optional callback: receives the ConcurrentDictionary and is called every 500ms.
        # Use this to update a dashboard. If $null, progress is silent.
        [scriptblock]   $OnProgress        = $null
    )

    $useKey      = -not [string]::IsNullOrWhiteSpace($KeyFile)
    $statusDict  = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

    foreach ($t in $Targets) {
        $note = if ($InitialNotes -and $InitialNotes.ContainsKey($t.Name)) { $InitialNotes[$t.Name] } else { '' }
        [void]$statusDict.TryAdd($t.Name, "Pending|0|$note")
    }

    $jobs = $Targets | ForEach-Object -Parallel {
        $target      = $_
        $cmd         = $using:RemoteCommand
        $cred        = $using:Credential
        $kf          = $using:KeyFile
        $useKey      = $using:useKey
        $timeoutSecs = $using:TimeoutSecs
        $dict        = $using:statusDict

        $started  = [datetime]::UtcNow
        $exitCode = -1
        $errMsg   = ''
        $timedOut = $false
        $output   = ''

        try {
            $sessionParams = @{
                ComputerName = $target.Address
                Port         = [int]$target.Port
                AcceptKey    = $true
                ErrorAction  = 'Stop'
            }
            if ($useKey) {
                $sessionParams['Username'] = $target.User
                $sessionParams['KeyFile']  = $kf
            } else {
                $sessionParams['Credential'] = $cred
            }

            # 0-2 s jitter to prevent simultaneous hosts.json writes
            Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum 2000)

            # Retry up to 3 times on hosts.json file-lock
            $session  = $null
            $attempts = 0
            while ($null -eq $session -and $attempts -lt 3) {
                $attempts++
                try {
                    $session = New-SSHSession @sessionParams
                } catch {
                    if ($_.Exception.Message -match 'hosts\.json|being used by another') {
                        if ($attempts -lt 3) {
                            Start-Sleep -Milliseconds (Get-Random -Minimum 500 -Maximum 1500)
                        } else { throw }
                    } else { throw }
                }
            }

            # Preserve existing note — use split not regex ($Matches is not thread-safe in parallel)
            $existingEntry = $dict[$target.Name]
            $entryParts    = $existingEntry -split '\|', 3
            $existingNote  = if ($entryParts.Count -ge 3) { $entryParts[2] } else { '' }
            [void]$dict.TryUpdate($target.Name, "Running|0|$existingNote", $dict[$target.Name])

            try {
                $result   = Invoke-SSHCommand -SessionId $session.SessionId `
                                -Command $cmd -TimeOut $timeoutSecs
                $output   = $result.Output -join "`n"
                $exitCode = $result.ExitStatus
            } finally {
                Remove-SSHSession -SessionId $session.SessionId | Out-Null
            }
        } catch {
            $errMsg   = $_.Exception.Message
            $timedOut = $errMsg -match 'timed out|TimeOut'
            $exitCode = -1
        }

        $duration = ([datetime]::UtcNow - $started).TotalSeconds
        $status   = if ($exitCode -eq 0)  { 'OK' }
                    elseif ($timedOut)     { 'Timed out' }
                    else                   { "Failed ($exitCode)" }
        # On success keep the existing note; on failure show the error
        $finalEntry    = $dict[$target.Name]
        $finalParts    = $finalEntry -split '\|', 3
        $existingNote2 = if ($finalParts.Count -ge 3) { $finalParts[2] } else { '' }
        $note     = if ($timedOut)         { 'SSH closed; verify on target' }
                    elseif ($exitCode -ne 0 -and $errMsg) {
                        ($errMsg -split "`n")[0].Trim()
                    } else { $existingNote2 }

        [void]$dict.TryUpdate($target.Name, "$status|$duration|$note", $dict[$target.Name])

        [pscustomobject]@{
            TargetName     = $target.Name
            Action         = $using:Action
            PackageSpec    = $using:PackageSpec
            PackageManager = 'tcpkg'
            Status         = $status
            DurationSec    = $duration
            TimedOut       = $timedOut
            Output         = $output
            Note           = $note
        }
    } -ThrottleLimit $ThrottleLimit -AsJob

    # Main thread: poll the dict and invoke the progress callback
    while ($jobs.State -eq 'Running') {
        if ($OnProgress) { & $OnProgress $statusDict }
        Start-Sleep -Milliseconds 500
    }
    if ($OnProgress) { & $OnProgress $statusDict }   # final pass

    $rawResults = @($jobs | Receive-Job)
    Remove-Job $jobs

    # Build typed BatchResult[]
    return @($rawResults | ForEach-Object {
        $r = [BatchResult]::new()
        $r.TargetName      = $_.TargetName
        $r.Action          = $_.Action
        $r.PackageSpec     = $_.PackageSpec
        $r.PackageManager  = $_.PackageManager
        $r.Status          = $_.Status
        $r.DurationSec     = $_.DurationSec
        $r.TimedOut        = $_.TimedOut
        $r.Note            = $_.Note
        $r
    })
}