# =============================================================================
#  TcFltPkgMgr — WinGet Executor
#  Parallel SSH batch executor for WinGet package operations on Windows targets.
#  Mirrors Invoke-FltSshBatch but uses winget instead of tcpkg on the remote.
#
#  WinGet runs on the remote machine via SSH — the operator machine does NOT
#  need winget installed. The remote target must have winget in PATH.
#
#  Exit code mapping:
#    0             → OK
#    -1978335212   → Package not found in any configured source
#    -1978335189   → Package already installed (on install)
#    -1978335188   → No applicable upgrade available (on upgrade)
#    any other     → Failed (N)
# =============================================================================

# Map WinGet verb to the full remote command string.
# PackageSpec may be just an id (e.g. 'Notepad++.Notepad++') or an id with
# a version flag (e.g. 'Notepad++.Notepad++ --version 8.9.6.4').
# --disable-interactivity prevents winget from blocking on prompts over SSH.
function _Get-WinGetCommand {
    param([string]$Action, [string]$PackageSpec)

    # Split id from any embedded flags (e.g. --version X)
    $parts   = $PackageSpec -split '\s+--', 2
    $id      = $parts[0].Trim()
    $extra   = if ($parts.Count -gt 1) { " --$($parts[1].Trim())" } else { '' }

    $flags = '--silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    switch ($Action) {
        'install'   { "winget install --id $id$extra $flags" }
        'upgrade'   { "winget upgrade  --id $id$extra $flags" }
        'uninstall' { "winget uninstall --id $id --silent --disable-interactivity" }
        default     { "winget install --id $id$extra $flags" }
    }
}

# Map a WinGet exit code to a human-readable status string and note.
function _ConvertFrom-WinGetExitCode {
    param([int]$ExitCode, [string]$Action)
    switch ($ExitCode) {
        0           { return 'OK', '' }
        -1978335212 { return 'Failed', 'Package not found in any WinGet source' }
        -1978335189 { return 'Skipped', 'Already installed' }
        -1978335188 { return 'Skipped', 'No upgrade available' }
        default     { return "Failed ($ExitCode)", '' }
    }
}

# Execute a WinGet package action across multiple Windows targets via parallel SSH.
# Does not perform a feed pre-check — WinGet fetches from configured sources directly.
# Uses the same ConcurrentDictionary + OnProgress pattern as Invoke-FltSshBatch.
#
# Returns [BatchResult[]]
function Invoke-FltWinGetBatch {
    param(
        [FleetTarget[]] $Targets,
        [string]        $Action,           # 'install' | 'upgrade' | 'uninstall'
        [string]        $PackageSpec,      # WinGet package id, e.g. Microsoft.VisualStudioCode
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string]        $KeyFile           = '',
        [int]           $TimeoutSecs       = 0,    # 0 = use config default
        [int]           $ThrottleLimit     = 0,    # 0 = use config default
        [hashtable]     $InitialNotes      = $null,
        [scriptblock]   $OnProgress        = $null
    )

    if ($TimeoutSecs -le 0) {
        $TimeoutSecs = [int](Get-FltCfgValue 'ssh' 'timeoutSeconds' 1800)
    }
    if ($ThrottleLimit -le 0) {
        $ThrottleLimit = [int](Get-FltCfgValue 'ssh' 'throttleLimit' 25)
    }

    $remoteCmd  = _Get-WinGetCommand -Action $Action -PackageSpec $PackageSpec
    $useKey     = -not [string]::IsNullOrWhiteSpace($KeyFile)
    $statusDict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

    foreach ($t in $Targets) {
        $note = if ($InitialNotes -and $InitialNotes.ContainsKey($t.Name)) { $InitialNotes[$t.Name] } else { '' }
        [void]$statusDict.TryAdd($t.Name, "Pending|0|$note")
    }

    $jobs = $Targets | ForEach-Object -Parallel {
        $target      = $_
        $cmd         = $using:remoteCmd
        $cred        = $using:Credential
        $kf          = $using:KeyFile
        $useKey      = $using:useKey
        $timeoutSecs = $using:TimeoutSecs
        $dict        = $using:statusDict

        $started  = [datetime]::UtcNow
        $exitCode  = -1
        $errMsg    = ''
        $timedOut  = $false
        $cmdOutput = ''

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

            # Jitter to prevent simultaneous SSH connection bursts
            Start-Sleep -Milliseconds (Get-Random -Minimum 0 -Maximum 2000)

            # Retry on hosts.json file-lock (same pattern as SshExecutor)
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

            $existingEntry = $dict[$target.Name]
            $entryParts    = $existingEntry -split '\|', 3
            $existingNote  = if ($entryParts.Count -ge 3) { $entryParts[2] } else { '' }
            [void]$dict.TryUpdate($target.Name, "Running|0|$existingNote", $dict[$target.Name])

            try {
                $result   = Invoke-SSHCommand -SessionId $session.SessionId `
                                -Command $cmd -TimeOut $timeoutSecs
                $exitCode = $result.ExitStatus
                # Capture first line of output for error notes
                $cmdOutput = ($result.Output | Where-Object { $_ } | Select-Object -First 3) -join ' | '
            } finally {
                Remove-SSHSession -SessionId $session.SessionId | Out-Null
            }
        } catch {
            $errMsg   = $_.Exception.Message
            $timedOut = $errMsg -match 'timed out|TimeOut'
            $exitCode = -1
        }

        $duration = ([datetime]::UtcNow - $started).TotalSeconds

        # Map WinGet exit code to status and note
        if ($timedOut) {
            $status = 'Timed out'
            $note   = 'SSH closed; verify on target'
        } elseif ($exitCode -eq -1 -and $errMsg) {
            $status = 'Failed (-1)'
            $note   = ($errMsg -split "`n")[0].Trim()
        } else {
            # WinGet-specific exit code mapping
            $status = switch ($exitCode) {
                0           { 'OK' }
                -1978335212 { 'Skipped' }
                -1978335189 { 'Skipped' }
                -1978335188 { 'Skipped' }
                default     { "Failed ($exitCode)" }
            }
            $note = switch ($exitCode) {
                0           { '' }
                -1978335212 { 'Package not found in WinGet sources' }
                -1978335189 { 'Already installed' }
                -1978335188 { 'No upgrade available' }
                default     { if ($cmdOutput) { $cmdOutput } else { '' } }
            }
        }

        [void]$dict.TryUpdate($target.Name, "$status|$duration|$note", $dict[$target.Name])

        [pscustomobject]@{
            TargetName    = $target.Name
            Action        = $using:Action
            PackageSpec   = $using:PackageSpec
            PackageManager = 'winget'
            Status        = $status
            DurationSec   = $duration
            TimedOut      = $timedOut
            Note          = $note
        }
    } -ThrottleLimit $ThrottleLimit -AsJob

    # Poll the dict and invoke progress callback while jobs run
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