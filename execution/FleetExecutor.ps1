# =============================================================================
#  TcFltPkgMgr — Fleet Executor
#  Orchestrates parallel SSH and sequential push-from-local execution.
#  The only file that decides which path each target takes.
#  Returns [BatchResult[]] for the UI to display.
# =============================================================================

# Check which targets in a list are missing a required feed.
# Uses Posh-SSH to query all targets in parallel.
# Returns a hashtable: TargetName -> $true (has feed) / $false (missing)
function Get-FltRemoteFeedStatus {
    param(
        [FleetTarget[]] $Targets,
        [string]        $FeedName,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string]        $KeyFile = ''
    )

    $result   = @{}
    $useKey   = -not [string]::IsNullOrWhiteSpace($KeyFile)
    $throttle = [int](Get-FltCfgValue 'ssh' 'throttleLimit' 25)
    # remoteTcpkgPath is the path to tcpkg on the REMOTE Windows target machine —
    # not the local operator machine. Safe to use even when operator runs on Linux.
    $remoteTcpkg = (Get-FltCfgValue 'tcpkg' 'remoteTcpkgPath' 'C:\ProgramData\Beckhoff\TcPkg\TcPkg.exe')

    # Bundle all variables into a single context object — avoids $using: scope
    # issues with ForEach-Object -Parallel inside a function
    $ctx = [pscustomobject]@{
        FeedName    = $FeedName
        Credential  = $Credential
        KeyFile     = $KeyFile
        UseKey      = $useKey
        RemoteTcpkg = $remoteTcpkg
    }

    $findings = $Targets | ForEach-Object -Parallel {
        $t       = $_
        $ctx     = $using:ctx
        $hasFlag = $false
        try {
            $sessionParams = @{
                ComputerName = $t.Address
                Port         = [int]$t.Port
                AcceptKey    = $true
                ErrorAction  = 'Stop'
            }
            if ($ctx.UseKey) {
                $sessionParams['Username'] = $t.User
                $sessionParams['KeyFile']  = $ctx.KeyFile
            } else {
                $sessionParams['Credential'] = $ctx.Credential
            }
            $session = New-SSHSession @sessionParams
            try {
                $cmd    = '"' + $ctx.RemoteTcpkg + '" source list --as-json'
                $result = Invoke-SSHCommand -SessionId $session.SessionId -Command $cmd -TimeOut 30
                $text   = $result.Output -join "`n"
                $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
                if ($s -ge 0 -and $e -gt $s) {
                    $json = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json
                    foreach ($src in $json) {
                        if ($src.Name -and $src.Name.ToLower() -eq $ctx.FeedName.ToLower()) {
                            $hasFlag = $true; break
                        }
                    }
                }
            } finally {
                Remove-SSHSession -SessionId $session.SessionId | Out-Null
            }
        } catch { $hasFlag = $false }

        [pscustomobject]@{ Name = $t.Name; HasFeed = $hasFlag }
    } -ThrottleLimit $throttle

    foreach ($f in $findings) { $result[$f.Name] = $f.HasFeed }
    return $result
}

# Execute a package action across multiple targets.
# Parallel SSH is the default for eligible targets (InternetAccess = True).
# Targets with InternetAccess = False fall back to sequential tcpkg -r push.
# For install/upgrade: if a target has InternetAccess = True but is missing the
# required feed, automatically sets InternetAccess = False (push from local)
# and restores it after the install.
#
# $OnProgress is an optional scriptblock called every 500ms with a
# [ConcurrentDictionary[string,string]] for dashboard integration.
function Invoke-FleetAction {
    param(
        [string]        $Action,           # install | upgrade | uninstall | repair
        [string]        $PackageSpec,      # e.g. twincat.standard.xae=4026.24.0
        [string]        $FeedName     = '', # Name of feed the package lives in (for pre-check)
        [FleetTarget[]] $Targets,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string]        $KeyFile           = '',
        [int]           $TimeoutSecs       = 0,   # 0 = use config default
        [scriptblock]   $OnProgress        = $null,
        [switch]        $ForceSequential   # skip SSH, always use tcpkg -r
    )

    if ($TimeoutSecs -le 0) {
        $TimeoutSecs = [int]((Get-FltCfgValue 'ssh' 'timeoutSeconds' 1800))
    }
    $throttle    = [int]((Get-FltCfgValue 'ssh' 'throttleLimit' 25))
    $remoteTcpkg = (Get-FltCfgValue 'tcpkg' 'remoteTcpkgPath' 'C:\ProgramData\Beckhoff\TcPkg\TcPkg.exe')
    $remoteCmd   = '"{0}" {1} {2} -y' -f $remoteTcpkg, $Action, $PackageSpec

    # ── Pre-planning: feed check + internet-access toggle ─────────────────────
    # For install/upgrade on targets with InternetAccess = True:
    # check if the required feed is present. If not, temporarily set
    # InternetAccess = False so the push path is used, then restore after.
    $restoreTargets = @()   # targets to restore InternetAccess = True after execution

    if ($Action -in @('install','upgrade') -and $FeedName) {
        # Mark all targets as 'checking' while parallel feed check runs
        foreach ($t in $Targets) {
            if ($t.InternetAccess) {
                Update-FltBatchRow $t.Name 'Checking feed...' 0 ''
            } else {
                Update-FltBatchRow $t.Name 'Pending' 0 'Push from local'
            }
        }

        # Parallel SSH feed check — only targets with InternetAccess = True
        $iaTargets = @($Targets | Where-Object { $_.InternetAccess })
        if ($iaTargets.Count -gt 0 -and (Ensure-FltPoshSsh)) {
            $feedStatus = Get-FltRemoteFeedStatus -Targets $iaTargets -FeedName $FeedName `
                              -Credential $Credential -KeyFile $KeyFile

            foreach ($t in $iaTargets) {
                $hasFeed = $feedStatus[$t.Name]
                if (-not $hasFeed) {
                    Update-FltBatchRow $t.Name 'Pending' 0 'No feed — switching to push'
                    Invoke-FltTcpkg -ArgList @('remote','edit',$t.Name,'--internet-access','False','-y') | Out-Null
                    if ($Script:FltLastExit -eq 0) {
                        $t.InternetAccess = $false
                        $restoreTargets  += $t.Name
                        Update-FltBatchRow $t.Name 'Pending' 0 'Push from local'
                    } else {
                        Update-FltBatchRow $t.Name 'Pending' 0 'Feed missing (SSH anyway)'
                    }
                } else {
                    Update-FltBatchRow $t.Name 'Pending' 0 'Feed OK'
                }
            }
        } elseif ($iaTargets.Count -gt 0) {
            # Posh-SSH not available — fall back to sequential tcpkg -r check
            foreach ($t in $iaTargets) {
                $raw  = Invoke-FltTcpkg -ArgList @('source','list','-r',$t.Name,'--as-json') -Silent
                $json = ConvertFrom-FltTcpkgJson $raw
                $hasFeed = $json -and ($json | Where-Object { $_.Name -and $_.Name.ToLower() -eq $FeedName.ToLower() })
                if (-not $hasFeed) {
                    Update-FltBatchRow $t.Name 'Pending' 0 'No feed — switching to push'
                    Invoke-FltTcpkg -ArgList @('remote','edit',$t.Name,'--internet-access','False','-y') | Out-Null
                    if ($Script:FltLastExit -eq 0) {
                        $t.InternetAccess = $false
                        $restoreTargets  += $t.Name
                        Update-FltBatchRow $t.Name 'Pending' 0 'Push from local'
                    } else {
                        Update-FltBatchRow $t.Name 'Pending' 0 'Feed missing (SSH anyway)'
                    }
                } else {
                    Update-FltBatchRow $t.Name 'Pending' 0 'Feed OK'
                }
            }
        }
    }

    # Split targets into three buckets by package manager:
    #   tcpkg SSH  — InternetAccess = True AND EffectivePackageManager = 'tcpkg'/'both'
    #   WinGet SSH — InternetAccess = True AND EffectivePackageManager = 'winget'/'both'
    #   Push       — InternetAccess = False (local tcpkg push, Windows/tcpkg only)
    if ($ForceSequential) {
        $tcpkgSshTargets  = @()
        $wingetSshTargets = @()
        $pushTargets      = @($Targets)
    } elseif ($Action -in @('install','upgrade')) {
        $iaTargets        = @($Targets | Where-Object { $_.InternetAccess })
        $tcpkgSshTargets  = @($iaTargets | Where-Object { (Get-FltEffectivePackageManager $_) -in @('tcpkg','both') })
        $wingetSshTargets = @($iaTargets | Where-Object { (Get-FltEffectivePackageManager $_) -in @('winget','both') })
        $pushTargets      = @($Targets   | Where-Object { -not $_.InternetAccess })
    } else {
        # uninstall/repair: no feed fetch needed — route by package manager
        $tcpkgSshTargets  = @($Targets | Where-Object { (Get-FltEffectivePackageManager $_) -in @('tcpkg','both') })
        $wingetSshTargets = @($Targets | Where-Object { (Get-FltEffectivePackageManager $_) -in @('winget','both') })
        $pushTargets      = @()
    }

    # Keep $sshTargets as union for backward-compat references below
    $sshTargets = @($tcpkgSshTargets) + @($wingetSshTargets)

    # Ensure push targets have a note if the feed check didn't already set one
    foreach ($t in $pushTargets) {
        $st = $Script:FltBatchStatus[$t.Name]
        if (-not $st -or -not $st.Note) {
            Update-FltBatchRow $t.Name 'Pending' 0 'Push from local'
        }
    }

    $allResults = [System.Collections.Generic.List[object]]::new()

    # ── tcpkg SSH bucket ──────────────────────────────────────────────────────
    if ($tcpkgSshTargets.Count -gt 0 -and -not $Script:FltReadOnly) {
        if (Ensure-FltPoshSsh) {
            $initialNotes = @{}
            foreach ($t in $tcpkgSshTargets) {
                $st = $Script:FltBatchStatus[$t.Name]
                if ($st -and $st.Note) { $initialNotes[$t.Name] = $st.Note }
            }
            foreach ($t in $tcpkgSshTargets) {
                $note = if ($initialNotes.ContainsKey($t.Name)) { $initialNotes[$t.Name] } else { '' }
                Update-FltBatchRow $t.Name 'Running (SSH)' 0 $note
            }

            $sshResults = Invoke-FltSshBatch `
                -Targets       $tcpkgSshTargets `
                -RemoteCommand $remoteCmd `
                -Action        $Action `
                -PackageSpec   $PackageSpec `
                -Credential    $Credential `
                -KeyFile       $KeyFile `
                -TimeoutSecs   $TimeoutSecs `
                -ThrottleLimit $throttle `
                -InitialNotes  $initialNotes `
                -OnProgress    $OnProgress

            foreach ($r in $sshResults) { $allResults.Add($r) }
        } else {
            # Posh-SSH not available — fall tcpkg SSH targets to push
            $pushTargets = @($pushTargets) + @($tcpkgSshTargets)
        }
    } elseif ($tcpkgSshTargets.Count -gt 0 -and $Script:FltReadOnly) {
        foreach ($t in $tcpkgSshTargets) {
            $r = [BatchResult]::new()
            $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
            $r.Status = '[read-only] would SSH (tcpkg)'; $r.DurationSec = 0
            $allResults.Add($r)
        }
    }

    # ── WinGet SSH bucket ─────────────────────────────────────────────────────
    if ($wingetSshTargets.Count -gt 0 -and -not $Script:FltReadOnly) {
        if (Ensure-FltPoshSsh) {
            $wgNotes = @{}
            foreach ($t in $wingetSshTargets) {
                $st = $Script:FltBatchStatus[$t.Name]
                if ($st -and $st.Note) { $wgNotes[$t.Name] = $st.Note }
            }
            foreach ($t in $wingetSshTargets) {
                $note = if ($wgNotes.ContainsKey($t.Name)) { $wgNotes[$t.Name] } else { '' }
                Update-FltBatchRow $t.Name 'Running (WinGet)' 0 $note
            }

            $wgResults = Invoke-FltWinGetBatch `
                -Targets       $wingetSshTargets `
                -Action        $Action `
                -PackageSpec   $PackageSpec `
                -Credential    $Credential `
                -KeyFile       $KeyFile `
                -TimeoutSecs   $TimeoutSecs `
                -ThrottleLimit $throttle `
                -InitialNotes  $wgNotes `
                -OnProgress    $OnProgress

            foreach ($r in $wgResults) { $allResults.Add($r) }
        } else {
            foreach ($t in $wingetSshTargets) {
                $r = [BatchResult]::new()
                $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
                $r.Status = 'Skipped'; $r.Note = 'Posh-SSH not available'
                $allResults.Add($r)
            }
        }
    } elseif ($wingetSshTargets.Count -gt 0 -and $Script:FltReadOnly) {
        foreach ($t in $wingetSshTargets) {
            $r = [BatchResult]::new()
            $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
            $r.Status = '[read-only] would SSH (winget)'; $r.DurationSec = 0
            $allResults.Add($r)
        }
    }

    # ── Sequential push bucket (tcpkg -r) ─────────────────────────────────────
    foreach ($t in $pushTargets) {
        $r = [BatchResult]::new()
        $r.TargetName  = $t.Name
        $r.Action      = $Action
        $r.PackageSpec = $PackageSpec

        if ($Script:FltReadOnly) {
            $r.Status = "[read-only] would push: tcpkg $Action $PackageSpec -r $($t.Name) -y"
            $allResults.Add($r)
            continue
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Preserve existing note (e.g. 'Push from local') when updating to Running
        $existingNote = if ($Script:FltBatchStatus[$t.Name]) { $Script:FltBatchStatus[$t.Name].Note } else { '' }

        # Notify progress callback that this target is running
        if ($OnProgress) {
            $tmpDict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
            [void]$tmpDict.TryAdd($t.Name, "Running (push)|0|$existingNote")
            & $OnProgress $tmpDict
        }

        Invoke-FltTcpkg -ArgList @($Action, $PackageSpec, '-r', $t.Name, '-y') -Silent | Out-Null
        $exitCode = $Script:FltLastExit
        $sw.Stop()

        $r.DurationSec = $sw.Elapsed.TotalSeconds
        $r.Status      = if ($exitCode -eq 0) { 'OK (push)' } else { "Failed ($exitCode)" }
        $r.Note        = $existingNote

        if ($OnProgress) {
            $tmpDict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
            [void]$tmpDict.TryAdd($t.Name, "$($r.Status)|$($r.DurationSec)|$existingNote")
            & $OnProgress $tmpDict
        }

        $allResults.Add($r)
    }

    # ── Restore Internet Access on targets that were temporarily switched ─────
    foreach ($tName in $restoreTargets) {
        $st = $Script:FltBatchStatus[$tName]
        Update-FltBatchRow $tName 'Restoring IA...' 0 $(if ($st) { $st.Note } else { '' })
        Invoke-FltTcpkg -ArgList @('remote','edit',$tName,'--internet-access','True','-y') | Out-Null
        if ($Script:FltLastExit -eq 0) {
            $st = $Script:FltBatchStatus[$tName]
            if ($st) { Update-FltBatchRow $tName $st.Status $st.Duration $st.Note }
        } else {
            $st = $Script:FltBatchStatus[$tName]
            if ($st) { Update-FltBatchRow $tName $st.Status $st.Duration 'WARNING: IA not restored' }
        }
    }

    return $allResults.ToArray()
}

# Collect SSH credentials from the user (shared password or key file).
# Returns a hashtable @{ Credential; KeyFile } or $null if cancelled.
function Get-FleetSshCredential {
    param([FleetTarget[]]$Targets)

    Write-Host ''
    Write-Host '  SSH credentials:' -ForegroundColor Cyan
    Write-Host '   1. Password (shared across all targets)'
    Write-Host '   2. Private key file'
    Write-Host '   0. Cancel'
    Write-Host ''
    $choice = (Read-Host '  Choice').Trim()
    if ($choice -eq '0') { return $null }

    if ($choice -eq '2') {
        $keyFile = (Read-Host '  Path to private key file (blank to cancel)').Trim()
        if (-not $keyFile) { return $null }
        $keyFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($keyFile)
        if (-not (Test-Path $keyFile)) {
            Write-Host "  Key file not found: $keyFile" -ForegroundColor Red
            return $null
        }
        return @{ Credential = $null; KeyFile = $keyFile }
    } else {
        $sampleUser = ($Targets | Select-Object -First 1).User
        Write-Host ("  Enter the SSH password for '{0}'." -f $sampleUser) -ForegroundColor Cyan
        Write-Host '  All selected targets must share this password.' -ForegroundColor DarkGray
        Write-Host ''
        $plain = (Read-Host "  Password for $sampleUser").Trim()
        $sec   = ConvertTo-SecureString $plain -AsPlainText -Force
        $cred  = [System.Management.Automation.PSCredential]::new($sampleUser, $sec)
        return @{ Credential = $cred; KeyFile = '' }
    }
}