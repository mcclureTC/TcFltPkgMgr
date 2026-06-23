# =============================================================================
#  TcFltPkgMgr — Linux Admin menu
#  Ansible-based operations for Linux non-container fleet targets.
#
#  Phase 6.2 — Invoke-LinuxAdminMenu (top-level menu, target filter, sub-menu routing)
#  Phase 6.3 — Package sub-menus    (Invoke-LinuxInstallMenu, Upgrade, Remove)
#  Phase 6.4 — User sub-menu        (Invoke-LinuxUserMenu)
#  Phase 6.5 — Service sub-menu     (Invoke-LinuxServiceMenu)
#  Phase 6.6 — Run playbook         (Invoke-LinuxPlaybookMenu)
# =============================================================================

# ---------------------------------------------------------------------------
# Private helper: Linux Ansible-eligible targets
# ---------------------------------------------------------------------------

function _Get-LinuxTargets {
    @($Script:FleetTargets | Where-Object {
        $_.OS -eq 'linux' -and $_.TargetType -ne 'container'
    })
}

# ---------------------------------------------------------------------------
# Private helper: shared Ansible batch action orchestration
# Mirrors _Invoke-WinGetBatchAction but routes through Invoke-FltAnsibleBatch.
# ---------------------------------------------------------------------------

function _Invoke-AnsibleBatchAction {
    param(
        [Parameter(Mandatory)] [string]      $Action,
        [Parameter(Mandatory)] [string]      $PackageSpec,
        [Parameter(Mandatory)] [scriptblock] $PlaybookBuilder,
        [object[]] $PreSelected = @()
    )

    $linuxTargets = @(_Get-LinuxTargets)
    if ($linuxTargets.Count -eq 0) {
        Write-Host '  No Linux targets configured.' -ForegroundColor Yellow
        Write-Host '  Add a target with OS=linux via Setup > Add target.' -ForegroundColor DarkGray
        Read-Host '  Press Enter'
        return
    }

    # Target selection
    if ($PreSelected.Count -gt 0) {
        $selected = $PreSelected
    } else {
        Show-FleetDashboard -Targets $linuxTargets -LastCommand '' -ResultLines @(
            "Action: $($Action.ToUpper())   Package: $PackageSpec",
            "Select targets — enter numbers separated by commas or spaces, e.g: 11,12  or  11-13"
        )
        $selected = @(Read-FltMultiSelect -Items $linuxTargets -Prompt 'Targets (11+)')
        if ($selected.Count -eq 0) { return }
    }

    Write-Host ''
    Write-Host ("  $($Action.ToUpper()) '$PackageSpec' on $($selected.Count) Linux target(s) via Ansible.") -ForegroundColor Cyan
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    Show-FleetBatchDashboard -Targets $selected -Action $Action -PackageSpec $PackageSpec `
        -Mode 'Ansible' -TimeoutSecs 300

    $onProgress = {
        param($dict)
        foreach ($key in @($dict.Keys)) {
            $parts = ($dict[$key]) -split '\|', 3
            $st    = $parts[0]
            $dur   = [double]$parts[1]
            $note  = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            if ($Script:FltBatchStatus.ContainsKey($key)) {
                $cur     = $Script:FltBatchStatus[$key].Status
                $curNote = $Script:FltBatchStatus[$key].Note
                if ($st -ne $cur -or $note -ne $curNote) {
                    Update-FltBatchRow $key $st $dur $note
                }
            }
        }
    }

    $results = Invoke-FltAnsibleBatch `
                   -Targets        $selected `
                   -PlaybookBuilder $PlaybookBuilder `
                   -Action         $Action `
                   -PackageSpec    $PackageSpec `
                   -OnProgress     $onProgress `
                   -ReadOnly       $Script:FltReadOnly

    foreach ($r in $results) {
        Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note
    }

    $ok   = @($results | Where-Object { $_.Status -like 'OK*' }).Count
    $skip = @($results | Where-Object { $_.Status -like 'Skipped*' }).Count
    $fail = @($results | Where-Object {
        $_.Status -like 'Failed*' -or $_.Status -eq 'Unreachable' -or $_.Status -eq 'Unsupported'
    }).Count

    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    $sumStr = "  Complete: $ok OK  |  $skip skipped  |  $fail failed"
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}${sumStr}`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    [void](Read-Host '  Batch complete. Press Enter to continue')
}

# ---------------------------------------------------------------------------
# Phase 6.3 — Package sub-menus
# ---------------------------------------------------------------------------

function Invoke-LinuxInstallMenu {
    Clear-Host
    Write-Host '  Linux Admin  >  Install package' -ForegroundColor Cyan
    Write-Host ''

    $pkg = (Read-Host '  Package name to install (blank to cancel)').Trim()
    if ([string]::IsNullOrEmpty($pkg)) { return }

    _Invoke-AnsibleBatchAction `
        -Action         'install' `
        -PackageSpec    $pkg `
        -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName $pkg }
}

function Invoke-LinuxUpgradeMenu {
    Clear-Host
    Write-Host '  Linux Admin  >  Upgrade package' -ForegroundColor Cyan
    Write-Host ''

    $pkg = (Read-Host '  Package name to upgrade (blank to cancel)').Trim()
    if ([string]::IsNullOrEmpty($pkg)) { return }

    _Invoke-AnsibleBatchAction `
        -Action         'upgrade' `
        -PackageSpec    $pkg `
        -PlaybookBuilder { _Get-PackagePlaybook -Action 'upgrade' -PackageName $pkg }
}

function Invoke-LinuxRemoveMenu {
    Clear-Host
    Write-Host '  Linux Admin  >  Remove package' -ForegroundColor Cyan
    Write-Host ''

    $pkg = (Read-Host '  Package name to remove (blank to cancel)').Trim()
    if ([string]::IsNullOrEmpty($pkg)) { return }

    _Invoke-AnsibleBatchAction `
        -Action         'remove' `
        -PackageSpec    $pkg `
        -PlaybookBuilder { _Get-PackagePlaybook -Action 'remove' -PackageName $pkg }
}

# ---------------------------------------------------------------------------
# Phase 6.4 — User management sub-menu
# ---------------------------------------------------------------------------

function Invoke-LinuxUserMenu {
    while ($true) {
        Clear-Host
        Write-Host '  Linux Admin  >  Manage users' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. Add user'
        Write-Host '  2. Remove user'
        Write-Host ''
        Write-Host '  0. Back' -ForegroundColor DarkGray
        Write-Host ''
        $choice = (Read-Host '  Choice').Trim()

        switch ($choice) {
            '1' {
                Clear-Host
                Write-Host '  Linux Admin  >  Add user' -ForegroundColor Cyan
                Write-Host ''
                $userName = (Read-Host '  Username (blank to cancel)').Trim()
                if ([string]::IsNullOrEmpty($userName)) { break }

                $groupsRaw = (Read-Host "  Groups (comma-separated, blank for none)").Trim()
                $groups    = if ($groupsRaw) { @($groupsRaw -split '\s*,\s*' | Where-Object { $_ }) } else { @() }
                $shell     = (Read-Host "  Shell (blank for /bin/bash)").Trim()
                if ([string]::IsNullOrEmpty($shell)) { $shell = '/bin/bash' }

                _Invoke-AnsibleBatchAction `
                    -Action         'create' `
                    -PackageSpec    $userName `
                    -PlaybookBuilder {
                        _Get-UserPlaybook -Action 'create' -UserName $userName `
                            -Groups $groups -Shell $shell
                    }
            }
            '2' {
                Clear-Host
                Write-Host '  Linux Admin  >  Remove user' -ForegroundColor Cyan
                Write-Host ''
                $userName = (Read-Host '  Username to remove (blank to cancel)').Trim()
                if ([string]::IsNullOrEmpty($userName)) { break }

                Write-Host ''
                Write-Host "  WARNING: This will remove user '$userName' and their home directory." -ForegroundColor Yellow
                if (-not (Read-FltYesNo -Prompt 'Confirm?')) { break }

                _Invoke-AnsibleBatchAction `
                    -Action         'remove' `
                    -PackageSpec    $userName `
                    -PlaybookBuilder { _Get-UserPlaybook -Action 'remove' -UserName $userName }
            }
            '0' { return }
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 6.5 — Service management sub-menu
# ---------------------------------------------------------------------------

function Invoke-LinuxServiceMenu {
    while ($true) {
        Clear-Host
        Write-Host '  Linux Admin  >  Manage services' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. Start service'
        Write-Host '  2. Stop service'
        Write-Host '  3. Restart service'
        Write-Host '  4. Enable on boot'
        Write-Host '  5. Disable on boot'
        Write-Host ''
        Write-Host '  0. Back' -ForegroundColor DarkGray
        Write-Host ''
        $choice = (Read-Host '  Choice').Trim()

        $actionMap = @{
            '1' = 'start'
            '2' = 'stop'
            '3' = 'restart'
            '4' = 'enable'
            '5' = 'disable'
        }

        if ($choice -eq '0') { return }
        if (-not $actionMap.ContainsKey($choice)) { continue }

        $action = $actionMap[$choice]
        Clear-Host
        Write-Host "  Linux Admin  >  Service: $action" -ForegroundColor Cyan
        Write-Host ''
        $svcName = (Read-Host '  Service name (e.g. nginx, docker — blank to cancel)').Trim()
        if ([string]::IsNullOrEmpty($svcName)) { continue }

        _Invoke-AnsibleBatchAction `
            -Action         $action `
            -PackageSpec    $svcName `
            -PlaybookBuilder { _Get-ServicePlaybook -Action $action -ServiceName $svcName }
    }
}

# ---------------------------------------------------------------------------
# Phase 6.6 — Run playbook
# ---------------------------------------------------------------------------

function Invoke-LinuxPlaybookMenu {
    Clear-Host
    Write-Host '  Linux Admin  >  Run playbook' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Enter the path to an Ansible playbook (.yml) file.' -ForegroundColor DarkGray
    Write-Host '  The playbook will run against the targets you select.' -ForegroundColor DarkGray
    Write-Host ''

    $path = (Read-Host '  Playbook path (blank to cancel)').Trim()
    if ([string]::IsNullOrEmpty($path)) { return }

    if (-not (Test-Path $path)) {
        Write-Host "  File not found: '$path'" -ForegroundColor Red
        Read-Host '  Press Enter'
        return
    }
    if ([System.IO.Path]::GetExtension($path) -notin @('.yml', '.yaml')) {
        Write-Host "  File must be a .yml or .yaml file." -ForegroundColor Yellow
        Read-Host '  Press Enter'
        return
    }

    # Use a fixed playbook builder that returns the existing file
    $resolvedPath = (Resolve-Path $path).Path
    _Invoke-AnsibleBatchAction `
        -Action         'playbook' `
        -PackageSpec    (Split-Path $resolvedPath -Leaf) `
        -PlaybookBuilder {
            [pscustomobject]@{ Ok = $true; Path = $resolvedPath; Message = "Using: $resolvedPath" }
        }
}

# ---------------------------------------------------------------------------
# Phase 6.2 — Linux Admin top-level menu
# ---------------------------------------------------------------------------

function Invoke-LinuxAdminMenu {
    $linuxTargets = @(_Get-LinuxTargets)

    if ($linuxTargets.Count -eq 0) {
        Clear-Host
        Write-Host '  Linux Admin' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  No Linux targets configured.' -ForegroundColor Yellow
        Write-Host '  Add a target via Setup > Add target and set OS=linux, Type=physical or vm.' -ForegroundColor DarkGray
        Write-Host ''
        Read-Host '  Press Enter'
        return
    }

    while ($true) {
        Clear-Host

        # Show Linux-only target dashboard
        Show-FleetDashboard -Targets $linuxTargets -LastCommand '' -ResultLines @(
            "Linux Admin — $($linuxTargets.Count) Linux target(s)"
        )

        Write-Host ''
        Write-Host '  1. Install package   2. Upgrade package   3. Remove package' -ForegroundColor White
        Write-Host '  4. Manage users      5. Manage services   6. Run playbook' -ForegroundColor White
        Write-Host ''
        Write-Host '  0. Back' -ForegroundColor DarkGray
        Write-Host ''

        $choice = (Read-Host '  Choice').Trim()

        switch ($choice) {
            '1' { Invoke-LinuxInstallMenu }
            '2' { Invoke-LinuxUpgradeMenu }
            '3' { Invoke-LinuxRemoveMenu }
            '4' { Invoke-LinuxUserMenu }
            '5' { Invoke-LinuxServiceMenu }
            '6' { Invoke-LinuxPlaybookMenu }
            '0' { return }
            default {
                Write-Host "  Enter 1-6 for an operation, 0 to go back." -ForegroundColor Yellow
                Start-Sleep -Milliseconds 800
            }
        }

        # Refresh Linux targets after each action (targets may have changed)
        $linuxTargets = @(_Get-LinuxTargets)
    }
}