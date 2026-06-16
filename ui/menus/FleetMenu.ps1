# =============================================================================
#  TcFltPkgMgr — Fleet Menu (Home Screen)
#  The fleet is the home screen. Targets are the primary context.
#  Operations are actions performed on selected targets.
#  The dashboard is always visible; only the content zone below it changes.
# =============================================================================

# Start a background TCP reachability check for a list of targets.
# Uses ForEach-Object -Parallel so all targets are checked simultaneously
# rather than sequentially — critical at 100+ targets where sequential
# checks with a 2s timeout would take up to 200s.
# Returns a Job object. Results are [pscustomobject]@{ Name; Reachable }.
function Start-FltReachJob {
    param([FleetTarget[]]$Targets)
    $addrs    = @($Targets | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Address=$_.Address; Port=$_.Port } })
    $throttle = [Math]::Min(50, [int](Get-FltCfgValue 'ssh' 'throttleLimit' 25))

    # ThreadJob runs in the same process — no serialization issues with pscustomobject arrays.
    # ForEach-Object -Parallel checks all targets simultaneously rather than sequentially.
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

# Reload targets from tcpkg, preserve prior reachability state, start new check.
# Returns the new reachability job.
function Invoke-FltReloadTargets {
    param([object]$ReachJob)
    # Cancel any running job
    if ($ReachJob) { Remove-Job $ReachJob -Force -ErrorAction SilentlyContinue }

    # Capture prior reachability before reloading
    $priorReach = @{}
    foreach ($t in $Script:FleetTargets) { $priorReach[$t.Name] = $t.Reachable }

    # Reload fresh from tcpkg
    $Script:FleetTargets = @(Get-FleetTargets -Silent)

    # Restore prior status so dashboard doesn't flash 'unknown'
    foreach ($t in $Script:FleetTargets) {
        $t.Reachable = if ($priorReach.ContainsKey($t.Name)) { $priorReach[$t.Name] } else { 'checking' }
    }

    # Mark all as 'checking' and kick off a new job
    foreach ($t in $Script:FleetTargets) { $t.Reachable = 'checking' }
    return Start-FltReachJob $Script:FleetTargets
}

function Invoke-FleetMenu {
    # Load fleet targets and start initial reachability check
    $Script:FleetTargets       = @(Get-FleetTargets -Silent)
    $names = ($Script:FleetTargets | ForEach-Object { $_.Name }) -join ', '
    $Script:FltMenuLastCmd     = ''
    $Script:FltMenuResultLines = @()
    $Script:FltDashPage        = 0
    # Sort/filter state persists — initialized in TcFltPkgMgr.ps1, not reset here
    $reachJob                  = Start-FltReachJob $Script:FleetTargets

    # Column definitions for sort/filter pickers
    $sortCols  = @('Name','Address','Port','Internet Access','Status')
    $sortProps = @('Name','Address','Port','InternetAccess','Reachable')

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

    # Mark all targets as 'checking' while the background job runs
    foreach ($t in $Script:FleetTargets) { $t.Reachable = 'checking' }
    & $repaint

    while ($true) {
        # Non-blocking input loop — polls reachability job while waiting for keypress
        $inputBuffer = ''
        while ($true) {
            # Check reachability job
            if ($reachJob -and $reachJob.State -in @('Completed','Failed')) {
                if ($reachJob.State -eq 'Completed') {
                    $reachResults = Receive-Job $reachJob
                    foreach ($r in $reachResults) {
                        $tgt = $Script:FleetTargets | Where-Object { $_.Name -eq $r.Name } | Select-Object -First 1
                        if ($tgt) { $tgt.Reachable = if ($r.Reachable) { 'online' } else { 'offline' } }
                    }
                    # Repaint dashboard then restore prompt and any typed chars
                    Show-FleetDashboard -Targets $Script:FleetTargets -Page $Script:FltDashPage `
                        -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines `
                        -SortState $Script:FltTargetSort -FilterState $Script:FltTargetFilter
                    Write-Host -NoNewline "  Choice: $inputBuffer"
                }
                Remove-Job $reachJob -Force
                $reachJob = $null
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
            } elseif ($reachJob) {
                # Only sleep while the background job is running
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
        if ($num -eq 1) { Invoke-FleetInstallMenu;   $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 2) { Invoke-FleetUpgradeMenu;   $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 3) { Invoke-FleetUninstallMenu; $reachJob = Invoke-FltReloadTargets $reachJob }
        elseif ($num -eq 4) { Invoke-PackageStatusMenu }
        elseif ($num -eq 5) { Invoke-OutdatedCheckMenu }
        elseif ($num -eq 6) { Invoke-ProfileMenu }
        elseif ($num -eq 7) { Invoke-UiConfigMenu }
        elseif ($num -eq 8) { Invoke-SetupMenu; $reachJob = Invoke-FltReloadTargets $reachJob }
        else {
            $Script:FltMenuResultLines = @("Enter 11-$(10+$n) for a target, 1-8 for operations, 0 to exit.")
        }

        & $repaint
    }
}