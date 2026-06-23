# =============================================================================
#  TcFltPkgMgr — Container Admin menu
#  Package, lifecycle, log, and health operations for Docker container targets.
#
#  Phase 8.2 — Invoke-ContainerAdminMenu (top-level, dashboard, routing)
#  Phase 8.3 — Package ops     (Invoke-ContainerInstallMenu, RemoveMenu)
#  Phase 8.4 — Image pull      (Invoke-ContainerPullMenu)
#  Phase 8.5 — Lifecycle ops   (Invoke-ContainerLifecycleMenu)
#  Phase 8.6 — Logs viewer     (Invoke-ContainerLogsMenu)
#  Phase 8.7 — Health check    (Invoke-ContainerHealthMenu)
# =============================================================================

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

# Returns SSH credentials, or a no-credential object when all selected targets
# use __local__ as their Docker host (so no SSH prompt appears for local ops).
function _Get-ContainerSshCreds {
    param([object[]]$Targets)
    $needSsh = @($Targets | Where-Object { $_.DockerHost -ne '__local__' })
    if ($needSsh.Count -eq 0) {
        return [pscustomobject]@{ Credential = $null; KeyFile = '' }
    }
    return Get-FleetSshCredential -Targets $Targets
}

function _Get-ContainerTargets {
    @($Script:FleetTargets | Where-Object { $_.TargetType -eq 'container' })
}

# Shared docker exec batch orchestration — mirrors _Invoke-AnsibleBatchAction
function _Invoke-DockerExecAction {
    param(
        [Parameter(Mandatory)] [string]      $Action,
        [Parameter(Mandatory)] [string]      $PackageSpec,
        [object[]]                           $PreSelected = @()
    )

    $containers = @(_Get-ContainerTargets)
    if ($containers.Count -eq 0) {
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    if ($PreSelected.Count -gt 0) {
        $selected = $PreSelected
    } else {
        Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
            "Action: $($Action.ToUpper())   Package: $PackageSpec",
            'Select targets — numbers, commas, or ranges (e.g. 11,12 or 11-13)'
        )
        $selected = @(Read-FltMultiSelect -Items $containers -Prompt 'Targets (11+)')
        if ($selected.Count -eq 0) { return }
    }

    Write-Host ''
    Write-Host "  $($Action.ToUpper()) '$PackageSpec' on $($selected.Count) container(s) via docker exec." `
        -ForegroundColor Cyan
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    $sshCreds = _Get-ContainerSshCreds -Targets $selected

    Show-FleetBatchDashboard -Targets $selected -Action $Action -PackageSpec $PackageSpec `
        -Mode 'docker exec' -TimeoutSecs 300

    $onProgress = {
        param($dict)
        foreach ($key in @($dict.Keys)) {
            $parts = ($dict[$key]) -split '\|', 3
            $st    = $parts[0]; $dur = [double]$parts[1]
            $note  = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            if ($Script:FltBatchStatus.ContainsKey($key)) {
                $cur = $Script:FltBatchStatus[$key].Status
                $cn  = $Script:FltBatchStatus[$key].Note
                if ($st -ne $cur -or $note -ne $cn) { Update-FltBatchRow $key $st $dur $note }
            }
        }
    }

    $results = Invoke-FltDockerExecBatch `
                   -Targets     $selected `
                   -Action      $Action `
                   -PackageSpec $PackageSpec `
                   -Credential  $sshCreds.Credential `
                   -KeyFile     $sshCreds.KeyFile `
                   -OnProgress  $onProgress `
                   -ReadOnly    $Script:FltReadOnly

    foreach ($r in $results) { Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note }

    $ok   = @($results | Where-Object { $_.Status -like 'OK*' }).Count
    $skip = @($results | Where-Object { $_.Status -like 'Skipped*' }).Count
    $fail = @($results | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Timed out' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    $sumStr = "  Complete: $ok OK  |  $skip skipped  |  $fail failed"
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}${sumStr}`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    Read-FltBatchNav
}

# Shared lifecycle batch orchestration — runs docker commands on the host
function _Invoke-DockerLifecycleAction {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pull','stop','start','restart','rm','run')]
        [string] $Action,
        [Parameter(Mandatory)] [string] $PackageSpec,
        [string] $DockerArgs   = '',
        [int]    $TimeoutSecs  = 120,
        [object[]] $PreSelected = @()
    )

    $containers = @(_Get-ContainerTargets)
    if ($containers.Count -eq 0) {
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    if ($PreSelected.Count -gt 0) {
        $selected = $PreSelected
    } else {
        Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
            "Action: docker $($Action.ToUpper())   Spec: $PackageSpec"
            'Select targets — numbers, commas, or ranges'
        )
        $selected = @(Read-FltMultiSelect -Items $containers -Prompt 'Targets (11+)')
        if ($selected.Count -eq 0) { return }
    }

    Write-Host ''
    Write-Host "  docker $($Action.ToUpper()) '$PackageSpec' on $($selected.Count) container(s)." `
        -ForegroundColor Cyan
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    $sshCreds = _Get-ContainerSshCreds -Targets $selected

    Show-FleetBatchDashboard -Targets $selected -Action $Action -PackageSpec $PackageSpec `
        -Mode 'docker lifecycle' -TimeoutSecs $TimeoutSecs

    # Capture DockerArgs for closure
    $capturedArgs = $DockerArgs

    $onProgress = {
        param($dict)
        foreach ($key in @($dict.Keys)) {
            $parts = ($dict[$key]) -split '\|', 3
            $st = $parts[0]; $dur = [double]$parts[1]
            $note = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            if ($Script:FltBatchStatus.ContainsKey($key)) {
                $cur = $Script:FltBatchStatus[$key].Status
                $cn  = $Script:FltBatchStatus[$key].Note
                if ($st -ne $cur -or $note -ne $cn) { Update-FltBatchRow $key $st $dur $note }
            }
        }
    }

    $results = Invoke-FltDockerLifecycleBatch `
                   -Targets     $selected `
                   -Action      $Action `
                   -PackageSpec $PackageSpec `
                   -DockerArgs  $capturedArgs `
                   -Credential  $sshCreds.Credential `
                   -KeyFile     $sshCreds.KeyFile `
                   -TimeoutSecs $TimeoutSecs `
                   -OnProgress  $onProgress `
                   -ReadOnly    $Script:FltReadOnly

    foreach ($r in $results) { Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note }

    $ok   = @($results | Where-Object { $_.Status -like 'OK*' }).Count
    $skip = @($results | Where-Object { $_.Status -like 'Skipped*' }).Count
    $fail = @($results | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Timed out' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    $sumStr = "  Complete: $ok OK  |  $skip skipped  |  $fail failed"
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}${sumStr}`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    Read-FltBatchNav
}

# ---------------------------------------------------------------------------
# Phase 8.10 — Compose-aware lifecycle helper
# ---------------------------------------------------------------------------

# Returns the absolute compose file path for a target, or '' if not set.
function _Get-TargetComposeFile {
    param([FleetTarget]$Target)
    if ([string]::IsNullOrEmpty($Target.ComposeFile)) { return '' }
    $abs = Join-Path $Script:FltScriptRoot $Target.ComposeFile
    if (Test-Path $abs) { return $abs }
    return ''
}

# Runs a compose or docker CLI lifecycle action across a selection of targets.
# Targets with ComposeFile set use docker compose; others use docker CLI directly.
# Verb mapping: start→start, stop→stop, restart→restart, pull→pull,
#               up→up -d, recreate→up -d --force-recreate
function _Invoke-ComposeOrDockerAction {
    param(
        [Parameter(Mandatory)][string]   $Verb,        # compose verb: start/stop/restart/pull/up
        [string]   $DockerVerb  = '',                  # docker CLI verb override (start/stop/restart/pull)
        [string]   $ExtraArgs   = '',
        [object[]] $Selected    = @(),
        [int]      $TimeoutSecs = 300
    )

    if ($Selected.Count -eq 0) { return }

    $composeTargets = @($Selected | Where-Object { -not [string]::IsNullOrEmpty($_.ComposeFile) })
    $directTargets  = @($Selected | Where-Object {      [string]::IsNullOrEmpty($_.ComposeFile) })

    $allResults = [System.Collections.Generic.List[object]]::new()

    # ── Compose path ──────────────────────────────────────────────────────────
    # Group by compose file so one `docker compose` call handles all services in that file
    if ($composeTargets.Count -gt 0) {
        $byFile = @{}
        foreach ($t in $composeTargets) {
            $absFile = _Get-TargetComposeFile -Target $t
            if (-not $absFile) {
                # Compose file missing — fall back to direct docker CLI
                $directTargets += $t
                continue
            }
            if (-not $byFile.ContainsKey($absFile)) { $byFile[$absFile] = @() }
            $byFile[$absFile] += $t
        }

        foreach ($absFile in $byFile.Keys) {
            $fileTargets = $byFile[$absFile]
            $services    = @($fileTargets | ForEach-Object { $_.ComposeService } | Where-Object { $_ })
            $project     = ($fileTargets[0]).ComposeProject
            if ([string]::IsNullOrEmpty($project)) {
                $project = [System.IO.Path]::GetFileNameWithoutExtension($absFile).ToLower() `
                           -replace '[^a-z0-9]',''
            }

            if ($Script:FltReadOnly) {
                foreach ($t in $fileTargets) {
                    $allResults.Add([pscustomobject]@{
                        TargetName = $t.Name; Status = 'Skipped'
                        Note = "[read-only] would run: docker compose $Verb $($t.ComposeService)"
                        DurationSec = 0; PackageManager = 'docker-lifecycle'
                    })
                }
                continue
            }

            $sw     = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-FltComposeCommand -ComposeFile $absFile -ProjectName $project `
                          -Verb $Verb -Services $services -ExtraArgs $ExtraArgs `
                          -TimeoutSecs $TimeoutSecs
            $sw.Stop()
            $dur = $sw.Elapsed.TotalSeconds

            foreach ($t in $fileTargets) {
                $allResults.Add([pscustomobject]@{
                    TargetName    = $t.Name
                    Status        = if ($result.Ok) { 'OK' } else { 'Failed' }
                    Note          = if ($result.Ok) { "compose $Verb" } else {
                                        ($result.Output -split "`n" | Select-Object -Last 2) -join ' ' }
                    DurationSec   = [math]::Round($dur, 1)
                    PackageManager = 'docker-lifecycle'
                })
                Update-FltBatchRow $t.Name `
                    (if ($result.Ok) { 'OK' } else { 'Failed' }) $dur `
                    (if ($result.Ok) { "compose $Verb" } else { 'See output' })
            }
        }
    }

    # ── Direct docker CLI path (no compose file) ──────────────────────────────
    if ($directTargets.Count -gt 0) {
        $cliVerb = if ($DockerVerb) { $DockerVerb } else { $Verb }
        $sshCreds = _Get-ContainerSshCreds -Targets $directTargets

        $results = Invoke-FltDockerLifecycleBatch `
                       -Targets     $directTargets `
                       -Action      $cliVerb `
                       -PackageSpec 'container' `
                       -DockerArgs  $ExtraArgs `
                       -Credential  $sshCreds.Credential `
                       -KeyFile     $sshCreds.KeyFile `
                       -TimeoutSecs $TimeoutSecs `
                       -ReadOnly    $Script:FltReadOnly

        foreach ($r in $results) {
            Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note
            $allResults.Add($r)
        }
    }

    return $allResults.ToArray()
}

# ---------------------------------------------------------------------------
# Phase 8.3 — Package operations
# ---------------------------------------------------------------------------

function Invoke-ContainerInstallMenu {
    Clear-Host
    Write-Host '  Containers  >  Install package' -ForegroundColor Cyan
    Write-Host ''
    $pkg = (Read-Host '  Package name to install (blank to cancel)').Trim()
    if ([string]::IsNullOrEmpty($pkg)) { return }
    $capturedPkg = $pkg
    _Invoke-DockerExecAction -Action 'install' -PackageSpec $capturedPkg
}

function Invoke-ContainerRemoveMenu {
    Clear-Host
    Write-Host '  Containers  >  Remove package' -ForegroundColor Cyan
    Write-Host ''
    $pkg = (Read-Host '  Package name to remove (blank to cancel)').Trim()
    if ([string]::IsNullOrEmpty($pkg)) { return }
    $capturedPkg = $pkg
    _Invoke-DockerExecAction -Action 'remove' -PackageSpec $capturedPkg
}

# ---------------------------------------------------------------------------
# Phase 8.4 — Image pull
# ---------------------------------------------------------------------------

function Invoke-ContainerPullMenu {
    Clear-Host
    Write-Host '  Containers  >  Pull image' -ForegroundColor Cyan
    Write-Host ''

    $containers = @(_Get-ContainerTargets)
    if ($containers.Count -eq 0) {
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    # Check if any targets have a compose file — if so, pull via compose (no image prompt needed)
    $composeCount = @($containers | Where-Object { -not [string]::IsNullOrEmpty($_.ComposeFile) }).Count
    $directCount  = @($containers | Where-Object {      [string]::IsNullOrEmpty($_.ComposeFile) }).Count

    $image = ''
    if ($directCount -gt 0) {
        Write-Host '  Some targets have no compose file — image name required for those.' -ForegroundColor DarkGray
        Write-Host ''
        $image = (Read-Host '  Image name/tag for non-compose targets (blank to skip direct pull)').Trim()
    }

    Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
        'Pull image — select targets', '- / + to page'
    )
    $selected = @(Read-FltMultiSelect -Items $containers -Prompt 'Targets (11+)')
    if ($selected.Count -eq 0) { return }

    if (-not (Read-FltYesNo -Prompt 'Pull images now?')) { return }

    Show-FleetBatchDashboard -Targets $selected -Action 'pull' -PackageSpec 'image' `
        -Mode 'docker lifecycle' -TimeoutSecs 300

    # Compose targets: docker compose pull (no image arg needed)
    # Direct targets: docker pull <image> — only if image was provided
    $composeSelected = @($selected | Where-Object { -not [string]::IsNullOrEmpty($_.ComposeFile) })
    $directSelected  = @($selected | Where-Object {      [string]::IsNullOrEmpty($_.ComposeFile) })

    if ($directSelected.Count -gt 0 -and [string]::IsNullOrEmpty($image)) {
        foreach ($t in $directSelected) {
            Update-FltBatchRow $t.Name 'Skipped' 0 'No image specified for direct pull'
        }
        $directSelected = @()
    }

    $capturedImage = $image
    $allResults = @(_Invoke-ComposeOrDockerAction -Verb 'pull' -DockerVerb 'pull' `
                        -ExtraArgs $capturedImage -Selected $selected -TimeoutSecs 300)

    $ok   = @($allResults | Where-Object { $_.Status -like 'OK*' }).Count
    $fail = @($allResults | Where-Object { $_.Status -like 'Failed*' }).Count
    $skip = @($allResults | Where-Object { $_.Status -like 'Skipped*' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}  Complete: $ok OK  |  $skip skipped  |  $fail failed`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    Read-FltBatchNav
}

# ---------------------------------------------------------------------------
# Phase 8.5 — Lifecycle operations
# ---------------------------------------------------------------------------

function Invoke-ContainerLifecycleMenu {
    param(
        [ValidateSet('start','stop','restart','recreate')]
        [string] $Action
    )

    Clear-Host
    Write-Host "  Containers  >  $($Action.Substring(0,1).ToUpper())$($Action.Substring(1))" `
        -ForegroundColor Cyan
    Write-Host ''

    if ($Action -eq 'recreate') {
        Write-Host '  Recreate stops, removes, and re-runs the container.' -ForegroundColor Yellow
        Write-Host '  You will be prompted for the docker run arguments.' -ForegroundColor DarkGray
        Write-Host ''
        $runArgs = (Read-Host '  docker run arguments (image + flags, blank to cancel)').Trim()
        if ([string]::IsNullOrEmpty($runArgs)) { return }
        $capturedRunArgs = $runArgs

        # Recreate = stop → rm → run
        $containers = @(_Get-ContainerTargets)
        if ($containers.Count -eq 0) {
            Write-Host '  No container targets configured.' -ForegroundColor Yellow
            Read-Host '  Press Enter'; return
        }
        Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
            'Recreate: stop → remove → run', 'Select targets')
        $selected = @(Read-FltMultiSelect -Items $containers -Prompt 'Targets (11+)')
        if ($selected.Count -eq 0) { return }

        Write-Host ''
        Write-Host "  Recreating $($selected.Count) container(s)." -ForegroundColor Cyan
        if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

        $sshCreds = _Get-ContainerSshCreds -Targets $selected
        foreach ($step in @('stop','rm')) {
            $capturedStep = $step
            $results = Invoke-FltDockerLifecycleBatch `
                           -Targets $selected -Action $capturedStep `
                           -PackageSpec 'container' `
                           -Credential $sshCreds.Credential -KeyFile $sshCreds.KeyFile `
                           -ReadOnly $Script:FltReadOnly
            $failed = @($results | Where-Object { $_.Status -notlike 'OK*' -and $_.Status -ne 'Skipped' })
            if ($failed.Count -gt 0) {
                Write-Host "  Warning: $($failed.Count) container(s) failed on '$capturedStep' step." `
                    -ForegroundColor Yellow
            }
        }
        # For compose targets, use force-recreate; for others, use docker run
        $capturedRunArgsLocal = $capturedRunArgs
        $composeRecreate = @($selected | Where-Object { -not [string]::IsNullOrEmpty($_.ComposeFile) })
        $directRecreate  = @($selected | Where-Object {      [string]::IsNullOrEmpty($_.ComposeFile) })

        if ($composeRecreate.Count -gt 0) {
            Show-FleetBatchDashboard -Targets $selected -Action 'recreate' -PackageSpec 'container' `
                -Mode 'docker lifecycle' -TimeoutSecs 300
            $allResults = @(_Invoke-ComposeOrDockerAction -Verb 'up' `
                                -ExtraArgs '-d --force-recreate' -Selected $composeRecreate -TimeoutSecs 300)
            foreach ($r in $allResults) { Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note }
        }
        if ($directRecreate.Count -gt 0) {
            _Invoke-DockerLifecycleAction -Action 'run' -PackageSpec 'container' `
                -DockerArgs $capturedRunArgsLocal -PreSelected $directRecreate
        }
        Read-FltBatchNav
        return
    }

    # start / stop / restart — use compose when available, docker CLI as fallback
    $capturedAction = $Action
    $containers = @(_Get-ContainerTargets)
    if ($containers.Count -eq 0) {
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }
    Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
        "Action: $($capturedAction.ToUpper())", 'Select targets'
    )
    $selected = @(Read-FltMultiSelect -Items $containers -Prompt 'Targets (11+)')
    if ($selected.Count -eq 0) { return }

    Write-Host ''
    Write-Host "  $($capturedAction.ToUpper()) $($selected.Count) container(s)." -ForegroundColor Cyan
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    Show-FleetBatchDashboard -Targets $selected -Action $capturedAction -PackageSpec 'container' `
        -Mode 'docker lifecycle' -TimeoutSecs 120

    $allResults = @(_Invoke-ComposeOrDockerAction -Verb $capturedAction `
                        -DockerVerb $capturedAction -Selected $selected -TimeoutSecs 120)

    foreach ($r in $allResults) { Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note }

    $ok   = @($allResults | Where-Object { $_.Status -like 'OK*' }).Count
    $fail = @($allResults | Where-Object { $_.Status -like 'Failed*' }).Count
    $skip = @($allResults | Where-Object { $_.Status -like 'Skipped*' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}  Complete: $ok OK  |  $skip skipped  |  $fail failed`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    Read-FltBatchNav
}

# ---------------------------------------------------------------------------
# Phase 8.6 — Logs viewer
# ---------------------------------------------------------------------------

function Invoke-ContainerLogsMenu {
    $containers = @(_Get-ContainerTargets)
    if ($containers.Count -eq 0) {
        Clear-Host
        Write-Host '  Containers  >  View logs' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    Clear-Host
    Write-Host '  Containers  >  View logs' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Select one container to view logs.' -ForegroundColor DarkGray
    Write-Host ''

    # Show numbered list of containers
    for ($i = 0; $i -lt $containers.Count; $i++) {
        $t = $containers[$i]
        Write-Host ("  {0,3}. {1,-20} {2,-20} {3}" -f (11+$i), $t.Name, $t.DockerHost, $t.ContainerName)
    }
    Write-Host ''
    Write-Host '    0. Cancel' -ForegroundColor DarkGray
    Write-Host ''

    $raw = (Read-Host '  Target number').Trim()
    if ($raw -eq '0' -or [string]::IsNullOrEmpty($raw)) { return }
    $num = 0
    if (-not [int]::TryParse($raw, [ref]$num) -or $num -lt 11 -or ($num - 11) -ge $containers.Count) {
        Write-Host '  Invalid selection.' -ForegroundColor Red
        Start-Sleep -Milliseconds 800; return
    }

    $target    = $containers[$num - 11]
    $hostTgt   = $Script:FleetTargets | Where-Object { $_.Name -eq $target.DockerHost } | Select-Object -First 1
    $tailLines = [int](Get-FltCfgValue 'docker' 'logTailLines' 50)

    if (-not $hostTgt) {
        Write-Host "  Docker host '$($target.DockerHost)' not found in fleet." -ForegroundColor Red
        Read-Host '  Press Enter'; return
    }

    $logArgs = "logs --tail $tailLines $($target.ContainerName)"

    Clear-Host
    Write-Host "  Logs: $($target.ContainerName) on $($target.DockerHost) (last $tailLines lines)" `
        -ForegroundColor Cyan
    Write-Host ('-' * ([Math]::Max([Console]::WindowWidth, 60) - 1)) -ForegroundColor DarkGray
    Write-Host ''

    try {
        if ($target.DockerHost -eq '__local__') {
            $result = _Invoke-FltDockerLocal -DockerArgs $logArgs
            $output = $result.Output -join "`n"
            if ([string]::IsNullOrWhiteSpace($output)) {
                Write-Host '  (no log output)' -ForegroundColor DarkGray
            } else {
                Write-Host $output
            }
        } else {
            if (-not (Ensure-FltPoshSsh)) {
                Write-Host '  Posh-SSH is not available.' -ForegroundColor Red
                Read-Host '  Press Enter'; return
            }
            $sshCreds  = Get-FleetSshCredential -Targets @($hostTgt)
            $sshParams = @{
                ComputerName = $hostTgt.Address
                Port         = [int]$hostTgt.Port
                AcceptKey    = $true
                ErrorAction  = 'Stop'
            }
            if ($sshCreds.KeyFile) {
                $sshParams['Username'] = $hostTgt.User
                $sshParams['KeyFile']  = $sshCreds.KeyFile
            } else {
                $sshParams['Credential'] = $sshCreds.Credential
            }
            $session = New-SSHSession @sshParams
            try {
                $result = Invoke-SSHCommand -SessionId $session.SessionId `
                              -Command "docker $logArgs" -TimeOut 30
                $output = $result.Output -join "`n"
                if ([string]::IsNullOrWhiteSpace($output)) {
                    Write-Host '  (no log output)' -ForegroundColor DarkGray
                } else {
                    Write-Host $output
                }
            } finally {
                Remove-SSHSession -SessionId $session.SessionId | Out-Null
            }
        }
    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host ('-' * ([Math]::Max([Console]::WindowWidth, 60) - 1)) -ForegroundColor DarkGray
    Read-Host '  Press Enter'
}

# ---------------------------------------------------------------------------
# Phase 8.7 — Health check
# ---------------------------------------------------------------------------

function Invoke-ContainerHealthMenu {
    $containers = @(_Get-ContainerTargets)
    if ($containers.Count -eq 0) {
        Clear-Host
        Write-Host '  Containers  >  Health check' -ForegroundColor Cyan
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    Clear-Host
    Write-Host '  Containers  >  Health check' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Querying Docker health status for all containers...' -ForegroundColor DarkGray
    Write-Host ''

    # Group containers by Docker host to minimise SSH connections
    $byHost = @{}
    foreach ($t in $containers) {
        if (-not $byHost.ContainsKey($t.DockerHost)) {
            $byHost[$t.DockerHost] = [System.Collections.Generic.List[object]]::new()
        }
        $byHost[$t.DockerHost].Add($t)
    }

    $results  = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($hostName in $byHost.Keys) {
        $hostContainers = $byHost[$hostName]
        $hostTgt = $Script:FleetTargets | Where-Object { $_.Name -eq $hostName } | Select-Object -First 1

        if (-not $hostTgt) {
            foreach ($t in $hostContainers) {
                $results.Add([pscustomobject]@{
                    Name = $t.Name; Container = $t.ContainerName
                    Host = $hostName; Health = 'host-not-found'
                })
            }
            continue
        }

        # Local Docker — run inspect directly without SSH
        if ($hostName -eq '__local__') {
            foreach ($t in $hostContainers) {
                $capturedName = $t.ContainerName
                try {
                    $res    = _Invoke-FltDockerLocal -DockerArgs "inspect --format={{.State.Health.Status}} $capturedName"
                    $health = ($res.Output -join '').Trim()
                    if ([string]::IsNullOrEmpty($health) -or $res.ExitStatus -ne 0) { $health = 'none' }
                } catch { $health = 'error' }
                $results.Add([pscustomobject]@{
                    Name = $t.Name; Container = $t.ContainerName; Host = $hostName; Health = $health
                })
            }
            continue
        }

        # Remote Docker host — get creds on demand and SSH
        $sshCreds = Get-FleetSshCredential -Targets @($hostTgt)
        $session  = $null
        try {
            $sshParams = @{
                ComputerName = $hostTgt.Address
                Port         = [int]$hostTgt.Port
                AcceptKey    = $true
                ErrorAction  = 'Stop'
            }
            if ($sshCreds.KeyFile) {
                $sshParams['Username']   = $hostTgt.User
                $sshParams['KeyFile']    = $sshCreds.KeyFile
            } else {
                $sshParams['Credential'] = $sshCreds.Credential
            }
            $session = New-SSHSession @sshParams
        } catch {
            foreach ($t in $hostContainers) {
                $results.Add([pscustomobject]@{
                    Name = $t.Name; Container = $t.ContainerName
                    Host = $hostName; Health = 'ssh-failed'
                })
            }
            continue
        }

        foreach ($t in $hostContainers) {
            $capturedName = $t.ContainerName
            $inspectCmd = "docker inspect --format={{.State.Health.Status}} $capturedName 2>/dev/null || echo 'none'"
            try {
                $res    = Invoke-SSHCommand -SessionId $session.SessionId `
                              -Command $inspectCmd -TimeOut 10
                $health = ($res.Output -join '').Trim()
                if ([string]::IsNullOrEmpty($health)) { $health = 'none' }
            } catch {
                $health = 'error'
            }
            $results.Add([pscustomobject]@{
                Name = $t.Name; Container = $t.ContainerName
                Host = $hostName; Health = $health
            })
        }

        if ($session) {
            try { Remove-SSHSession -SessionId $session.SessionId | Out-Null } catch {}
        }
    }

    # Display results table
    $sw = [Math]::Max([Console]::WindowWidth, 60) - 1
    Write-Host ('  {0,-20} {1,-20} {2,-20} {3}' -f 'Name','Host','Container','Health') `
        -ForegroundColor DarkGray
    Write-Host ("  " + '-' * ($sw - 2)) -ForegroundColor DarkGray

    foreach ($row in $results) {
        $clr = switch ($row.Health) {
            'healthy'   { 'Green'  }
            'unhealthy' { 'Red'    }
            'starting'  { 'Yellow' }
            'none'      { 'DarkGray' }
            default     { 'Red'    }
        }
        Write-Host ('  {0,-20} {1,-20} {2,-20} {3}' -f `
            $row.Name, $row.Host, $row.Container, $row.Health) -ForegroundColor $clr
    }

    Write-Host ''
    $healthy   = @($results | Where-Object { $_.Health -eq 'healthy'   }).Count
    $unhealthy = @($results | Where-Object { $_.Health -eq 'unhealthy' }).Count
    $none      = @($results | Where-Object { $_.Health -eq 'none'      }).Count
    Write-Host "  $healthy healthy  |  $unhealthy unhealthy  |  $none no healthcheck" `
        -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  Press Enter'
}

# ---------------------------------------------------------------------------
# Phase 8.2 — Container Admin top-level menu
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Phase 8.10 — Deploy (first-time container creation via docker compose up -d)
# ---------------------------------------------------------------------------

function Invoke-ContainerDeployMenu {
    Clear-Host
    Write-Host '  Containers  >  Deploy' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Deploy creates and starts containers that do not yet exist.' -ForegroundColor DarkGray
    Write-Host '  Only targets with a compose file can be deployed this way.' -ForegroundColor DarkGray
    Write-Host ''

    $containers = @(_Get-ContainerTargets | Where-Object {
        -not [string]::IsNullOrEmpty($_.ComposeFile)
    })

    if ($containers.Count -eq 0) {
        Write-Host '  No targets with compose files found.' -ForegroundColor Yellow
        Write-Host '  Add a container target using option 1 or 3 in the Add Target flow.' -ForegroundColor DarkGray
        Read-Host '  Press Enter'; return
    }

    Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
        'Deploy — docker compose up -d', 'Select targets to deploy'
    )
    $selected = @(Read-FltMultiSelect -Items $containers -Prompt 'Targets (11+)')
    if ($selected.Count -eq 0) { return }

    # Check if any need --build (debian-ssh uses a local Dockerfile)
    $needsBuild = $false
    foreach ($t in $selected) {
        $absFile = _Get-TargetComposeFile -Target $t
        if ($absFile) {
            $fileContent = Get-Content $absFile -Raw -ErrorAction SilentlyContinue
            if ($fileContent -match 'build:') { $needsBuild = $true; break }
        }
    }

    if ($needsBuild) {
        Write-Host ''
        Write-Host '  One or more compose files use a local build context (Dockerfile).' -ForegroundColor Yellow
        $buildChoice = Read-FltYesNo -Prompt 'Build images before starting? (required for first deploy)'
    } else {
        $buildChoice = $false
    }

    Write-Host ''
    Write-Host "  Deploying $($selected.Count) container(s)..." -ForegroundColor Cyan
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    Show-FleetBatchDashboard -Targets $selected -Action 'deploy' -PackageSpec 'container' `
        -Mode 'docker lifecycle' -TimeoutSecs 600

    # Group by compose file and run once per file
    $byFile = @{}
    foreach ($t in $selected) {
        $absFile = _Get-TargetComposeFile -Target $t
        if (-not $absFile) {
            Update-FltBatchRow $t.Name 'Skipped' 0 'No compose file — use Recreate instead'
            continue
        }
        if (-not $byFile.ContainsKey($absFile)) { $byFile[$absFile] = @() }
        $byFile[$absFile] += $t
    }

    $allResults = [System.Collections.Generic.List[object]]::new()

    foreach ($absFile in $byFile.Keys) {
        $fileTargets = $byFile[$absFile]
        $services    = @($fileTargets | ForEach-Object { $_.ComposeService } | Where-Object { $_ })
        $project     = ($fileTargets[0]).ComposeProject
        if ([string]::IsNullOrEmpty($project)) {
            $project = [System.IO.Path]::GetFileNameWithoutExtension($absFile).ToLower() `
                       -replace '[^a-z0-9]',''
        }

        if ($Script:FltReadOnly) {
            foreach ($t in $fileTargets) {
                $roResult = [pscustomobject]@{
                    TargetName    = $t.Name
                    Status        = 'Skipped'
                    Note          = "[read-only] would run: docker compose up -d $($t.ComposeService)"
                    DurationSec   = 0
                    PackageManager = 'docker-lifecycle'
                }
                $allResults.Add($roResult)
                Update-FltBatchRow $t.Name 'Skipped' 0 'Read-only mode'
            }
            continue
        }

        foreach ($t in $fileTargets) {
            Update-FltBatchRow $t.Name 'Running' 0 'docker compose up -d'
        }

        $extraArgs = '-d'
        if ($buildChoice) { $extraArgs += ' --build' }

        $sw     = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-FltComposeCommand -ComposeFile $absFile -ProjectName $project `
                      -Verb 'up' -Services $services -ExtraArgs $extraArgs -TimeoutSecs 600
        $sw.Stop()
        $dur = [math]::Round($sw.Elapsed.TotalSeconds, 1)

        foreach ($t in $fileTargets) {
            $status = if ($result.Ok) { 'OK' } else { 'Failed' }
            $errLine = $result.Output -split "`n" |
                       Where-Object { $_ -match 'Error|error' } |
                       Select-Object -Last 1
            $note   = if ($result.Ok) { 'deployed' } elseif ($errLine) { $errLine.Trim() } else { 'failed' }
            Update-FltBatchRow $t.Name $status $dur $note
            $allResults.Add([pscustomobject]@{
                TargetName    = $t.Name
                Status        = $status
                Note          = $note
                DurationSec   = $dur
                PackageManager = 'docker-lifecycle'
            })
        }
    }

    $ok   = @($allResults | Where-Object { $_.Status -like 'OK*' }).Count
    $fail = @($allResults | Where-Object { $_.Status -like 'Failed*' }).Count
    $skip = @($allResults | Where-Object { $_.Status -like 'Skipped*' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}  Complete: $ok OK  |  $skip skipped  |  $fail failed`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    Read-FltBatchNav
}

function Invoke-ContainerAdminMenu {
    $containers = @(_Get-ContainerTargets)

    if ($containers.Count -eq 0) {
        Clear-Host
        Write-Host '  Containers' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Write-Host '  Add a container target via Setup > Add target > 3. Docker container.' `
            -ForegroundColor DarkGray
        Write-Host ''
        Read-Host '  Press Enter'
        return
    }

    while ($true) {
        $containers = @(_Get-ContainerTargets)
        Clear-Host
        Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
            "Containers — $($containers.Count) container target(s)"
        )
        Write-Host ''
        Write-Host '  1. Install package   2. Remove package    3. Pull image' -ForegroundColor White
        Write-Host '  4. Start             5. Stop              6. Restart' -ForegroundColor White
        Write-Host '  7. Recreate          8. View logs         9. Health check' -ForegroundColor White
        Write-Host ' 10. Deploy            (docker compose up -d — first-time creation)' -ForegroundColor White
        Write-Host ''
        Write-Host '  0. Back' -ForegroundColor DarkGray
        Write-Host ''

        $choice = (Read-Host '  Choice').Trim()

        switch ($choice) {
            '1' { Invoke-ContainerInstallMenu }
            '2' { Invoke-ContainerRemoveMenu }
            '3' { Invoke-ContainerPullMenu }
            '4' { Invoke-ContainerLifecycleMenu -Action 'start'   }
            '5' { Invoke-ContainerLifecycleMenu -Action 'stop'    }
            '6' { Invoke-ContainerLifecycleMenu -Action 'restart' }
            '7' { Invoke-ContainerLifecycleMenu -Action 'recreate' }
            '8'  { Invoke-ContainerLogsMenu }
            '9'  { Invoke-ContainerHealthMenu }
            '10' { Invoke-ContainerDeployMenu }
            '0'  { return }
            default {
                Write-Host '  Enter 1-10 for an operation, 0 to go back.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 800
            }
        }
    }
}