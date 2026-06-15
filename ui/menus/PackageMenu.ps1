# =============================================================================
#  TcFltPkgMgr — Package Menu
#  Install, upgrade, uninstall across the fleet; cross-target package status.
# =============================================================================

# ── Fleet install ─────────────────────────────────────────────────────────────

function Invoke-FleetInstallMenu {
    Clear-Host
    Write-Host '  Fleet Install' -ForegroundColor Cyan
    Write-Host ''

    # Search for package
    $term = Read-FltPackageSearch -Prompt 'Package name to install (blank to cancel):'
    if (-not $term) { return }

    # Pick feed — use live source list from tcpkg, not static config
    $liveSources = @(Get-FltSources | Where-Object { $_.State -eq 'enabled' } | Sort-Object Pri)
    $feedIdx     = _Pick-Feed-Live $liveSources
    if ($feedIdx -lt 0) { return }
    $feedFilter  = if ($feedIdx -lt $liveSources.Count) { $liveSources[$feedIdx].Name } else { '' }

    # Search feed
    $listArgs = @('list', $term)
    if ($feedFilter) { $listArgs += '-n', $feedFilter }
    $res = Get-FltPackageList -ListArgs $listArgs
    if (-not $res.Ok -or $res.Items.Count -eq 0) {
        Write-Host "  No packages found matching '$term'." -ForegroundColor Yellow
        Read-Host '  Press Enter to continue'
        return
    }

    # Pick package
    Write-Host '  Results:' -ForegroundColor Cyan
    Show-FltTable -Items $res.Items -Columns $res.Columns -Base 1
    Write-Host '     0. Cancel'; Write-Host ''
    $pkg = Read-FltNumberedChoice -Items $res.Items -Prompt 'Package number' -Base 1
    if (-not $pkg) { return }

    # Pick version
    $versions = Get-FltPackageVersions -PackageName $pkg.Name -FeedFilter $feedFilter
    $pkgSpec  = $null
    if ($versions.Count -gt 0) {
        Write-Host ''
        Write-Host ("  Versions of $($pkg.Name):") -ForegroundColor Cyan
        Show-FltTable -Items $versions -Columns @(
            @{ Header = 'Version'; Expr = { $_.Version } },
            @{ Header = 'Feed';    Expr = { $_.Source  } }
        ) -Base 1
        $latestNum = $versions.Count + 1   # next number after the list
        Write-Host ("  {0,4}. Latest (let tcpkg decide)" -f $latestNum)
        Write-Host '     0. Cancel'
        Write-Host ''
        $vChoice = (Read-Host '  Choice').Trim()
        if ($vChoice -eq '0' -or [string]::IsNullOrWhiteSpace($vChoice)) { return }
        if ($vChoice -match '^\d+$') {
            $vn = [int]$vChoice
            if ($vn -ge 1 -and $vn -le $versions.Count) {
                $ver     = $versions[$vn - 1]
                $pkgSpec = "$($pkg.Name.ToLower())=$($ver.Version)"
                # Source field from tcpkg list -a is the feed name
                $feedName = if ($ver.Source) { $ver.Source } else { '' }
            } elseif ($vn -eq $latestNum) {
                $pkgSpec = $pkg.Name.ToLower()
                $feedName = ''
            } else { return }
        } else { return }
    } else {
        $pkgSpec = $pkg.Name.ToLower()
        $feedName = ''
    }

    _Invoke-FleetBatchAction -Action 'install' -PackageSpec $pkgSpec -FeedName $feedName
}

function Invoke-FleetUpgradeMenu {
    Clear-Host
    Write-Host '  Fleet Upgrade' -ForegroundColor Cyan
    Write-Host ''
    $term = Read-FltPackageSearch -Prompt 'Package name to upgrade (blank to cancel):'
    if (-not $term) { return }
    $res = Get-FltPackageList -ListArgs @('list', $term)
    if (-not $res.Ok -or $res.Items.Count -eq 0) {
        Write-Host "  No packages found matching '$term'." -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }
    Show-FltTable -Items $res.Items -Columns $res.Columns -Base 1
    Write-Host '     0. Cancel'; Write-Host ''
    $pkg = Read-FltNumberedChoice -Items $res.Items -Prompt 'Package number' -Base 1
    if (-not $pkg) { return }
    _Invoke-FleetBatchAction -Action 'upgrade' -PackageSpec $pkg.Name.ToLower()
}

function Invoke-FleetUninstallMenu {
    Clear-Host
    Write-Host '  Fleet Uninstall' -ForegroundColor Cyan
    Write-Host ''
    $term = Read-FltPackageSearch -Prompt 'Package to uninstall (blank to cancel):'
    if (-not $term) { return }
    $res = Get-FltPackageList -ListArgs @('list', '-i', $term)
    if (-not $res.Ok -or $res.Items.Count -eq 0) {
        Write-Host "  No installed packages found matching '$term'." -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }
    Show-FltTable -Items $res.Items -Columns $res.Columns -Base 1
    Write-Host '     0. Cancel'; Write-Host ''
    $pkg = Read-FltNumberedChoice -Items $res.Items -Prompt 'Package number' -Base 1
    if (-not $pkg) { return }
    _Invoke-FleetBatchAction -Action 'uninstall' -PackageSpec $pkg.Name.ToLower()
}

# ── Batch action orchestration ────────────────────────────────────────────────

function _Invoke-FleetBatchAction {
    param([string]$Action, [string]$PackageSpec, [string]$FeedName = '')
    $targets = $Script:FleetTargets
    if ($targets.Count -eq 0) {
        Write-Host '  No remote targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    # Show fleet dashboard so user can see targets and their status
    Show-FleetDashboard -Targets $targets -LastCommand '' -ResultLines @(
        "Action: $($Action.ToUpper())   Package: $PackageSpec",
        "Select targets — enter numbers separated by commas or spaces, e.g: 11,12,13  or  11 12 13  or  11-13"
    )

    $selected = @(Read-FltMultiSelect -Items $targets -Prompt 'Targets (11+)')
    if ($selected.Count -eq 0) { return }

    # Collect SSH credentials
    $sshCreds = Get-FleetSshCredential -Targets $selected
    if (-not $sshCreds) { return }

    $timeout = Read-FltTimeout -Default ([int]((Get-FltCfgValue 'ssh' 'timeoutSeconds' 1800)))

    # Confirm — note that feed check will run before execution
    Write-Host ''
    Write-Host ("  $($Action.ToUpper()) '$PackageSpec' on $($selected.Count) target(s).") -ForegroundColor Cyan
    if ($FeedName -and $Action -in @('install','upgrade')) {
        Write-Host "  Feed check: targets missing the required feed will auto-switch to push-from-local." -ForegroundColor DarkGray
    }
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    # Show batch dashboard and execute
    Show-FleetBatchDashboard -Targets $selected -Action $Action -PackageSpec $PackageSpec `
        -Mode 'Parallel SSH' -TimeoutSecs $timeout

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

    $results = Invoke-FleetAction -Action $Action -PackageSpec $PackageSpec -FeedName $FeedName `
                   -Targets $selected -Credential $sshCreds.Credential `
                   -KeyFile $sshCreds.KeyFile -TimeoutSecs $timeout `
                   -OnProgress $onProgress

    # Final status update
    foreach ($r in $results) {
        Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note
    }

    # Log the batch result
    Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $results

    $ok   = @($results | Where-Object { $_.Status -like 'OK*' }).Count
    $fail = @($results | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Timed out' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    $sumStr = "  Complete: $ok OK  |  $fail failed"
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}${sumStr}`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    [void](Read-Host '  Batch complete. Press Enter to continue')
}

# ── Cross-target package status view ─────────────────────────────────────────

function Invoke-PackageStatusMenu {
    Clear-Host
    Write-Host '  Package Status Across Fleet' -ForegroundColor Cyan
    Write-Host ''
    $pkg = Read-FltPackageSearch -Prompt 'Package name (exact, blank to cancel):'
    if (-not $pkg) { return }

    # Get feed version
    $versions = Get-FltPackageVersions -PackageName $pkg
    $feedVer  = if ($versions.Count -gt 0) { $versions[0].Version } else { '' }
    $feedSrc  = if ($versions.Count -gt 0) { $versions[0].Source  } else { '' }

    Write-Host '  Querying all targets...' -ForegroundColor Cyan
    $summary = Get-FleetPackageStatus -PackageName $pkg -Targets $Script:FleetTargets `
                   -FeedVersion $feedVer -FeedSource $feedSrc

    Show-PackageStatusDashboard -Summary $summary -AllTargets $Script:FleetTargets

    Write-Host ''
    $choice = (Read-Host '  Choice').Trim()
    # 1 = install/upgrade selected, 2 = upgrade all outdated
    if ($choice -eq '2') {
        $outdated = @($summary.States | Where-Object { $_.Status -eq 'upgradable' } |
                      ForEach-Object {
                          $Script:FleetTargets | Where-Object { $_.Name -eq $_.TargetName } |
                          Select-Object -First 1
                      } | Where-Object { $_ })
        if ($outdated.Count -gt 0) {
            _Invoke-FleetBatchAction -Action 'upgrade' -PackageSpec $pkg.ToLower()
        }
    }
}

# ── Outdated check ────────────────────────────────────────────────────────────

function Invoke-OutdatedCheckMenu {
    Clear-Host
    Write-Host '  Fleet Outdated Check' -ForegroundColor Cyan
    Write-Host '  Querying all targets for upgradable packages...' -ForegroundColor DarkGray
    Write-Host ''

    $outdatedMap = Get-FleetOutdated -Targets $Script:FleetTargets

    if ($outdatedMap.Count -eq 0) {
        Write-Host '  All targets are up to date.' -ForegroundColor Green
        Read-Host '  Press Enter'; return
    }

    $w = [Math]::Max([Console]::WindowWidth, 60) - 1
    Write-Host ('  {0,-30} {1,-10} {2,-14} {3}' -f 'Package','Targets','Installed','Latest') -ForegroundColor DarkGray
    Write-Host ('  ' + '-' * ($w - 2)) -ForegroundColor DarkGray

    foreach ($pkgName in $outdatedMap.Keys | Sort-Object) {
        $sum     = $outdatedMap[$pkgName]
        $tCount  = $sum.States.Count
        $instVer = ($sum.States | Select-Object -First 1).InstalledVersion
        Write-Host ('  {0,-30} {1,-10} {2,-14} {3}' -f $pkgName, "$tCount target(s)", $instVer, $sum.FeedVersion)
    }

    Write-Host ''
    $r = (Read-Host '  Upgrade all listed packages on affected targets?  [1] Yes  [0] No  (default 0)').Trim()
    if ($r -eq '1') {
        foreach ($pkgName in $outdatedMap.Keys) {
            $targets = @($outdatedMap[$pkgName].States | ForEach-Object {
                $tn = $_.TargetName
                $Script:FleetTargets | Where-Object { $_.Name -eq $tn } | Select-Object -First 1
            } | Where-Object { $_ })
            if ($targets.Count -gt 0) {
                _Invoke-FleetBatchAction -Action 'upgrade' -PackageSpec $pkgName.ToLower()
            }
        }
    }
}

# ── Helper: feed picker (live — from tcpkg source list) ──────────────────────
# Uses the actual configured sources rather than the static feeds config.
# Returns index into $Sources array, or $Sources.Count for "All feeds", or -1 to cancel.

function _Pick-Feed-Live {
    param([object[]]$Sources)
    if (-not $Sources -or $Sources.Count -eq 0) { return 0 }   # no sources = all

    Write-Host '  Feed to search:' -ForegroundColor Cyan
    Show-FltTable -Items $Sources -Columns @(
        @{ Header = 'Feed';     Expr = { $_.Name } },
        @{ Header = 'Priority'; Expr = { $_.Pri  }; Align = 'Right' }
    ) -Base 1
    $allNum = $Sources.Count + 1
    Write-Host ("  {0,4}. All feeds" -f $allNum)
    Write-Host '     0. Cancel'
    Write-Host ''
    $r = (Read-Host '  Choice').Trim()
    if ($r -eq '0' -or [string]::IsNullOrWhiteSpace($r)) { return -1 }
    if ($r -match '^\d+$') {
        $n = [int]$r
        if ($n -ge 1 -and $n -le $Sources.Count) { return $n - 1 }
        if ($n -eq $allNum) { return $Sources.Count }
    }
    return -1
}

# ── Helper: feed picker (static config) ──────────────────────────────────────

function _Pick-Feed {
    param([FeedDefinition[]]$Feeds)
    if ($Feeds.Count -eq 0) { return $Feeds.Count }   # All feeds

    Write-Host '  Feed to search:' -ForegroundColor Cyan
    $allNum = $Feeds.Count + 1   # next number after last feed
    Show-FltTable -Items $Feeds -Columns @(
        @{ Header = 'Feed';     Expr = { $_.Name } },
        @{ Header = 'Priority'; Expr = { $_.Priority }; Align = 'Right' }
    ) -Base 1
    Write-Host ("  {0,4}. All feeds" -f $allNum)
    Write-Host '     0. Cancel'
    Write-Host ''
    $r = (Read-Host '  Choice').Trim()
    if ($r -eq '0' -or [string]::IsNullOrWhiteSpace($r)) { return -1 }
    if ($r -match '^\d+$') {
        $n = [int]$r
        if ($n -ge 1 -and $n -le $Feeds.Count) { return $n - 1 }
        if ($n -eq $allNum) { return $Feeds.Count }
    }
    return -1
}