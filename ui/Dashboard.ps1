# =============================================================================
#  TcFltPkgMgr — Dashboard
#  All screen-painting functions. Pure render layer — accepts typed objects,
#  paints ANSI, returns nothing. Never fetches data or prompts for input.
#
#  Safe-width rule: always use $sw = $w - 1 to prevent terminal auto-wrap
#  which injects phantom newlines that misalign absolute-positioned rows.
# =============================================================================

# ── Low-level paint primitives ────────────────────────────────────────────────

function Get-FltSafeWidth {
    return [Math]::Max([Console]::WindowWidth, 60) - 1
}

function Paint-FltRow {
    param([int]$Row, [string]$Text, [string]$Fg = '')
    $sw   = Get-FltSafeWidth
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

# Standard title bar for any dashboard panel.
function Paint-FltTitleBar {
    param([int]$Row, [string]$Title)
    $sw   = Get-FltSafeWidth
    $mode = if ($Script:FltReadOnly) { '[READ-ONLY]' } else { '[LIVE]' }
    $left = " TcFlt Package Manager  |  $Title"
    $bar  = ($left.PadRight($sw - $mode.Length - 2) + "  $mode").PadRight($sw)
    Paint-FltRow $Row $bar 'Bold'
}

# ── Fleet home screen dashboard ───────────────────────────────────────────────
#
# Layout:
#   Row 1         : title bar
#   Row 2         : column headers
#   Rows 3..2+n   : one target row (numbered 11+)
#   Row 3+n       : separator
#   Row 4+n       : fixed action footer
#   Row 5+n       : separator
#   Row 6+n       : last command
#   Rows 7+n..    : result lines (4 fixed)
#   Row 11+n      : blank — prompt row

function Show-FleetDashboard {
    param(
        [FleetTarget[]] $Targets,
        [string[]]      $ResultLines = @(),
        [string]        $LastCommand = ''
    )
    $sw = Get-FltSafeWidth
    $n  = $Targets.Count
    $maxResult = 4
    $Script:FltDashHeight = 1 + 1 + $n + 1 + 1 + 1 + 1 + $maxResult + 1

    Clear-Host

    # Row 1: title bar
    Paint-FltTitleBar 1 'Fleet'

    # Row 2: column headers
    $nameColW = [Math]::Min(24, [Math]::Max(14,
        ($Targets | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum ?? 14))
    $hdrLine = '  {0,3}  {1} {2,-18} {3,-6} {4,-8} {5}' -f `
        '#', 'Target'.PadRight($nameColW), 'Host', 'Port', 'Internet', 'Status'
    Paint-FltRow 2 $hdrLine 'Dark'

    # Rows 3..2+n: target rows (base-11)
    for ($i = 0; $i -lt $n; $i++) {
        $t      = $Targets[$i]
        $num    = 11 + $i
        $ia     = if ($t.InternetAccess) { 'Yes' } else { 'No' }
        $iaClr  = if ($t.InternetAccess) { 'Green' } else { 'Yellow' }
        $icon   = $t.ReachableIcon()
        $status = "$icon $($t.Reachable)"
        if     ($t.Reachable -eq 'online')   { $stClr = 'Green' }
        elseif ($t.Reachable -eq 'offline')  { $stClr = 'Red'   }
        else                                  { $stClr = 'Dark'  }
        $row  = 3 + $i
        $line = '  {0,3}. {1} {2,-18} {3,-6} {4,-8} {5}' -f `
                $num, $t.Name.PadRight($nameColW), $t.Address, $t.Port, $ia, $status
        # Paint line then colour the status portion in-place is complex;
        # use a single colour based on reachability for the whole row.
        Paint-FltRow $row $line $stClr
    }

    # Row 3+n: separator
    $sepRow1 = 3 + $n
    Paint-FltRow $sepRow1 ('-' * $sw) 'Dark'

    # Row 4+n: fixed action footer
    $footerRow = $sepRow1 + 1
    Paint-FltRow $footerRow '  1. Install   2. Upgrade   3. Uninstall   4. Package status   5. Outdated check   6. Profiles   7. Setup   0. Exit' 'Dark'

    # Row 5+n: separator
    $sepRow2 = $footerRow + 1
    Paint-FltRow $sepRow2 ('-' * $sw) 'Dark'

    # Row 6+n: last command
    $cmdRow = $sepRow2 + 1
    $cmdText = if ($LastCommand) { "  > $LastCommand" } else { '' }
    Paint-FltRow $cmdRow $cmdText 'Dark'

    # Rows 7+n..: result lines
    for ($i = 0; $i -lt $maxResult; $i++) {
        $resRow  = $cmdRow + 1 + $i
        $resText = if ($i -lt $ResultLines.Count) { "  $($ResultLines[$i])" } else { '' }
        $resClr  = if ($resText -match 'OK|uccess|online')  { 'Green' }
                   elseif ($resText -match 'FAIL|[Ee]rror|offline') { 'Red' }
                   else { '' }
        Paint-FltRow $resRow $resText $resClr
    }

    # Blank prompt row
    Paint-FltRow $Script:FltDashHeight '' ''
    Write-Host -NoNewline "`e[$($Script:FltDashHeight);1H"
}

# ── Sources dashboard ─────────────────────────────────────────────────────────
#
# Layout:
#   Row 1       : title bar
#   Row 2       : column headers
#   Rows 3..2+n : one source row per configured source
#   Row 3+n     : separator
#   Row 4+n     : action footer
#   Row 5+n     : separator
#   Row 6+n     : last command / result
#   Row 7+n     : prompt row

function Show-SourcesDashboard {
    param(
        [object[]] $Sources,       # pscustomobject[] with Pri, Name, State, Url, Auth
        [string]   $LastCommand = '',
        [string]   $ResultLine  = ''
    )
    $sw = Get-FltSafeWidth
    $n  = if ($Sources) { $Sources.Count } else { 0 }

    Clear-Host

    Paint-FltTitleBar 1 'Setup  >  Sources / Feeds'

    # Row 2: column headers
    Paint-FltRow 2 ('  {0,3}  {1,-24} {2,-8} {3,-16} {4}' -f `
        'Pri', 'Name', 'State', 'Auth', 'URL') 'Dark'

    # Source rows
    for ($i = 0; $i -lt $n; $i++) {
        $s    = $Sources[$i]
        $clr  = if ($s.State -eq 'enabled') { 'Green' } else { 'Dark' }
        $num  = 11 + $i
        $url  = $s.Url
        $avail = $sw - 58   # chars left for URL after fixed columns
        if ($avail -lt 10) { $avail = 10 }
        if ($url.Length -gt $avail) { $url = $url.Substring(0, $avail - 1) + '~' }
        $line = '  {0,3}. {1,-24} {2,-8} {3,-16} {4}' -f `
                $num, $s.Name, $s.State, $s.Auth, $url
        Paint-FltRow (3 + $i) $line $clr
    }

    if ($n -eq 0) {
        Paint-FltRow 3 '  (no sources configured)' 'Dark'
    }

    $sepRow    = [Math]::Max(4, 3 + $n)
    $footerRow = $sepRow + 1
    $sepRow2   = $footerRow + 1
    $cmdRow    = $sepRow2 + 1
    $promptRow = $cmdRow + 1

    $Script:FltSourceDashHeight = $promptRow

    Paint-FltRow $sepRow    ('-' * $sw) 'Dark'
    Paint-FltRow $footerRow '  1. Add Beckhoff preset   2. Add custom   11+. Enable/Disable   0. Back' 'Dark'
    Paint-FltRow $sepRow2   ('-' * $sw) 'Dark'

    $cmdText = if ($LastCommand) { "  > $LastCommand" } else { '' }
    Paint-FltRow $cmdRow $cmdText 'Dark'

    if ($ResultLine) {
        $resClr = if ($ResultLine -match 'OK|uccess|dded|abled') { 'Green' }
                  elseif ($ResultLine -match 'FAIL|[Ee]rror') { 'Red' }
                  else { '' }
        # Overwrite cmd row with result, shift prompt down
        Paint-FltRow $cmdRow "  $ResultLine" $resClr
    }

    Paint-FltRow $promptRow '' ''
    Write-Host -NoNewline "`e[${promptRow};1H"
}



function Show-PackageStatusDashboard {
    param(
        [FleetPackageSummary] $Summary,
        [FleetTarget[]]       $AllTargets
    )
    $sw = Get-FltSafeWidth
    $n  = $AllTargets.Count

    # Build a state lookup
    $stateMap = @{}
    foreach ($s in $Summary.States) { $stateMap[$s.TargetName] = $s }

    $nameColW = [Math]::Min(24, [Math]::Max(14,
        ($AllTargets | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum ?? 14))

    Clear-Host

    Paint-FltTitleBar 1 "Package: $($Summary.PackageName)"

    # Row 2: package info
    $feedInfo = if ($Summary.FeedVersion) { "Feed version: $($Summary.FeedVersion)" } else { 'Feed version: (not specified)' }
    Paint-FltRow 2 "  $feedInfo   Source: $($Summary.FeedSource)" 'Dark'

    # Row 3: column headers
    $pkgHdr = '  {0,3}  {1} {2,-16} {3,-16} {4}' -f `
        '#', 'Target'.PadRight($nameColW), 'Installed', 'Feed', 'Status'
    Paint-FltRow 3 $pkgHdr 'Dark'

    # Rows 4..3+n: one row per target
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
        $row  = 4 + $i
        $line = '  {0,3}. {1} {2,-16} {3,-16} {4}' -f `
                (11 + $i), $t.Name.PadRight($nameColW), $inst, $feed, $stat
        Paint-FltRow $row $line $clr
    }

    $sepRow    = 4 + $n
    $footerRow = $sepRow + 1
    Paint-FltRow $sepRow ('-' * $sw) 'Dark'
    Paint-FltRow $footerRow '  1. Install/Upgrade selected   2. Upgrade all outdated   0. Back   |   enter 11+ to select target' 'Dark'

    $Script:FltDashHeight = $footerRow + 2
    Paint-FltRow $Script:FltDashHeight '' ''
    Write-Host -NoNewline "`e[$($Script:FltDashHeight);1H"
}

# ── Batch execution dashboard ─────────────────────────────────────────────────

function Show-FleetBatchDashboard {
    param(
        [FleetTarget[]] $Targets,
        [string]        $Action,
        [string]        $PackageSpec,
        [string]        $Mode,
        [int]           $TimeoutSecs = 0
    )
    $sw = Get-FltSafeWidth
    $n  = $Targets.Count
    $maxResult = 4
    $headerRows = 7   # +1 for command row

    $Script:FltBatchDashHeight   = $headerRows + $n + 1 + 1 + $maxResult + 1
    $Script:FltBatchScrollStart  = $Script:FltBatchDashHeight + 1

    # Pre-initialise status for each target
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

    Paint-FltTitleBar 1 'Batch operation'

    Paint-FltRow 2 "  Action: $($Action.ToUpper())   Package: $PackageSpec" 'Cyan'

    $modeStr = "  Mode: $Mode"
    if ($TimeoutSecs -gt 0) { $modeStr += "   Timeout: ${TimeoutSecs} s" }
    Paint-FltRow 3 $modeStr 'Dark'

    # Row 4: command that will be run on each remote
    $remoteTcpkg = (Get-FltCfgValue 'tcpkg' 'remoteTcpkgPath' 'TcPkg.exe')
    Paint-FltRow 4 "  > `"$remoteTcpkg`" $Action $PackageSpec -y" 'Dark'

    Paint-FltRow 5 ('-' * $sw) 'Dark'
    Paint-FltRow 6 ('  {0,-22} {1,-14} {2,9}  {3}' -f 'Target','Status','Duration','Note') 'Dark'
    Paint-FltRow 7 ('-' * $sw) 'Dark'

    for ($i = 0; $i -lt $n; $i++) {
        Paint-FltRow (8 + $i) ('  {0,-22} {1,-14}' -f $Targets[$i].Name, 'Pending') ''
    }

    Paint-FltRow ($headerRows + $n + 1) ('-' * $sw) 'Dark'
    Paint-FltRow ($headerRows + $n + 2) '  Pending...' 'Dark'

    Paint-FltRow $Script:FltBatchDashHeight '' ''
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
}

# Update a single target's row during batch execution (in-place, cursor-safe).
function Update-FltBatchRow {
    param([string]$TargetName, [string]$Status, [double]$Duration = 0, [string]$Note = '')
    if (-not $Script:FltBatchStatus.ContainsKey($TargetName)) { return }

    $st = $Script:FltBatchStatus[$TargetName]
    $st.Status   = $Status
    $st.Duration = $Duration
    $st.Note     = $Note

    $sw     = Get-FltSafeWidth
    $row    = $st.Row
    $durStr = if ($Duration -gt 0) { '{0,7:F1} s' -f $Duration } else { '         ' }
    $line   = '  {0,-22} {1,-14} {2}  {3}' -f $TargetName, $Status, $durStr, $Note
    if ($line.Length -gt $sw) { $line = $line.Substring(0, $sw) }

    if     ($Status -like 'OK*')       { $clr = "`e[92m" }
    elseif ($Status -like 'Failed*')   { $clr = "`e[91m" }
    elseif ($Status -eq 'Timed out')   { $clr = "`e[93m" }
    elseif ($Status -like 'Running*')  { $clr = "`e[96m" }
    elseif ($Status -eq 'Skipped')     { $clr = "`e[90m" }
    else                                { $clr = ''        }
    $rst = if ($clr) { "`e[0m" } else { '' }

    Write-Host -NoNewline "`e[s`e[${row};1H${clr}${line}${rst}`e[K`e[u"

    # Refresh summary row
    $all      = $Script:FltBatchStatus.Values
    $ok       = @($all | Where-Object { $_.Status -like 'OK*' }).Count
    $run      = @($all | Where-Object { $_.Status -like 'Running*' }).Count
    $fail     = @($all | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Timed out' }).Count
    $skip     = @($all | Where-Object { $_.Status -eq 'Skipped' }).Count
    $pend     = @($all | Where-Object { $_.Status -eq 'Pending' }).Count
    $sumRow   = $Script:FltBatchDashHeight - 1
    $sumStr   = "  $ok OK  |  $run running  |  $fail failed  |  $skip skipped  |  $pend pending"
    Write-Host -NoNewline "`e[s`e[${sumRow};1H`e[90m${sumStr}`e[0m`e[K`e[u"
}

# ── Simple list renderer (replaces Show-SelectableList from the old scripts) ──

function Show-FltTable {
    param(
        [object[]]   $Items,
        [hashtable[]] $Columns,
        [int]         $Base     = 11,
        [switch]      $NoNumber
    )
    if (-not $Items -or $Items.Count -eq 0) { return }
    $w = Get-FltSafeWidth

    # Calculate column widths — guard against null expr results
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

    # Header
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

    # Rows
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