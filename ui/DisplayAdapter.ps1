# =============================================================================
#  TcFltPkgMgr — Display Adapter
#  Stable public interface for all display operations.
#  Menus and executors call ONLY these functions — never backend functions
#  directly. The active backend is wired at startup by DisplayBackends.ps1.
#
#  To add a new backend (e.g. Spectre.Console):
#    1. Create ui/DashboardSpectre.ps1 with _Spectre_ prefixed functions
#    2. Add a branch to Set-FltDisplayBackend in DisplayBackends.ps1
#    3. Set "displayBackend": "spectre" in settings.local.json
#    4. No changes needed here or in any menu file.
# =============================================================================

# ── Public adapter functions ──────────────────────────────────────────────────
# Each function delegates to the active backend via a script-scope variable
# set by Set-FltDisplayBackend in DisplayBackends.ps1.

# Returns the safe terminal width (WindowWidth - 1) to prevent auto-wrap.
function Get-FltSafeWidth {
    & $Script:FltDisplay_GetSafeWidth
}

# Paint a single row at absolute cursor position with optional foreground colour.
function Paint-FltRow {
    param([int]$Row, [string]$Text, [string]$Fg = '')
    & $Script:FltDisplay_PaintRow -Row $Row -Text $Text -Fg $Fg
}

# Paint the top title bar showing the screen name and LIVE/READ-ONLY mode indicator.
function Paint-FltTitleBar {
    param([int]$Row, [string]$Title)
    & $Script:FltDisplay_PaintTitleBar -Row $Row -Title $Title
}

# Render the Fleet home screen — target list with status, footer, sort/filter nav row.
function Show-FleetDashboard {
    param(
        [FleetTarget[]] $Targets,
        [string[]]      $ResultLines = @(),
        [string]        $LastCommand = '',
        [int]           $Page        = 0,
        [hashtable]     $SortState   = $null,
        [hashtable]     $FilterState = $null
    )
    & $Script:FltDisplay_ShowFleetDashboard -Targets $Targets -ResultLines $ResultLines `
        -LastCommand $LastCommand -Page $Page -SortState $SortState -FilterState $FilterState
}

# Render the Setup screen in either targets or sources/feeds mode.
function Show-SetupDashboard {
    param(
        [string]    $Mode        = 'targets',
        [object[]]  $Items       = @(),
        [string]    $Result      = '',
        [string]    $LastCmd     = '',
        [hashtable] $SortState   = $null,
        [hashtable] $FilterState = $null
    )
    & $Script:FltDisplay_ShowSetupDashboard -Mode $Mode -Items $Items -Result $Result `
        -LastCmd $LastCmd -SortState $SortState -FilterState $FilterState
}

# Render the dedicated Sources/Feeds screen (used by Invoke-FleetSourceMenu).
function Show-SourcesDashboard {
    param(
        [object[]] $Sources,
        [string]   $LastCommand = '',
        [string]   $ResultLine  = ''
    )
    & $Script:FltDisplay_ShowSourcesDashboard -Sources $Sources -LastCommand $LastCommand -ResultLine $ResultLine
}

# Render the Package Status screen showing per-target installed vs feed version.
function Show-PackageStatusDashboard {
    param(
        [FleetPackageSummary] $Summary,
        [FleetTarget[]]       $AllTargets
    )
    & $Script:FltDisplay_ShowPackageStatusDashboard -Summary $Summary -AllTargets $AllTargets
}

# Render the Batch Operation screen — initial layout before parallel jobs start.
# Subsequent per-row updates are done via Update-FltBatchRow, not a full repaint.
function Show-FleetBatchDashboard {
    param(
        [FleetTarget[]] $Targets,
        [string]        $Action,
        [string]        $PackageSpec,
        [string]        $Mode,
        [int]           $TimeoutSecs = 0
    )
    & $Script:FltDisplay_ShowFleetBatchDashboard -Targets $Targets -Action $Action -PackageSpec $PackageSpec -Mode $Mode -TimeoutSecs $TimeoutSecs
}

# Update a single target row on the batch dashboard in-place (no full repaint).
function Update-FltBatchRow {
    param([string]$TargetName, [string]$Status, [double]$Duration = 0, [string]$Note = '')
    & $Script:FltDisplay_UpdateBatchRow -TargetName $TargetName -Status $Status -Duration $Duration -Note $Note
}

# Render a numbered table of items with configurable columns. Used for package
# search results, version pickers, feed pickers, and other list displays.
function Show-FltTable {
    param(
        [object[]]    $Items,
        [hashtable[]] $Columns,
        [int]         $Base     = 11,
        [switch]      $NoNumber
    )
    & $Script:FltDisplay_ShowFltTable -Items $Items -Columns $Columns -Base $Base -NoNumber:$NoNumber
}