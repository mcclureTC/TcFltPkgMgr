# =============================================================================
#  TcFltPkgMgr — Fleet Menu (Home Screen)
#  The fleet is the home screen. Targets are the primary context.
#  Operations are actions performed on selected targets.
#  The dashboard is always visible; only the content zone below it changes.
# =============================================================================

function Invoke-FleetMenu {
    # Load fleet targets
    $Script:FleetTargets = @(Get-FleetTargets -Silent)

    $Script:FltMenuLastCmd     = ''
    $Script:FltMenuResultLines = @()

    # Kick off a background reachability check
    $reachJob = Start-Job -ScriptBlock {
        param($targets, $cfgPath)
        # minimal inline check — no module imports needed for TCP
        $results = @()
        foreach ($t in $targets) {
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $ar  = $tcp.BeginConnect($t.Address, $t.Port, $null, $null)
                $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
                $tcp.Close()
                $results += [pscustomobject]@{ Name = $t.Name; Reachable = $ok }
            } catch {
                $results += [pscustomobject]@{ Name = $t.Name; Reachable = $false }
            }
        }
        return $results
    } -ArgumentList $Script:FleetTargets, ''

    # Mark all targets as 'checking' while the background job runs
    foreach ($t in $Script:FleetTargets) { $t.Reachable = 'checking' }
    Show-FleetDashboard -Targets $Script:FleetTargets `
        -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines

    while ($true) {
        # Poll reachability job non-blockingly
        if ($reachJob -and $reachJob.State -in @('Completed','Failed')) {
            if ($reachJob.State -eq 'Completed') {
                $reachResults = Receive-Job $reachJob
                foreach ($r in $reachResults) {
                    $tgt = $Script:FleetTargets | Where-Object { $_.Name -eq $r.Name } | Select-Object -First 1
                    if ($tgt) { $tgt.Reachable = if ($r.Reachable) { 'online' } else { 'offline' } }
                }
            }
            Remove-Job $reachJob -Force
            $reachJob = $null
            Show-FleetDashboard -Targets $Script:FleetTargets `
                -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines
        }

        $choice = (Read-Host '  Choice').Trim()
        $n      = $Script:FleetTargets.Count

        if ($choice -notmatch '^\d+$') {
            $Script:FltMenuResultLines = @('Please enter a number.')
            Show-FleetDashboard -Targets $Script:FleetTargets `
                -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines
            continue
        }

        $num = [int]$choice

        if ($num -eq 0) {
            Write-Host ''
            Write-Host '  Goodbye.' -ForegroundColor Cyan
            return
        }

        # 11..10+n — target selected: show per-target actions
        if ($num -ge 11 -and $num -le (10 + $n)) {
            $tgt = $Script:FleetTargets[$num - 11]
            $Script:FltMenuResultLines = @(
                "$($tgt.Name)  ($($tgt.Address))  Internet: $(if ($tgt.InternetAccess) {'Yes'} else {'No'})",
                '1. Verify   2. Edit   3. Remove   0. Cancel'
            )
            Show-FleetDashboard -Targets $Script:FleetTargets `
                -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines
            $verb = (Read-Host '  Action').Trim()

            if ($verb -eq '1') {
                $ok = Test-FleetTargetVerify -Name $tgt.Name
                $Script:FltMenuResultLines = @(if ($ok) { "Verified: $($tgt.Name) -- OK" } else { "Verify FAILED: $($tgt.Name)" })
                $Script:FltMenuLastCmd = "tcpkg remote verify $($tgt.Name)"
                $Script:FleetTargets = @(Get-FleetTargets -Silent)

            } elseif ($verb -eq '2') {
                Invoke-TargetMenu -Target $tgt
                $Script:FleetTargets = @(Get-FleetTargets -Silent)
                $Script:FltMenuResultLines = @("Target '$($tgt.Name)' updated.")

            } elseif ($verb -eq '3') {
                $Script:FltMenuResultLines = @("Remove '$($tgt.Name)'?  1. Yes  0. No")
                Show-FleetDashboard -Targets $Script:FleetTargets `
                    -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines
                $confirm = (Read-Host '  Choice').Trim()
                if ($confirm -eq '1') {
                    $ok = Remove-FleetTarget -Name $tgt.Name
                    $Script:FltMenuLastCmd = "tcpkg remote remove $($tgt.Name)"
                    $Script:FltMenuResultLines = @(if ($ok) { "Removed: $($tgt.Name)" } else { "Remove FAILED: $($tgt.Name)" })
                    $Script:FleetTargets = @(Get-FleetTargets -Silent)
                } else {
                    $Script:FltMenuResultLines = @()
                }
            } else {
                $Script:FltMenuResultLines = @()
            }

            Show-FleetDashboard -Targets $Script:FleetTargets `
                -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines
            continue
        }

        # Fixed operations
        if ($num -eq 1) { Invoke-FleetInstallMenu;   $Script:FleetTargets = @(Get-FleetTargets -Silent) }
        elseif ($num -eq 2) { Invoke-FleetUpgradeMenu;   $Script:FleetTargets = @(Get-FleetTargets -Silent) }
        elseif ($num -eq 3) { Invoke-FleetUninstallMenu; $Script:FleetTargets = @(Get-FleetTargets -Silent) }
        elseif ($num -eq 4) { Invoke-PackageStatusMenu }
        elseif ($num -eq 5) { Invoke-OutdatedCheckMenu }
        elseif ($num -eq 6) { Invoke-ProfileMenu }
        elseif ($num -eq 7) { Invoke-SetupMenu; $Script:FleetTargets = @(Get-FleetTargets -Silent) }
        else {
            $Script:FltMenuResultLines = @("Enter 11-$(10+$n) for a target, 1-7 for operations, 0 to exit.")
        }

        Show-FleetDashboard -Targets $Script:FleetTargets `
            -LastCommand $Script:FltMenuLastCmd -ResultLines $Script:FltMenuResultLines
    }
}