# =============================================================================
#  TcFltPkgMgr — Fleet Menu (Home Screen)
#  The fleet is the home screen. Targets are the primary context.
#  Operations are actions performed on selected targets.
#  The dashboard is always visible; only the content zone below it changes.
# =============================================================================

# Start a background TCP reachability check for a list of targets.
# Skips targets that are cached as online within reachCacheSecs.
# Uses ForEach-Object -Parallel so all targets are checked simultaneously.
# Returns a Job object. Results are [pscustomobject]@{ Name; Reachable }.
function Start-FltReachJob {
    param(
        [FleetTarget[]] $Targets,
        [switch]        $IgnoreCache   # force recheck even if cached
    )
    $cacheSecs = [int](Get-FltCfgValue 'ui' 'reachCacheSecs' 60)
    $now       = [DateTime]::UtcNow

    # Filter out recently confirmed online targets unless forced
    $toCheck = if ($IgnoreCache -or -not $Script:FltReachCache) {
        @($Targets)
    } else {
        @($Targets | Where-Object {
            $cached = $Script:FltReachCache[$_.Name]
            # Re-check if: not in cache, was offline/checking, or cache expired
            -not $cached -or
            $_.Reachable -ne 'online' -or
            ($now - $cached).TotalSeconds -gt $cacheSecs
        })
    }

    if ($toCheck.Count -eq 0) { return $null }   # all targets cached — no job needed

    $addrs    = @($toCheck | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Address=$_.Address; Port=$_.Port } })
    $throttle = [Math]::Min(50, [int](Get-FltCfgValue 'ssh' 'throttleLimit' 25))

    # ThreadJob runs in the same process — no serialization issues with pscustomobject arrays.
    Start-ThreadJob -ScriptBlock {
        param($addrs, $throttle)
        $addrs | ForEach-Object -Parallel {
            $t = $_
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $ar  = $tcp.BeginConnect($t.Address, $t.Port, $null, $null)
                $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
                $tcp.Close()
                [pscustomobject]@{ Name = $t.Name; Reachable = $ok }
            } catch {
                [pscustomobject]@{ Name = $t.Name; Reachable = $false }
            }
        } -ThrottleLimit $using:throttle
    } -ArgumentList $addrs, $throttle
}

# Apply reachability job results to targets and update the cache.
function Receive-FltReachJob {
    param([object]$ReachJob)
    if (-not $ReachJob) { return }
    $results = Receive-Job $ReachJob
    $now     = [DateTime]::UtcNow
    foreach ($r in $results) {
        $tgt = $Script:FleetTargets | Where-Object { $_.Name -eq $r.Name } | Select-Object -First 1
        if ($tgt) {
            $tgt.Reachable = if ($r.Reachable) { 'online' } else { 'offline' }
            # Update cache — only cache online results; offline targets always recheck
            if (-not $Script:FltReachCache) { $Script:FltReachCache = @{} }
            if ($r.Reachable) {
                $Script:FltReachCache[$r.Name] = $now
            } else {
                $Script:FltReachCache.Remove($r.Name)
            }
        }
    }
    Remove-Job $ReachJob -Force
}

# Reload targets from JSON store, preserve prior reachability state, start new check.
# Returns the new reachability job.
function Invoke-FltReloadTargets {
    param([object]$ReachJob)
    # Cancel any running job
    if ($ReachJob) { Remove-Job $ReachJob -Force -ErrorAction SilentlyContinue }

    # Capture prior reachability before reloading
    $priorReach = @{}
    foreach ($t in $Script:FleetTargets) { $priorReach[$t.Name] = $t.Reachable }

    # Reload fresh from JSON store
    $Script:FleetTargets = @(Get-FleetTargets -Silent)

    # Restore prior status so dashboard doesn't flash 'unknown'
    foreach ($t in $Script:FleetTargets) {
        $t.Reachable = if ($priorReach.ContainsKey($t.Name)) { $priorReach[$t.Name] } else { 'checking' }
    }

    # Reset to page 0 on reload (sort/filter preserved)
    $Script:FltDashPage = 0
    # Mark all as 'checking' and kick off a new job (ignore cache on explicit reload)
    foreach ($t in $Script:FleetTargets) { $t.Reachable = 'checking' }
    return Start-FltReachJob $Script:FleetTargets -IgnoreCache
}

# tcpkg sub-menu — install/upgrade/uninstall/status/outdated via tcpkg.
function Invoke-TcpkgMenu {
    while ($true) {
        Clear-Host
        Write-Host '  tcpkg' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. Install'
        Write-Host '  2. Upgrade'
        Write-Host '  3. Uninstall'
        Write-Host '  4. Status'
        Write-Host '  5. Outdated'
        Write-Host ''
        Write-Host '  0. Back' -ForegroundColor DarkGray
        Write-Host ''
        $choice = (Read-Host '  Choice').Trim()
        switch ($choice) {
            '1' { Invoke-FleetInstallMenu }
            '2' { Invoke-FleetUpgradeMenu }
            '3' { Invoke-FleetUninstallMenu }
            '4' { Invoke-PackageStatusMenu }
            '5' { Invoke-OutdatedCheckMenu }
            '0' { return }
        }
    }
}

# WinGet sub-menu — install/upgrade/uninstall/status via winget SSH.
function Invoke-WinGetMenu {
    while ($true) {
        Clear-Host
        Write-Host '  WinGet' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. Install'
        Write-Host '  2. Upgrade'
        Write-Host '  3. Uninstall'
        Write-Host '  4. Status'
        Write-Host ''
        Write-Host '  0. Back' -ForegroundColor DarkGray
        Write-Host ''
        $choice = (Read-Host '  Choice').Trim()
        switch ($choice) {
            '1' { Invoke-WinGetInstallMenu }
            '2' { Invoke-WinGetUpgradeMenu }
            '3' { Invoke-WinGetUninstallMenu }
            '4' { Invoke-WinGetStatusMenu }
            '0' { return }
        }
    }
}

# The Fleet home screen — the application entry point after startup.
# Shows all targets with reachability status. Handles sort, filter, pagination,
# target selection (11+), and routes to all sub-menus (Install, Setup, etc.).
# Manages two background reachability jobs: page-first and rest-of-fleet.
function Invoke-FleetMenu {
    # Load fleet targets
    $Script:FleetTargets       = @(Get-FleetTargets -Silent)
    $Script:FltMenuLastCmd     = ''
    $Script:FltMenuResultLines = @()
    $Script:FltDashPage        = 0
    # Sort/filter state persists — initialized in TcFltPkgMgr.ps1, not reset here

    # Page-first reachability: check current page targets immediately,
    # queue remaining pages as a second job (uses cache for non-page targets)
    $pageSize     = [Math]::Max(1, [int](Get-FltCfgValue 'ui' 'dashboardPageSize' 20))
    $pageTargets  = @($Script:FleetTargets | Select-Object -First $pageSize)
    $restTargets  = @($Script:FleetTargets | Select-Object -Skip  $pageSize)

    foreach ($t in $Script:FleetTargets) { $t.Reachable = 'checking' }
    $reachJob     = Start-FltReachJob $pageTargets -IgnoreCache
    $reachJobRest = if ($restTargets.Count -gt 0) {
        Start-FltReachJob $restTargets   # respects cache for off-page targets
    } else { $null }

    # Column definitions for sort/filter pickers
    $sortCols  = @('Name','OS','Type','Address','Port','Internet Access','Status')
    $sortProps = @('Name','OS','TargetType','Address','Port','InternetAccess','Reachable')

    # Helper: repaint with current sort/filter/page state
    # Also updates $Script:FltDisplayTargets — the sorted+filtered view used for selection
    $repaint = {
        # Compute the sorted+filtered display order
        $display = if ($Script:FltTargetFilter.FilterColumn) {
            @(Invoke-FltFilter -Items $Script:FleetTargets `
                -Column $Script:FltTargetFilter.FilterColumn `
                -Value  $Script:FltTargetFilter.FilterValue)
        } else { @($Script:FleetTargets) }

        if ($Script:FltTargetSort.SortColumn) {
            $display = @(Invoke-FltSort -Items $display `
                -Column $Script:FltTargetSort.SortColumn `
                -Descending $Script:FltTargetSort.SortDesc)
        }
        $Script:FltDisplayTargets = $display

        Show-FleetDashboard -Targets $Script:FleetTargets -Page $Script:FltDashPage `
            -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines `
            -SortState $Script:FltTargetSort -FilterState $Script:FltTargetFilter
        Write-Host -NoNewline '  Choice: '
    }

    # Mark all targets as 'checking' while background jobs run
    foreach ($t in $Script:FleetTargets) { $t.Reachable = 'checking' }
    & $repaint

    while ($true) {
        # Non-blocking input loop — polls reachability jobs while waiting for keypress
        $inputBuffer = ''
        while ($true) {
            # Check page-first job (current page targets)
            if ($reachJob -and $reachJob.State -in @('Completed','Failed')) {
                if ($reachJob.State -eq 'Completed') {
                    Receive-FltReachJob $reachJob
                    Show-FleetDashboard -Targets $Script:FleetTargets -Page $Script:FltDashPage `
                        -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines `
                        -SortState $Script:FltTargetSort -FilterState $Script:FltTargetFilter
                    Write-Host -NoNewline "  Choice: $inputBuffer"
                } else {
                    Remove-Job $reachJob -Force
                }
                $reachJob = $null
            }

            # Check rest-of-fleet job (off-page targets)
            if ($reachJobRest -and $reachJobRest.State -in @('Completed','Failed')) {
                if ($reachJobRest.State -eq 'Completed') {
                    Receive-FltReachJob $reachJobRest
                    # Only repaint if this page's targets were affected
                    Show-FleetDashboard -Targets $Script:FleetTargets -Page $Script:FltDashPage `
                        -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines `
                        -SortState $Script:FltTargetSort -FilterState $Script:FltTargetFilter
                    Write-Host -NoNewline "  Choice: $inputBuffer"
                } else {
                    Remove-Job $reachJobRest -Force
                }
                $reachJobRest = $null
            }

            # Check for keypress without blocking
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Enter) { break }
                if ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($inputBuffer.Length -gt 0) {
                        $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1)
                        Write-Host -NoNewline "`b `b"
                    }
                } elseif ($key.KeyChar -ne [char]0) {
                    $inputBuffer += $key.KeyChar
                    Write-Host -NoNewline $key.KeyChar
                }
            } elseif ($reachJob -or $reachJobRest) {
                # Only sleep while background jobs are running
                Start-Sleep -Milliseconds 50
            }
        }
        Write-Host ''   # newline after Enter
        $choice = $inputBuffer.Trim()

        $n        = if ($Script:FltDisplayTargets) { $Script:FltDisplayTargets.Count } else { $Script:FleetTargets.Count }
        $pageSize = [Math]::Max(1, [int](Get-FltCfgValue 'ui' 'dashboardPageSize' 20))
        $maxPage  = [Math]::Max(0, [Math]::Ceiling($n / $pageSize) - 1)

        # Sort picker — *
        if ($choice -eq '*') {
            Invoke-FltSortPicker -Columns $sortCols -Properties $sortProps -State $Script:FltTargetSort | Out-Null
            $Script:FltDashPage = 0
            # Persist the new sort order to targets.local.json
            if ($Script:FltTargetSort.SortColumn) {
                $sorted = @(Invoke-FltSort -Items $Script:FleetTargets `
                    -Column $Script:FltTargetSort.SortColumn -Descending $Script:FltTargetSort.SortDesc)
                Save-FltTargets -Targets $sorted | Out-Null
                $Script:FleetTargets = $sorted
            }
            & $repaint
            continue
        }

        # Filter picker — /
        if ($choice -eq '/') {
            Invoke-FltFilterPicker -Columns $sortCols -Properties $sortProps -State $Script:FltTargetFilter | Out-Null
            $Script:FltDashPage = 0
            & $repaint
            continue
        }

        # Page navigation — numpad - (prev) and + (next)
        if ($choice -eq '-') {
            $Script:FltDashPage = [Math]::Max(0, $Script:FltDashPage - 1)
            $Script:FltMenuResultLines = @()
            & $repaint
            continue
        }
        if ($choice -eq '+') {
            $Script:FltDashPage = [Math]::Min($maxPage, $Script:FltDashPage + 1)
            $Script:FltMenuResultLines = @()
            & $repaint
            continue
        }

        if ($choice -notmatch '^\d+$' -and $choice -notin @('-','+','*','/')) {
            $Script:FltMenuResultLines = @('Please enter a number, - (prev page), + (next), * (sort), / (filter).')
            & $repaint
            continue
        }

        $num = [int]$choice

        if ($num -eq 0) {
            Write-Host ''
            Write-Host '  Goodbye.' -ForegroundColor Cyan
            return
        }

        # 11..10+n — target selected: index into display order (sorted/filtered)
        if ($num -ge 11 -and $num -le (10 + $n)) {
            $tgt = $Script:FltDisplayTargets[$num - 11]
            $Script:FltMenuResultLines = @(
                "$($tgt.Name)  ($($tgt.Address))  — enter action for Config:",
                '1. Verify   2. Edit   3. Remove   0. Cancel'
            )
            & $repaint
            Write-Host ''
            $verb = (Read-Host '  Action').Trim()

            if ($verb -eq '1') {
                $ok = Test-FleetTargetVerify -Name $tgt.Name
                $Script:FltMenuResultLines = @(if ($ok) { "Verified: $($tgt.Name) -- OK" } else { "Verify FAILED: $($tgt.Name)" })
                $Script:FltMenuLastCmd = "tcpkg remote verify $($tgt.Name)"
                $reachJob = Invoke-FltReloadTargets $reachJob

            } elseif ($verb -eq '2') {
                Invoke-TargetMenu -Target $tgt
                $reachJob = Invoke-FltReloadTargets $reachJob
                $Script:FltMenuResultLines = @("Target '$($tgt.Name)' updated.")

            } elseif ($verb -eq '3') {
                $Script:FltMenuResultLines = @("Remove '$($tgt.Name)'?  1. Yes  0. No")
                & $repaint
                $confirm = $null
                while (-not $confirm) {
                    if ([Console]::KeyAvailable) { $confirm = [Console]::ReadKey($true).KeyChar }
                    else { Start-Sleep -Milliseconds 100 }
                }
                Write-Host $confirm
                if ($confirm -eq '1') {
                    $ok = Remove-FleetTarget -Name $tgt.Name
                    $Script:FltMenuLastCmd = "tcpkg remote remove $($tgt.Name)"
                    $Script:FltMenuResultLines = @(if ($ok) { "Removed: $($tgt.Name)" } else { "Remove FAILED: $($tgt.Name)" })
                    $reachJob = Invoke-FltReloadTargets $reachJob
                } else {
                    $Script:FltMenuResultLines = @()
                }
            } else {
                $Script:FltMenuResultLines = @()
            }

            & $repaint
            continue
        }

        # Fixed operations
        if ($num -eq 1) { Invoke-TcpkgMenu;          $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 2) { Invoke-WinGetMenu;      $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 3) { Invoke-LinuxAdminMenu;  $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 4) { Invoke-ContainerAdminMenu; $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 5) { Invoke-ProfileMenu }
        elseif ($num -eq 6) { Invoke-UiConfigMenu }
        elseif ($num -eq 7) { Invoke-SetupMenu;       $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 8) { Invoke-SystemMenu;      $reachJob = Invoke-FltReloadTargets $reachJob }
        else {
            $Script:FltMenuResultLines = @("Enter 11-$(10+$n) for a target, 1-8 for operations, 0 to exit.")
        }

        & $repaint
    }
}