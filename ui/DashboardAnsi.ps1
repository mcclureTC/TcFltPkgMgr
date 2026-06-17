# =============================================================================
#  TcFltPkgMgr — ANSI Dashboard Backend
#  Pure ANSI cursor-positioning implementation of the display interface.
#  Do NOT dot-source this file directly — load via DisplayBackends.ps1.
#
#  All public functions are prefixed _Ansi_ to distinguish them from the
#  stable adapter interface in DisplayAdapter.ps1.
#
#  Safe-width rule: always use $sw = $w - 1 to prevent terminal auto-wrap
#  which injects phantom newlines that misalign absolute-positioned rows.
# =============================================================================

# ── Low-level paint primitives ────────────────────────────────────────────────

function _Ansi_GetSafeWidth {
    return [Math]::Max([Console]::WindowWidth, 60) - 1
}

function _Ansi_PaintRow {
    param([int]$Row, [string]$Text, [string]$Fg = '')
    $sw   = _Ansi_GetSafeWidth
    if     ($Fg -eq 'Green')  { $open = "`e[92m" }
    elseif ($Fg -eq 'Yellow') { $open = "`e[93m" }
    elseif ($Fg -eq 'Red')    { $open = "`e[91m" }
    elseif ($Fg -eq 'Cyan')   { $open = "`e[96m" }
    elseif ($Fg -eq 'Dark')   { $open = "`e[90m" }
    elseif ($Fg -eq 'Bold')   { $open = "`e[1m"  }
    elseif ($Fg -eq 'White')  { $open = "`e[97m" }
    else                       { $open = ''       }
    $close = if ($open) { "`e[0m" } else { '' }
    if ($Text.Length -gt $sw) { $Text = $Text.Substring(0, $sw) }
    Write-Host -NoNewline "`e[${Row};1H${open}${Text}${close}`e[K"
}

function _Ansi_PaintTitleBar {
    param([int]$Row, [string]$Title)
    $sw   = _Ansi_GetSafeWidth
    $mode = if ($Script:FltReadOnly) { '[READ-ONLY]' } else { '[LIVE]' }
    $left = " TcFlt Package Manager  |  $Title"
    $bar  = ($left.PadRight($sw - $mode.Length - 2) + "  $mode").PadRight($sw)
    _Ansi_PaintRow $Row $bar 'Bold'
}

# ── Fleet home screen dashboard ───────────────────────────────────────────────

function _Ansi_ShowFleetDashboard {
    param(
        [FleetTarget[]] $Targets,
        [string[]]      $ResultLines = @(),
        [string]        $LastCommand = '',
        [int]           $Page        = 0,
        [hashtable]     $SortState   = $null,
        [hashtable]     $FilterState = $null
    )
    $sw       = _Ansi_GetSafeWidth
    $total    = $Targets.Count

    # Apply filter then sort before slicing for page
    $display = if ($FilterState -and $FilterState.FilterColumn) {
        @(Invoke-FltFilter -Items $Targets -Column $FilterState.FilterColumn -Value $FilterState.FilterValue)
    } else { @($Targets) }

    if ($SortState -and $SortState.SortColumn) {
        $display = @(Invoke-FltSort -Items $display -Column $SortState.SortColumn -Descending $SortState.SortDesc)
    }

    $filteredCount = $display.Count
    $pageSize      = [Math]::Max(1, [int](Get-FltCfgValue 'ui' 'dashboardPageSize' 20))
    $totalPages    = [Math]::Max(1, [Math]::Ceiling($filteredCount / $pageSize))
    $page          = [Math]::Max(0, [Math]::Min($page, $totalPages - 1))
    $offset        = $page * $pageSize
    $pageTargets   = @($display | Select-Object -Skip $offset -First $pageSize)
    $n             = $pageTargets.Count

    $maxResult = 4
    $Script:FltDashHeight = 1 + 1 + $n + 1 + 1 + 2 + 1 + $maxResult + 1

    Clear-Host
    _Ansi_PaintTitleBar 1 'Fleet'

    $nameColW = [Math]::Min(24, [Math]::Max(14,
        ($Targets | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum ?? 14))

    # Column headers with sort indicators
    $hName   = Get-FltSortHeader 'Target'   'Name'           $SortState
    $hOS     = Get-FltSortHeader 'OS'       'OS'             $SortState
    $hType   = Get-FltSortHeader 'Type'     'TargetType'     $SortState
    $hHost   = Get-FltSortHeader 'Address'  'Address'        $SortState
    $hPort   = Get-FltSortHeader 'Port'     'Port'           $SortState
    $hIA     = Get-FltSortHeader 'Internet' 'InternetAccess' $SortState
    $hStatus = Get-FltSortHeader 'Status'   'Reachable'      $SortState
    _Ansi_PaintRow 2 ('  {0,3}  {1} {2,-4} {3,-5} {4,-18} {5,-6} {6,-8} {7}' -f `
        '#', $hName.PadRight($nameColW), $hOS, $hType, $hHost, $hPort, $hIA, $hStatus) 'Dark'

    for ($i = 0; $i -lt $n; $i++) {
        $t      = $pageTargets[$i]
        # Global number = position in filtered+sorted display, not raw $Targets
        $num    = 11 + $offset + $i
        $os   = if ($t.OS -eq 'linux') { 'Lnx' } elseif ($t.OS -eq 'macos') { 'Mac' } else { 'Win' }
        $type = if ($t.TargetType -eq 'container') { 'Cntr' } elseif ($t.TargetType -eq 'vm') { 'VM' } else { 'Phys' }
        $addr = if ($t.TargetType -eq 'container' -and $t.DockerHost -and $t.ContainerName) {
            "$($t.DockerHost)/$($t.ContainerName)"
        } else { $t.Address }

        # Internet Access: show '---' for Linux and container targets —
        # they manage their own internet access and don't use push-from-local
        $ia = if ($t.OS -eq 'linux' -or $t.OS -eq 'macos' -or $t.TargetType -eq 'container') {
            '---'
        } elseif ($t.InternetAccess) { 'Yes' } else { 'No' }

        $icon   = $t.ReachableIcon()
        $status = "$icon $($t.Reachable)"

        # Row colour: Linux = Cyan, Container = Magenta, Windows = by reachability
        $rowClr = if ($t.TargetType -eq 'container') { 'Magenta' }
                  elseif ($t.OS -eq 'linux' -or $t.OS -eq 'macos') { 'Cyan' }
                  elseif ($t.Reachable -eq 'online')  { 'Green' }
                  elseif ($t.Reachable -eq 'offline') { 'Red'   }
                  else                                 { 'Dark'  }

        $line = '  {0,3}. {1} {2,-4} {3,-5} {4,-18} {5,-6} {6,-8} {7}' -f `
                $num, $t.Name.PadRight($nameColW), $os, $type, $addr, $t.Port, $ia, $status
        _Ansi_PaintRow (3 + $i) $line $rowClr
    }

    $sepRow1   = 3 + $n
    $footerRow = $sepRow1 + 1
    $navRow    = $footerRow + 1
    $sepRow2   = $navRow + 1
    $cmdRow    = $sepRow2 + 1

    _Ansi_PaintRow $sepRow1   ('-' * $sw) 'Dark'
    _Ansi_PaintRow $footerRow '  1. Install   2. Upgrade   3. Uninstall   4. Status   5. Outdated   6. Profiles   7. UI Config   8. Setup   0. Exit' 'Dark'

    # Nav row: pagination info + sort/filter hints
    $navParts = @()
    if ($totalPages -gt 1) {
        $pageInfo = "Page $($page + 1) of $totalPages"
        if ($page -gt 0)              { $pageInfo += "  [-]" }
        if ($page -lt $totalPages-1)  { $pageInfo += "  [+]" }
        $firstNum = $offset + 11
        $lastNum  = $offset + $n + 10
        $pageInfo += "  ($firstNum-$lastNum of $filteredCount)"
        $navParts += $pageInfo
    }
    if ($FilterState -and $FilterState.FilterColumn) {
        $navParts += "[Filter: $($FilterState.FilterColumn)='$($FilterState.FilterValue)']  $total→$filteredCount"
    }
    $navParts += "[*] Sort  [/] Filter"

    _Ansi_PaintRow $navRow ("  " + ($navParts -join "   ")) 'Dark'

    _Ansi_PaintRow $sepRow2   ('-' * $sw) 'Dark'

    $cmdText = if ($LastCommand) { "  > $LastCommand" } else { '' }
    _Ansi_PaintRow $cmdRow $cmdText 'Dark'

    for ($i = 0; $i -lt $maxResult; $i++) {
        $resRow  = $cmdRow + 1 + $i
        $resText = if ($i -lt $ResultLines.Count) { "  $($ResultLines[$i])" } else { '' }
        $resClr  = if ($resText -match 'OK|uccess|online')         { 'Green' }
                   elseif ($resText -match 'FAIL|[Ee]rror|offline') { 'Red'   }
                   else                                              { ''      }
        _Ansi_PaintRow $resRow $resText $resClr
    }

    _Ansi_PaintRow $Script:FltDashHeight '' ''
    Write-Host -NoNewline "`e[$($Script:FltDashHeight);1H"
}

# ── Setup menu dashboard ──────────────────────────────────────────────────────

function _Ansi_ShowSetupDashboard {
    param(
        [string]    $Mode       = 'targets',
        [object[]]  $Items      = @(),
        [string]    $Result     = '',
        [string]    $LastCmd    = '',
        [hashtable] $SortState  = $null,
        [hashtable] $FilterState = $null
    )
    $sw = _Ansi_GetSafeWidth

    # Apply filter then sort
    $display = if ($FilterState -and $FilterState.FilterColumn) {
        @(Invoke-FltFilter -Items $Items -Column $FilterState.FilterColumn -Value $FilterState.FilterValue)
    } else { @($Items) }

    if ($SortState -and $SortState.SortColumn) {
        $display = @(Invoke-FltSort -Items $display -Column $SortState.SortColumn -Descending $SortState.SortDesc)
    }
    $n = if ($display) { $display.Count } else { 0 }

    Clear-Host
    _Ansi_PaintTitleBar 1 "Setup  >  $(if ($Mode -eq 'sources') { 'Sources / Feeds' } else { 'Targets' })"

    if ($Mode -eq 'sources') {
        $hPri  = Get-FltSortHeader 'Pri'   'Pri'   $SortState
        $hName = Get-FltSortHeader 'Name'  'Name'  $SortState
        $hSt   = Get-FltSortHeader 'State' 'State' $SortState
        _Ansi_PaintRow 2 ('  {0,3}  {1,-24} {2,-8} {3,-16} {4}' -f $hPri,$hName,$hSt,'Auth','URL') 'Dark'
        for ($i = 0; $i -lt $n; $i++) {
            $s   = $display[$i]
            $clr = if ($s.State -eq 'enabled') { 'Green' } else { 'Dark' }
            $url = $s.Url
            $avail = $sw - 60; if ($avail -lt 10) { $avail = 10 }
            if ($url.Length -gt $avail) { $url = $url.Substring(0, $avail - 1) + '~' }
            _Ansi_PaintRow (3 + $i) ('  {0,3}. {1,-24} {2,-8} {3,-16} {4}' -f `
                ($i + 11), $s.Name, $s.State, $s.Auth, $url) $clr
        }
        if ($n -eq 0) { _Ansi_PaintRow 3 '  (no sources configured)' 'Dark' }
    } else {
        $hName = Get-FltSortHeader 'Name'     'Name'           $SortState
        $hOS   = Get-FltSortHeader 'OS'       'OS'             $SortState
        $hType = Get-FltSortHeader 'Type'     'TargetType'     $SortState
        $hAddr = Get-FltSortHeader 'Address'  'Address'        $SortState
        $hPort = Get-FltSortHeader 'Port'     'Port'           $SortState
        $hIA   = Get-FltSortHeader 'Internet' 'InternetAccess' $SortState
        _Ansi_PaintRow 2 ('  {0,3}  {1,-22} {2,-4} {3,-5} {4,-18} {5,-6} {6}' -f `
            '#', $hName, $hOS, $hType, $hAddr, $hPort, $hIA) 'Dark'
        for ($i = 0; $i -lt $n; $i++) {
            $t    = $display[$i]
            $os   = if ($t.OS -eq 'linux') { 'Lnx' } elseif ($t.OS -eq 'macos') { 'Mac' } else { 'Win' }
            $type = if ($t.TargetType -eq 'container') { 'Cntr' } elseif ($t.TargetType -eq 'vm') { 'VM' } else { 'Phys' }
            $addr = if ($t.TargetType -eq 'container' -and $t.DockerHost -and $t.ContainerName) {
                "$($t.DockerHost)/$($t.ContainerName)"
            } else { $t.Address }
            $ia   = if ($t.OS -eq 'linux' -or $t.OS -eq 'macos' -or $t.TargetType -eq 'container') {
                '---'
            } elseif ($t.InternetAccess) { 'Yes' } else { 'No' }
            $rowClr = if ($t.TargetType -eq 'container')                          { 'Magenta' }
                      elseif ($t.OS -eq 'linux' -or $t.OS -eq 'macos')            { 'Cyan'    }
                      else                                                         { ''        }
            _Ansi_PaintRow (3 + $i) ('  {0,3}. {1,-22} {2,-4} {3,-5} {4,-18} {5,-6} {6}' -f `
                ($i + 11), $t.Name, $os, $type, $addr, $t.Port, $ia) $rowClr
        }
        if ($n -eq 0) { _Ansi_PaintRow 3 '  (no remote targets configured)' 'Dark' }
    }

    $sepRow    = [Math]::Max(4, 3 + $n)
    $footerRow = $sepRow + 1
    $navRow    = $footerRow + 2
    $sepRow2   = $navRow + 1
    $resultRow = $sepRow2 + 1
    $promptRow = $resultRow + 1

    _Ansi_PaintRow $sepRow    ('-' * $sw) 'Dark'
    _Ansi_PaintRow $footerRow '  1. Add target   2. Import CSV   3. Export CSV   4. Sources   5. Gen config' 'Dark'
    _Ansi_PaintRow ($footerRow + 1) '  6. Export config   7. Import config   8. Log   9. Read-only   10. Diagnostics   11+. Select   0. Back' 'Dark'

    # Nav row with sort/filter hints
    $navParts = @()
    if ($FilterState -and $FilterState.FilterColumn) {
        $navParts += "[Filter: $($FilterState.FilterColumn)='$($FilterState.FilterValue)']  $($Items.Count)→$n"
    }
    $navParts += "[*] Sort  [/] Filter"
    _Ansi_PaintRow $navRow ("  " + ($navParts -join "   ")) 'Dark'
    _Ansi_PaintRow $sepRow2   ('-' * $sw) 'Dark'

    $cmdText = if ($LastCmd) { "  > $LastCmd" } else { '' }
    _Ansi_PaintRow $resultRow $cmdText 'Dark'

    if ($Result) {
        $clr = if ($Result -match 'OK|uccess|xport|mport|reated') { 'Green' }
               elseif ($Result -match 'fail|error|not found')      { 'Red'   }
               else                                                 { ''      }
        _Ansi_PaintRow $resultRow "  $Result" $clr
    }

    _Ansi_PaintRow $promptRow '' ''
    Write-Host -NoNewline "`e[${promptRow};1H"
}

# ── Sources dashboard ─────────────────────────────────────────────────────────

function _Ansi_ShowSourcesDashboard {
    param(
        [object[]] $Sources,
        [string]   $LastCommand = '',
        [string]   $ResultLine  = ''
    )
    $sw = _Ansi_GetSafeWidth
    $n  = if ($Sources) { $Sources.Count } else { 0 }

    Clear-Host
    _Ansi_PaintTitleBar 1 'Setup  >  Sources / Feeds'
    _Ansi_PaintRow 2 ('  {0,3}  {1,-24} {2,-8} {3,-16} {4}' -f 'Pri','Name','State','Auth','URL') 'Dark'

    for ($i = 0; $i -lt $n; $i++) {
        $s    = $Sources[$i]
        $clr  = if ($s.State -eq 'enabled') { 'Green' } else { 'Dark' }
        $num  = 11 + $i
        $url  = $s.Url
        $avail = $sw - 58; if ($avail -lt 10) { $avail = 10 }
        if ($url.Length -gt $avail) { $url = $url.Substring(0, $avail - 1) + '~' }
        _Ansi_PaintRow (3 + $i) ('  {0,3}. {1,-24} {2,-8} {3,-16} {4}' -f `
            $num, $s.Name, $s.State, $s.Auth, $url) $clr
    }

    if ($n -eq 0) { _Ansi_PaintRow 3 '  (no sources configured)' 'Dark' }

    $sepRow    = [Math]::Max(4, 3 + $n)
    $footerRow = $sepRow + 1
    $sepRow2   = $footerRow + 1
    $cmdRow    = $sepRow2 + 1
    $promptRow = $cmdRow + 1

    $Script:FltSourceDashHeight = $promptRow

    _Ansi_PaintRow $sepRow    ('-' * $sw) 'Dark'
    _Ansi_PaintRow $footerRow '  1. Add Beckhoff preset   2. Add custom   11+. Enable/Disable   0. Back' 'Dark'
    _Ansi_PaintRow $sepRow2   ('-' * $sw) 'Dark'

    $cmdText = if ($LastCommand) { "  > $LastCommand" } else { '' }
    _Ansi_PaintRow $cmdRow $cmdText 'Dark'

    if ($ResultLine) {
        $resClr = if ($ResultLine -match 'OK|uccess|dded|abled') { 'Green' }
                  elseif ($ResultLine -match 'FAIL|[Ee]rror')    { 'Red'   }
                  else                                            { ''      }
        _Ansi_PaintRow $cmdRow "  $ResultLine" $resClr
    }

    _Ansi_PaintRow $promptRow '' ''
    Write-Host -NoNewline "`e[${promptRow};1H"
}

# ── Package status dashboard ──────────────────────────────────────────────────

function _Ansi_ShowPackageStatusDashboard {
    param(
        [FleetPackageSummary] $Summary,
        [FleetTarget[]]       $AllTargets
    )
    $sw = _Ansi_GetSafeWidth
    $n  = $AllTargets.Count

    $stateMap = @{}
    foreach ($s in $Summary.States) { $stateMap[$s.TargetName] = $s }

    $nameColW = [Math]::Min(24, [Math]::Max(14,
        ($AllTargets | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum ?? 14))

    Clear-Host
    _Ansi_PaintTitleBar 1 "Package: $($Summary.PackageName)"

    $feedInfo = if ($Summary.FeedVersion) { "Feed version: $($Summary.FeedVersion)" } else { 'Feed version: (not specified)' }
    _Ansi_PaintRow 2 "  $feedInfo   Source: $($Summary.FeedSource)" 'Dark'

    $pkgHdr = '  {0,3}  {1} {2,-16} {3,-16} {4}' -f '#', 'Target'.PadRight($nameColW), 'Installed', 'Feed', 'Status'
    _Ansi_PaintRow 3 $pkgHdr 'Dark'

    for ($i = 0; $i -lt $n; $i++) {
        $t    = $AllTargets[$i]
        $s    = $stateMap[$t.Name]
        $inst = if ($s) { $s.InstalledVersion } else { '?' }
        $feed = $Summary.FeedVersion
        $stat = if ($s) { $s.Status } else { 'unknown' }
        if     ($stat -eq 'up-to-date')      { $clr = 'Green'  }
        elseif ($stat -eq 'upgradable')      { $clr = 'Yellow' }
        elseif ($stat -eq 'not-installed')   { $clr = 'Dark'   }
        elseif ($stat -eq 'newer-than-feed') { $clr = 'Cyan'   }
        else                                  { $clr = ''       }
        $line = '  {0,3}. {1} {2,-16} {3,-16} {4}' -f (11 + $i), $t.Name.PadRight($nameColW), $inst, $feed, $stat
        _Ansi_PaintRow (4 + $i) $line $clr
    }

    $sepRow    = 4 + $n
    $footerRow = $sepRow + 1
    _Ansi_PaintRow $sepRow    ('-' * $sw) 'Dark'
    _Ansi_PaintRow $footerRow '  1. Install/Upgrade selected   2. Upgrade all outdated   0. Back   |   enter 11+ to select target' 'Dark'

    $Script:FltDashHeight = $footerRow + 2
    _Ansi_PaintRow $Script:FltDashHeight '' ''
    Write-Host -NoNewline "`e[$($Script:FltDashHeight);1H"
}

# ── Batch execution dashboard ─────────────────────────────────────────────────

function _Ansi_ShowFleetBatchDashboard {
    param(
        [FleetTarget[]] $Targets,
        [string]        $Action,
        [string]        $PackageSpec,
        [string]        $Mode,
        [int]           $TimeoutSecs = 0
    )
    $sw         = _Ansi_GetSafeWidth
    $n          = $Targets.Count
    $maxResult  = 4
    $headerRows = 7

    $Script:FltBatchDashHeight  = $headerRows + $n + 1 + 1 + $maxResult + 1
    $Script:FltBatchScrollStart = $Script:FltBatchDashHeight + 1

    $Script:FltBatchStatus = @{}
    for ($i = 0; $i -lt $n; $i++) {
        $Script:FltBatchStatus[$Targets[$i].Name] = @{
            Status   = 'Pending'
            Duration = 0.0
            Note     = ''
            Row      = $headerRows + 1 + $i
        }
    }

    Clear-Host
    _Ansi_PaintTitleBar 1 'Batch operation'
    _Ansi_PaintRow 2 "  Action: $($Action.ToUpper())   Package: $PackageSpec" 'Cyan'

    $modeStr = "  Mode: $Mode"
    if ($TimeoutSecs -gt 0) { $modeStr += "   Timeout: ${TimeoutSecs} s" }
    _Ansi_PaintRow 3 $modeStr 'Dark'

    $remoteTcpkg = (Get-FltCfgValue 'tcpkg' 'remoteTcpkgPath' 'TcPkg.exe')
    _Ansi_PaintRow 4 "  > `"$remoteTcpkg`" $Action $PackageSpec -y" 'Dark'
    _Ansi_PaintRow 5 ('-' * $sw) 'Dark'
    _Ansi_PaintRow 6 ('  {0,-22} {1,-14} {2,9}  {3}' -f 'Target','Status','Duration','Note') 'Dark'
    _Ansi_PaintRow 7 ('-' * $sw) 'Dark'

    for ($i = 0; $i -lt $n; $i++) {
        _Ansi_PaintRow (8 + $i) ('  {0,-22} {1,-14}' -f $Targets[$i].Name, 'Pending') ''
    }

    _Ansi_PaintRow ($headerRows + $n + 1) ('-' * $sw) 'Dark'
    _Ansi_PaintRow ($headerRows + $n + 2) '  Pending...' 'Dark'
    _Ansi_PaintRow $Script:FltBatchDashHeight '' ''
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
}

function _Ansi_UpdateBatchRow {
    param([string]$TargetName, [string]$Status, [double]$Duration = 0, [string]$Note = '')
    if (-not $Script:FltBatchStatus.ContainsKey($TargetName)) { return }

    $st = $Script:FltBatchStatus[$TargetName]
    $st.Status   = $Status
    $st.Duration = $Duration
    $st.Note     = $Note

    $sw     = _Ansi_GetSafeWidth
    $row    = $st.Row
    $durStr = if ($Duration -gt 0) { '{0,7:F1} s' -f $Duration } else { '         ' }
    $line   = '  {0,-22} {1,-14} {2}  {3}' -f $TargetName, $Status, $durStr, $Note
    if ($line.Length -gt $sw) { $line = $line.Substring(0, $sw) }

    if     ($Status -like 'OK*')      { $clr = "`e[92m" }
    elseif ($Status -like 'Failed*')  { $clr = "`e[91m" }
    elseif ($Status -eq 'Timed out')  { $clr = "`e[93m" }
    elseif ($Status -like 'Running*') { $clr = "`e[96m" }
    elseif ($Status -eq 'Skipped')    { $clr = "`e[90m" }
    else                               { $clr = ''       }
    $rst = if ($clr) { "`e[0m" } else { '' }

    Write-Host -NoNewline "`e[s`e[${row};1H${clr}${line}${rst}`e[K`e[u"

    $all    = $Script:FltBatchStatus.Values
    $ok     = @($all | Where-Object { $_.Status -like 'OK*' }).Count
    $run    = @($all | Where-Object { $_.Status -like 'Running*' }).Count
    $fail   = @($all | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Timed out' }).Count
    $skip   = @($all | Where-Object { $_.Status -eq 'Skipped' }).Count
    $pend   = @($all | Where-Object { $_.Status -eq 'Pending' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumStr = "  $ok OK  |  $run running  |  $fail failed  |  $skip skipped  |  $pend pending"
    Write-Host -NoNewline "`e[s`e[${sumRow};1H`e[90m${sumStr}`e[0m`e[K`e[u"
}

# ── Simple list renderer ──────────────────────────────────────────────────────

function _Ansi_ShowFltTable {
    param(
        [object[]]    $Items,
        [hashtable[]] $Columns,
        [int]         $Base     = 11,
        [switch]      $NoNumber
    )
    if (-not $Items -or $Items.Count -eq 0) { return }
    $w = _Ansi_GetSafeWidth

    $widths = @($Columns | ForEach-Object {
        $col = $_
        $max = $col.Header.Length
        foreach ($item in $Items) {
            $raw = $item | ForEach-Object $col.Expr
            $val = if ($null -eq $raw) { '' } else { $raw.ToString() }
            if ($val.Length -gt $max) { $max = $val.Length }
        }
        [Math]::Min($max, 40)
    })

    $hdr = if ($NoNumber) { '  ' } else { '  {0,4}  ' -f '#' }
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        $w   = $widths[$c]
        $hdr += if ($Columns[$c].Align -eq 'Right') {
            $Columns[$c].Header.PadLeft($w) + '  '
        } else {
            $Columns[$c].Header.PadRight($w) + '  '
        }
    }
    Write-Host $hdr.TrimEnd() -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $row = if ($NoNumber) { '  ' } else { '  {0,4}. ' -f ($Base + $i) }
        for ($c = 0; $c -lt $Columns.Count; $c++) {
            $raw = $Items[$i] | ForEach-Object $Columns[$c].Expr
            $val = if ($null -eq $raw) { '' } else { $raw.ToString() }
            $w   = $widths[$c]
            if ($val.Length -gt $w) { $val = $val.Substring(0, $w - 1) + '~' }
            $row += if ($Columns[$c].Align -eq 'Right') {
                $val.PadLeft($w) + '  '
            } else {
                $val.PadRight($w) + '  '
            }
        }
        Write-Host $row.TrimEnd()
    }
}