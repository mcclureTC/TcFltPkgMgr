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
        [int]      $TimeoutSecs = 300,
        [object]   $PreGatheredCreds = $null           # credentials gathered before batch dashboard
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
        $cliVerb  = if ($DockerVerb) { $DockerVerb } else { $Verb }
        $sshCreds = if ($PreGatheredCreds) { $PreGatheredCreds } `
                    else { _Get-ContainerSshCreds -Targets $directTargets }

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

    # Gather SSH credentials BEFORE showing the batch dashboard
    $pullSshCreds = _Get-ContainerSshCreds -Targets $selected

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
                        -ExtraArgs $capturedImage -Selected $selected -TimeoutSecs 300 `
                        -PreGatheredCreds $pullSshCreds)

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

    # Gather credentials BEFORE showing batch dashboard
    $lifecycleCreds = _Get-ContainerSshCreds -Targets $selected

    Show-FleetBatchDashboard -Targets $selected -Action $capturedAction -PackageSpec 'container' `
        -Mode 'docker lifecycle' -TimeoutSecs 120

    $allResults = @(_Invoke-ComposeOrDockerAction -Verb $capturedAction `
                        -DockerVerb $capturedAction -Selected $selected -TimeoutSecs 120 `
                        -PreGatheredCreds $lifecycleCreds)

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

# ---------------------------------------------------------------------------
# Phase 8.12 — Remove container (docker rm -f)
# ---------------------------------------------------------------------------

function Invoke-ContainerRemoveContainerMenu {
    Clear-Host
    Write-Host '  Containers  >  Remove container' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Stops and permanently deletes the selected container(s).' -ForegroundColor DarkGray
    Write-Host '  The fleet target registration is NOT removed — do that via Setup if needed.' -ForegroundColor DarkGray
    Write-Host ''

    $containers = @(_Get-ContainerTargets)
    if ($containers.Count -eq 0) {
        Write-Host '  No container targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    Show-FleetDashboard -Targets $containers -LastCommand '' -ResultLines @(
        'Remove container — select targets', '- / + to page'
    )
    $selected = @(Read-FltMultiSelect -Items $containers -Prompt 'Targets (11+)')
    if ($selected.Count -eq 0) { return }

    Write-Host ''
    Write-Host "  This will PERMANENTLY DELETE $($selected.Count) container(s)." -ForegroundColor Yellow
    Write-Host '  The Docker image will NOT be deleted.' -ForegroundColor DarkGray
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    # Gather credentials before batch dashboard
    $rmCreds = _Get-ContainerSshCreds -Targets $selected

    Show-FleetBatchDashboard -Targets $selected -Action 'remove' -PackageSpec 'container' `
        -Mode 'docker lifecycle' -TimeoutSecs 60

    $allResults = @(_Invoke-ComposeOrDockerAction -Verb 'rm' -DockerVerb 'rm' `
                        -ExtraArgs '-f' -Selected $selected -TimeoutSecs 60 `
                        -PreGatheredCreds $rmCreds)

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

    # Offer to remove fleet target registrations for successfully removed containers
    $removed = @($allResults | Where-Object { $_.Status -like 'OK*' })
    if ($removed.Count -gt 0) {
        Write-Host ''
        if (Read-FltYesNo -Prompt "Also remove $($removed.Count) fleet target registration(s)?") {
            foreach ($r in $removed) {
                $t = $Script:FleetTargets | Where-Object { $_.Name -eq $r.TargetName }
                if ($t) {
                    Remove-FleetTarget -Name $r.TargetName | Out-Null
                    Write-Host "  Removed fleet target: $($r.TargetName)" -ForegroundColor DarkGray
                }
            }
            $Script:FleetTargets = @(Get-FleetTargets -Silent)
            Write-Host '  Fleet targets updated.' -ForegroundColor Green
        }
    }
    Read-Host '  Press Enter'
}

# ---------------------------------------------------------------------------
# Phase 8.11 — Build image and run container on a remote Docker host
# ---------------------------------------------------------------------------

function Invoke-ContainerRemoteBuildMenu {
    Clear-Host
    Write-Host '  Containers  >  Build + Run on remote host' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Builds a Docker image on a remote Linux Docker host via SSH,' -ForegroundColor DarkGray
    Write-Host '  then starts a container from that image.' -ForegroundColor DarkGray
    Write-Host ''

    # ── 1. Select a Linux fleet target as the Docker host ─────────────────────
    $linuxHosts = @($Script:FleetTargets | Where-Object {
        $_.OS -eq 'linux' -and $_.TargetType -ne 'container' -and
        $_.Address -and $_.Address -ne '__local__'
    })

    if ($linuxHosts.Count -eq 0) {
        Write-Host '  No Linux targets configured as Docker hosts.' -ForegroundColor Yellow
        Write-Host '  Add a Linux VM target first (Setup > Add target).' -ForegroundColor DarkGray
        Read-Host '  Press Enter'; return
    }

    Write-Host '  Available Docker hosts:' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $linuxHosts.Count; $i++) {
        Write-Host "   $($i+1). $($linuxHosts[$i].Name)  ($($linuxHosts[$i].Address))"
    }
    Write-Host '   0. Cancel'
    Write-Host ''
    $hostChoice = (Read-Host '  Docker host').Trim()
    if ($hostChoice -eq '0' -or [string]::IsNullOrEmpty($hostChoice)) { return }
    $hostIdx = [int]$hostChoice - 1
    if ($hostIdx -lt 0 -or $hostIdx -ge $linuxHosts.Count) {
        Write-Host '  Invalid selection.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }
    $dockerHost = $linuxHosts[$hostIdx]

    # ── 2. Connect to remote host ────────────────────────────────────────────
    $pwd = Get-FltStoredPassword -CredentialName $dockerHost.Name
    if (-not $pwd) {
        $pwd = (Read-Host "  Password for $($dockerHost.User)@$($dockerHost.Name)").Trim()
    }
    if (-not $pwd) { Write-Host '  No credential.' -ForegroundColor Red; Read-Host '  Press Enter'; return }
    $sec  = ConvertTo-SecureString $pwd -AsPlainText -Force
    $cred = [System.Management.Automation.PSCredential]::new($dockerHost.User, $sec)

    Write-Host ''
    Write-Host "  Connecting to $($dockerHost.Name)..." -ForegroundColor DarkGray
    $sessParams2 = @{
        ComputerName = $dockerHost.Address
        Port         = $dockerHost.Port
        Credential   = $cred
        AcceptKey    = $true
        ErrorAction  = 'Stop'
    }
    $session = $null
    try {
        $session = New-SSHSession @sessParams2
    } catch {
        Write-Host "  SSH failed: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host '  Press Enter'; return
    }
    $sid = $session.SessionId
    Write-Host "  Connected (session $sid)" -ForegroundColor DarkGray

    # Get DNS for container networking
    $dnsResult2 = Invoke-SSHCommand -SessionId $sid -Command "resolvectl status 2>/dev/null | grep -m1 'DNS Servers' | awk '{print \$3}' || echo ''"
    $dnsServer2 = ($dnsResult2.Output -join '').Trim()
    $dnsFlags   = if ($dnsServer2 -and $dnsServer2 -notmatch '^127\.') { "--dns $dnsServer2" } else { '' }

    # ── 3. Choose image source ────────────────────────────────────────────────
    Write-Host ''
    Write-Host '  Image source:' -ForegroundColor Cyan
    Write-Host '   1. Build from Dockerfile'
    Write-Host '   2. Use existing local image (already built on this host)'
    Write-Host '   0. Cancel'
    Write-Host ''
    $srcChoice = (Read-Host '  Choice').Trim()
    if ($srcChoice -eq '0') { return }

    if ($srcChoice -eq '2') {
        # ── Use existing image — skip build ────────────────────────────────
        $listResult = Invoke-SSHCommand -SessionId $sid -Command 'docker images --format "{{.Repository}}:{{.Tag}}" 2>&1'
        $images = @($listResult.Output | Where-Object { $_ -and $_ -notmatch '<none>' })
        if ($images.Count -eq 0) {
            Write-Host '  No local images found on this host.' -ForegroundColor Yellow
            Read-Host '  Press Enter'; return
        }
        Write-Host '  Available images:'
        for ($i = 0; $i -lt $images.Count; $i++) {
            Write-Host ("   $($i+1). $($images[$i])")
        }
        Write-Host '   0. Cancel'
        Write-Host ''
        $imgChoice = (Read-Host '  Image').Trim()
        if ($imgChoice -eq '0') { return }
        $imgIdx = [int]$imgChoice - 1
        if ($imgIdx -lt 0 -or $imgIdx -ge $images.Count) {
            Write-Host '  Invalid selection.' -ForegroundColor Yellow
            Read-Host '  Press Enter'; return
        }
        $imageName = $images[$imgIdx]

        # Get container config
        Write-Host ''
        Write-Host '  Container configuration:' -ForegroundColor Cyan
        $containerName = (Read-FltValue 'Container name (blank to cancel):' -CancelOnBlank)
        if (-not $containerName) { return }

        Write-Host ''
        Write-Host '  Network mode:' -ForegroundColor DarkGray
        Write-Host '   1. Bridge (default)   2. Host (shares VM network)'
        Write-Host ''
        $netChoice2 = (Read-Host '  Choice (blank = bridge)').Trim()
        $useHostNet2 = $netChoice2 -eq '2'
        $hostPort2   = '2222'
        if (-not $useHostNet2) {
            $hostPort2 = (Read-FltValue 'Host SSH port mapping (blank = 2222):' -AllowEmpty)
            if ([string]::IsNullOrEmpty($hostPort2)) { $hostPort2 = '2222' }
        }

        if ($useHostNet2) {
            # Host networking: each container needs a unique port — 22 is taken by VM sshd
            # Check which ports are already in use by other host-network containers
            $usedPorts = Invoke-SSHCommand -SessionId $sid `
                -Command "docker ps --format '{{.Command}}' | grep -oP '(?<=-p )\d+' | sort -n"
            $usedList  = ($usedPorts.Output | Where-Object { $_ }) -join ', '
            Write-Host ''
            Write-Host '  Host networking: each container needs a unique SSH port.' -ForegroundColor DarkGray
            if ($usedList) { Write-Host "  Ports already in use: $usedList" -ForegroundColor DarkGray }
            $sshPort2 = (Read-FltValue 'SSH port for this container (e.g. 2222, 2223 ...):'  -AllowEmpty)
            if ([string]::IsNullOrEmpty($sshPort2)) { $sshPort2 = '2222' }
            $runCmd2 = "docker run -d --name $containerName --restart unless-stopped --network host $imageName /usr/sbin/sshd -D -p $sshPort2"
        } else {
            $dnsFl = if ($dnsFlags) { $dnsFlags } else { '' }
            $runCmd2 = "docker run -d --name $containerName --restart unless-stopped $dnsFl -p ${hostPort2}:22 $imageName"
        }

        Write-Host ''
        Write-Host "  Starting container $containerName..." -ForegroundColor Cyan
        Write-Host ("  > " + $runCmd2) -ForegroundColor DarkGray
        $runRes2 = Invoke-SSHCommand -SessionId $sid -Command $runCmd2 -TimeOut 60
        $runRes2.Output | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor DarkGray }

        if ($runRes2.ExitStatus -ne 0) {
            Write-Host '  Container start FAILED.' -ForegroundColor Red
            Read-Host '  Press Enter'; return
        }
        Write-Host "  Container $containerName started." -ForegroundColor Green

        # Register as fleet target
        Write-Host ''
        if (Read-FltYesNo -Prompt "Register '$containerName' as a fleet target?") {
            $tgtName = Read-FltValue "Fleet target name (blank = $containerName):" -AllowEmpty
            if ([string]::IsNullOrEmpty($tgtName)) { $tgtName = $containerName }
            $ok2 = _Register-ContainerTarget -Name $tgtName `
                       -DockerHostName $dockerHost.Name `
                       -ContainerName  $containerName `
                       -PackageManager 'apt'
            if ($ok2) {
                Write-Host "  Registered '$tgtName'." -ForegroundColor Green
                $Script:FleetTargets = @(Get-FleetTargets -Silent)
            }
        }
        Write-Host ''
        Read-Host '  Press Enter'
        Remove-SSHSession -SessionId $sid | Out-Null
        return
    }

    Write-Host ''
    Write-Host '  What to build:' -ForegroundColor Cyan
    $dockerfileDir = Join-Path $Script:FltScriptRoot 'docker'
    $dockerfiles   = @(Get-ChildItem $dockerfileDir -Filter 'Dockerfile.*' -ErrorAction SilentlyContinue)

    # Descriptions for known Dockerfiles
    $dfDescriptions = @{
        'Dockerfile.debian-ssh'           = 'Debian SSH target (standard Debian feed)'
        'Dockerfile.debian-ssh-beckhoff'  = 'Debian SSH target (Beckhoff + standard feeds, requires bhf.conf secret)'
        'Dockerfile.ansible'              = 'Ansible operator container'
    }

    if ($dockerfiles.Count -gt 0) {
        Write-Host '  Available Dockerfiles:'
        for ($i = 0; $i -lt $dockerfiles.Count; $i++) {
            $dfDesc = $dfDescriptions[$dockerfiles[$i].Name]
            $descStr = if ($dfDesc) { " — $dfDesc" } else { '' }
            Write-Host "   $($i+1). $($dockerfiles[$i].Name)$descStr"
        }
        Write-Host "   $($dockerfiles.Count+1). Specify a custom Dockerfile path"
        Write-Host '   0. Cancel'
        Write-Host ''
        $dfChoice = (Read-Host '  Choice').Trim()
        if ($dfChoice -eq '0') { return }
        $dfIdx = [int]$dfChoice - 1
        if ($dfIdx -ge 0 -and $dfIdx -lt $dockerfiles.Count) {
            $dockerfilePath = $dockerfiles[$dfIdx].FullName
        } else {
            $dockerfilePath = Read-FltValue 'Dockerfile path (blank to cancel):' -CancelOnBlank
            if (-not $dockerfilePath) { return }
        }
    } else {
        $dockerfilePath = Read-FltValue 'Dockerfile path (blank to cancel):' -CancelOnBlank
        if (-not $dockerfilePath) { return }
    }

    if (-not (Test-Path $dockerfilePath)) {
        Write-Host "  File not found: $dockerfilePath" -ForegroundColor Red
        Read-Host '  Press Enter'; return
    }

    $imageName = (Read-FltValue 'Image name (e.g. tcflt-debian-ssh:latest):' -CancelOnBlank)
    if (-not $imageName) { return }

    # Build args (optional)
    Write-Host ''
    Write-Host '  Build arguments (optional, e.g. ROOT_PASSWORD=secret):' -ForegroundColor DarkGray
    Write-Host '  Enter one per line, blank to finish.' -ForegroundColor DarkGray
    Write-Host ''
    $buildArgs = @()
    while ($true) {
        $arg = (Read-Host '  --build-arg').Trim()
        if ([string]::IsNullOrEmpty($arg)) { break }
        $buildArgs += $arg
    }

    # ── 3. Container run parameters ───────────────────────────────────────────
    Write-Host ''
    Write-Host '  Container configuration:' -ForegroundColor Cyan
    $containerName = (Read-FltValue 'Container name (blank to cancel):' -CancelOnBlank)
    if (-not $containerName) { return }

    # Network mode
    Write-Host ''
    Write-Host '  Network mode:' -ForegroundColor DarkGray
    Write-Host '   1. Bridge (default — isolated network, port mapping)'
    Write-Host '   2. Host   (shares VM network stack — required when bridge has no internet)'
    Write-Host ''
    $netChoice = (Read-Host '  Choice (blank = bridge)').Trim()
    $useHostNet = $netChoice -eq '2'

    if ($useHostNet) {
        $hostPort = (Read-FltValue 'SSH port inside container (blank = 2222):' -AllowEmpty)
        if ([string]::IsNullOrEmpty($hostPort)) { $hostPort = '2222' }
        $buildArgs += "SSH_PORT=$hostPort"
        Write-Host "  Host networking: container sshd will listen on port $hostPort on the VM's IP." -ForegroundColor DarkGray
    } else {
        $hostPort = (Read-FltValue 'Host SSH port mapping (e.g. 2222, blank = 2222):' -AllowEmpty)
        if ([string]::IsNullOrEmpty($hostPort)) { $hostPort = '2222' }
    }

    # ── 5. Copy Dockerfile to remote host ─────────────────────────────────────
    try {
        # Create temp build dir on remote
        $remoteBuildDir = "/tmp/tcflt-build-$containerName"
        Invoke-SSHCommand -SessionId $sid -Command "mkdir -p $remoteBuildDir" | Out-Null

        # SCP the Dockerfile
        Write-Host "  Copying Dockerfile to $($dockerHost.Name):$remoteBuildDir..." -ForegroundColor DarkGray
        $scpParams = @{
            Path         = $dockerfilePath
            Destination  = "$remoteBuildDir/"
            ComputerName = $dockerHost.Address
            Port         = $dockerHost.Port
            Credential   = $cred
            AcceptKey    = $true
        }
        Set-SCPItem @scpParams -ErrorAction Stop
        Write-Host '  Dockerfile copied.' -ForegroundColor DarkGray

        # ── 6. Build the image ─────────────────────────────────────────────────
        $dfName     = Split-Path $dockerfilePath -Leaf
        $buildArgStr = ($buildArgs | ForEach-Object { "--build-arg $_" }) -join ' '

        # Beckhoff Dockerfile uses BuildKit --secret for credentials
        $secretFlag = ''
        if ($dfName -match 'beckhoff') {
            $bhfConfPath = Join-Path $Script:FltScriptRoot 'apt-config' | Join-Path -ChildPath 'bhf.conf'
            if (Test-Path $bhfConfPath) {
                # SCP bhf.conf to remote temp dir
                $scpSecret = @{
                    Path         = $bhfConfPath
                    Destination  = "$remoteBuildDir/"
                    ComputerName = $dockerHost.Address
                    Port         = $dockerHost.Port
                    Credential   = $cred
                    AcceptKey    = $true
                }
                Set-SCPItem @scpSecret -ErrorAction SilentlyContinue
                $secretFlag = "--secret id=apt,src=$remoteBuildDir/bhf.conf"
                Write-Host '  Beckhoff credentials (bhf.conf) found and will be used.' -ForegroundColor DarkGray
            } else {
                Write-Host '  Note: apt-config/bhf.conf not found — building without Beckhoff credentials.' -ForegroundColor Yellow
                Write-Host "  Create $bhfConfPath with your myBeckhoff credentials to enable the Beckhoff feed." -ForegroundColor DarkGray
            }
            # Enable BuildKit
            $buildCmd = "DOCKER_BUILDKIT=1 docker build $secretFlag -t $imageName -f '$remoteBuildDir/$dfName' $buildArgStr '$remoteBuildDir' 2>&1"
        } else {
            # --network host uses the Docker host DNS — needed when container DNS differs
            # Build context must be last argument — use single quotes for Linux shell
            # Use legacy builder (DOCKER_BUILDKIT=0) which supports --pull=false
            # This avoids trying to fetch base image from registry when offline
            $buildCmd = "DOCKER_BUILDKIT=0 docker build --network host --pull=false -t $imageName -f '$remoteBuildDir/$dfName' $buildArgStr '$remoteBuildDir' 2>&1"
        }

        Write-Host ''
        Write-Host "  Building $imageName on $($dockerHost.Name)..." -ForegroundColor Cyan
        Write-Host "  > $buildCmd" -ForegroundColor DarkGray
        Write-Host ''
        $buildResult = Invoke-SSHCommand -SessionId $sid -Command $buildCmd -TimeOut 600
        $buildOutput = @($buildResult.Output) + @($buildResult.Error) | Where-Object { $_ }
        $buildOutput | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor DarkGray }

        if ($buildResult.ExitStatus -ne 0) {
            Write-Host ''
            Write-Host '  Build FAILED — see output above.' -ForegroundColor Red
            # Show last 10 lines of output as a summary
            $buildOutput | Select-Object -Last 10 |
                ForEach-Object { Write-Host ("  " + $_) -ForegroundColor Red }
            Read-Host '  Press Enter'; return
        }
        Write-Host ''
        Write-Host "  Build OK — image $imageName ready." -ForegroundColor Green

        # ── 7. Run the container ───────────────────────────────────────────────
            if ($dnsFlags) { Write-Host "  Using DNS: $dnsServer2" -ForegroundColor DarkGray }
        if ($useHostNet) {
            # Host networking: add CMD override so sshd uses port 2222 not 22
            $runCmd = "docker run -d --name $containerName --restart unless-stopped --network host $imageName /usr/sbin/sshd -D -p $hostPort"
        } else {
            $runCmd = "docker run -d --name $containerName --restart unless-stopped $dnsFlags -p `${hostPort}:22 $imageName"
        }
        Write-Host ''
        Write-Host "  Starting container $containerName..." -ForegroundColor Cyan
        Write-Host "  > $runCmd" -ForegroundColor DarkGray
        $runResult = Invoke-SSHCommand -SessionId $sid -Command $runCmd -TimeOut 60
        $runResult.Output | ForEach-Object { Write-Host ("  " + $_) -ForegroundColor DarkGray }

        if ($runResult.ExitStatus -ne 0) {
            Write-Host ''
            Write-Host '  Container start FAILED.' -ForegroundColor Red
            Read-Host '  Press Enter'; return
        }
        Write-Host ''
        Write-Host "  Container $containerName started on $($dockerHost.Name)." -ForegroundColor Green

        # Clean up temp build dir
        Invoke-SSHCommand -SessionId $sid -Command "rm -rf $remoteBuildDir" | Out-Null

    } catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host '  Press Enter'; return
    } finally {
        Remove-SSHSession -SessionId $sid | Out-Null
    }

    # ── 8. Offer to register as fleet target ──────────────────────────────────
    Write-Host ''
    if (Read-FltYesNo -Prompt "Register '$containerName' as a fleet target?") {
        $targetName = Read-FltValue "Fleet target name (blank = $containerName):" -AllowEmpty
        if ([string]::IsNullOrEmpty($targetName)) { $targetName = $containerName }
        $ok = _Register-ContainerTarget -Name $targetName `
                  -DockerHostName $dockerHost.Name `
                  -ContainerName  $containerName `
                  -PackageManager 'apt'
        if ($ok) {
            Write-Host "  Registered '$targetName' as a fleet target." -ForegroundColor Green
            $Script:FleetTargets = @(Get-FleetTargets -Silent)
        } else {
            Write-Host '  Registration failed.' -ForegroundColor Red
        }
    }

    Write-Host ''
    Read-Host '  Press Enter'
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
        Write-Host ' 11. Build + run       (build image and start container on remote host)' -ForegroundColor White
        Write-Host ' 12. Remove container  (docker rm -f — stop and delete)' -ForegroundColor White
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
            '11' { Invoke-ContainerRemoteBuildMenu }
            '12' { Invoke-ContainerRemoveContainerMenu }
            '0'  { return }
            default {
                Write-Host '  Enter 1-12 for an operation, 0 to go back.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 800
            }
        }
    }
}