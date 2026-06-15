# =============================================================================
#  TcFltPkgMgr — Display Backend Loader
#  Called once at startup by TcFltPkgMgr.ps1 after DisplayAdapter.ps1 is
#  loaded. Dot-sources the chosen backend and wires its functions to the
#  $Script:FltDisplay_* variables that DisplayAdapter.ps1 delegates to.
#
#  Usage:
#    Set-FltDisplayBackend -Backend (Get-FltCfgValue 'ui' 'displayBackend' 'ansi')
#
#  Supported backends:
#    'ansi'    — ANSI cursor-positioning (ui/DashboardAnsi.ps1)
#    'spectre' — Spectre.Console C# library (ui/DashboardSpectre.ps1) [future]
# =============================================================================

function Set-FltDisplayBackend {
    param(
        [string] $Backend = 'ansi',
        [string] $UiRoot  = $PSScriptRoot   # path to the ui/ folder
    )

    $Script:FltDisplayBackend = $Backend

    if ($Backend -eq 'ansi') {
        # DashboardAnsi.ps1 is already dot-sourced at script scope by
        # TcFltPkgMgr.ps1 before this function is called. We only need
        # to wire the adapter variables here.
        $Script:FltDisplay_GetSafeWidth                = ${function:_Ansi_GetSafeWidth}
        $Script:FltDisplay_PaintRow                    = ${function:_Ansi_PaintRow}
        $Script:FltDisplay_PaintTitleBar               = ${function:_Ansi_PaintTitleBar}
        $Script:FltDisplay_ShowFleetDashboard          = ${function:_Ansi_ShowFleetDashboard}
        $Script:FltDisplay_ShowSetupDashboard          = ${function:_Ansi_ShowSetupDashboard}
        $Script:FltDisplay_ShowSourcesDashboard        = ${function:_Ansi_ShowSourcesDashboard}
        $Script:FltDisplay_ShowPackageStatusDashboard  = ${function:_Ansi_ShowPackageStatusDashboard}
        $Script:FltDisplay_ShowFleetBatchDashboard     = ${function:_Ansi_ShowFleetBatchDashboard}
        $Script:FltDisplay_UpdateBatchRow              = ${function:_Ansi_UpdateBatchRow}
        $Script:FltDisplay_ShowFltTable                = ${function:_Ansi_ShowFltTable}

    } elseif ($Backend -eq 'spectre') {
        # ── Future: Spectre.Console backend ───────────────────────────────────
        # To implement this backend:
        #   1. Create ui/DashboardSpectre.ps1 with all functions prefixed _Spectre_
        #   2. Load Spectre.Console.dll via Add-Type (ship in lib/ folder or
        #      require: dotnet tool install --global Spectre.Console.Cli)
        #   3. Uncomment and complete the wiring below
        #   4. Set "displayBackend": "spectre" in config/settings.local.json
        #   5. No changes needed in DisplayAdapter.ps1 or any menu file
        #
        # $spectrePath = Join-Path $UiRoot 'DashboardSpectre.ps1'
        # if (-not (Test-Path $spectrePath)) {
        #     throw "Spectre.Console dashboard backend not found at: $spectrePath"
        # }
        # . $spectrePath
        # $Script:FltDisplay_GetSafeWidth                = ${function:_Spectre_GetSafeWidth}
        # $Script:FltDisplay_PaintRow                    = ${function:_Spectre_PaintRow}
        # $Script:FltDisplay_PaintTitleBar               = ${function:_Spectre_PaintTitleBar}
        # $Script:FltDisplay_ShowFleetDashboard          = ${function:_Spectre_ShowFleetDashboard}
        # $Script:FltDisplay_ShowSetupDashboard          = ${function:_Spectre_ShowSetupDashboard}
        # $Script:FltDisplay_ShowSourcesDashboard        = ${function:_Spectre_ShowSourcesDashboard}
        # $Script:FltDisplay_ShowPackageStatusDashboard  = ${function:_Spectre_ShowPackageStatusDashboard}
        # $Script:FltDisplay_ShowFleetBatchDashboard     = ${function:_Spectre_ShowFleetBatchDashboard}
        # $Script:FltDisplay_UpdateBatchRow              = ${function:_Spectre_UpdateBatchRow}
        # $Script:FltDisplay_ShowFltTable                = ${function:_Spectre_ShowFltTable}
        throw "Spectre.Console backend is not yet implemented. Set displayBackend to 'ansi' in settings.local.json."

    } else {
        throw "Unknown display backend '$Backend'. Valid values: 'ansi', 'spectre'."
    }

    Write-Verbose "TcFltPkgMgr: display backend set to '$Backend'"
}