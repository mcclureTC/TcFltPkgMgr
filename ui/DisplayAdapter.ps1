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

function Get-FltSafeWidth {
    & $Script:FltDisplay_GetSafeWidth
}

function Paint-FltRow {
    param([int]$Row, [string]$Text, [string]$Fg = '')
    & $Script:FltDisplay_PaintRow -Row $Row -Text $Text -Fg $Fg
}

function Paint-FltTitleBar {
    param([int]$Row, [string]$Title)
    & $Script:FltDisplay_PaintTitleBar -Row $Row -Title $Title
}

function Show-FleetDashboard {
    param(
        [FleetTarget[]] $Targets,
        [string[]]      $ResultLines = @(),
        [string]        $LastCommand = ''
    )
    & $Script:FltDisplay_ShowFleetDashboard -Targets $Targets -ResultLines $ResultLines -LastCommand $LastCommand
}

function Show-SetupDashboard {
    param(
        [string]   $Mode    = 'targets',
        [object[]] $Items   = @(),
        [string]   $Result  = '',
        [string]   $LastCmd = ''
    )
    & $Script:FltDisplay_ShowSetupDashboard -Mode $Mode -Items $Items -Result $Result -LastCmd $LastCmd
}

function Show-SourcesDashboard {
    param(
        [object[]] $Sources,
        [string]   $LastCommand = '',
        [string]   $ResultLine  = ''
    )
    & $Script:FltDisplay_ShowSourcesDashboard -Sources $Sources -LastCommand $LastCommand -ResultLine $ResultLine
}

function Show-PackageStatusDashboard {
    param(
        [FleetPackageSummary] $Summary,
        [FleetTarget[]]       $AllTargets
    )
    & $Script:FltDisplay_ShowPackageStatusDashboard -Summary $Summary -AllTargets $AllTargets
}

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

function Update-FltBatchRow {
    param([string]$TargetName, [string]$Status, [double]$Duration = 0, [string]$Note = '')
    & $Script:FltDisplay_UpdateBatchRow -TargetName $TargetName -Status $Status -Duration $Duration -Note $Note
}

function Show-FltTable {
    param(
        [object[]]    $Items,
        [hashtable[]] $Columns,
        [int]         $Base     = 11,
        [switch]      $NoNumber
    )
    & $Script:FltDisplay_ShowFltTable -Items $Items -Columns $Columns -Base $Base -NoNumber:$NoNumber
}