# =============================================================================
#  TcFltPkgMgr — UI Config Menu
#  Runtime display preferences. Changes take effect immediately and are
#  persisted to settings.local.json so they survive restarts.
#
#  Accessed via Fleet home > 7. UI Config
#
#  Future settings to add here as needed:
#   - Dashboard refresh rate
#   - Color scheme
#   - Date/time format
#   - Column visibility
# =============================================================================

function _Show-UiConfigDashboard {
    param([string]$Result = '')

    $sw       = Get-FltSafeWidth
    $pageSize = Get-FltCfgValue 'ui' 'dashboardPageSize' 20
    $backend  = Get-FltCfgValue 'ui' 'displayBackend' 'ansi'

    Clear-Host
    Paint-FltTitleBar 1 'UI Config'

    Paint-FltRow 2  '  #   Setting                  Current value' 'Dark'
    Paint-FltRow 3  "   1. Page size                $pageSize"
    Paint-FltRow 4  "   2. Display backend          $backend"
    Paint-FltRow 5  '' ''

    $sepRow    = 6
    $footerRow = 7
    $sepRow2   = 8
    $resultRow = 9
    $promptRow = 10

    Paint-FltRow $sepRow    ('-' * $sw) 'Dark'
    Paint-FltRow $footerRow '  Enter item number to change   0. Back' 'Dark'
    Paint-FltRow $sepRow2   ('-' * $sw) 'Dark'

    if ($Result) {
        $clr = if ($Result -match 'Saved|OK') { 'Green' }
               elseif ($Result -match 'Error|Invalid') { 'Red' }
               else { '' }
        Paint-FltRow $resultRow "  $Result" $clr
    }

    Paint-FltRow $promptRow '' ''
    Write-Host -NoNewline "`e[${promptRow};1H"
}

# Persist a UI setting to settings.local.json and update $Script:FltCfg in memory.
function _Save-UiCfgValue {
    param([string]$Key, $Value)

    # Update in-memory config immediately
    if (-not $Script:FltCfg.ContainsKey('ui')) { $Script:FltCfg['ui'] = @{} }
    $Script:FltCfg['ui'][$Key] = $Value

    # Write to settings.local.json
    $localPath = Join-Path $Script:FltConfigDir 'settings.local.json'
    try {
        $local = if (Test-Path $localPath) {
            Get-Content $localPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        } else { @{} }

        if (-not $local.ContainsKey('ui')) { $local['ui'] = @{} }
        $local['ui'][$Key] = $Value

        $local | ConvertTo-Json -Depth 5 |
            Set-Content -Path $localPath -Encoding UTF8 -Force
        return $true
    } catch {
        Write-Warning "Could not save UI setting: $_"
        return $false
    }
}

# UI settings screen (Fleet > 7. UI Config). Allows runtime changes to
# display preferences that persist to settings.local.json immediately.
# Currently manages: page size, display backend.
# Future: color scheme, date/time format, column visibility.
function Invoke-UiConfigMenu {
    $result = ''

    while ($true) {
        _Show-UiConfigDashboard -Result $result
        $result  = ''
        $choice  = (Read-Host '  Choice').Trim()

        if ($choice -eq '0' -or [string]::IsNullOrEmpty($choice)) { return }

        # 1 — Page size
        if ($choice -eq '1') {
            $current = Get-FltCfgValue 'ui' 'dashboardPageSize' 20
            Write-Host "  Current page size: $current" -ForegroundColor DarkGray
            Write-Host '  How many targets to show per page (1-100, blank to cancel):' -ForegroundColor Cyan
            $input = (Read-Host '  Page size').Trim()
            if ([string]::IsNullOrEmpty($input)) { continue }
            if ($input -match '^\d+$' -and [int]$input -ge 1 -and [int]$input -le 100) {
                $newVal = [int]$input
                if (_Save-UiCfgValue -Key 'dashboardPageSize' -Value $newVal) {
                    $result = "Page size set to $newVal — takes effect immediately"
                } else {
                    $result = 'Error: could not save to settings.local.json'
                }
            } else {
                $result = "Invalid: enter a number between 1 and 100"
            }
            continue
        }

        # 2 — Display backend
        if ($choice -eq '2') {
            $current = Get-FltCfgValue 'ui' 'displayBackend' 'ansi'
            Write-Host "  Current backend: $current" -ForegroundColor DarkGray
            Write-Host '  Available backends:' -ForegroundColor Cyan
            Write-Host '     1. ansi    (current — ANSI terminal, all platforms)'
            Write-Host '     2. spectre (not yet implemented)'
            Write-Host '     0. Cancel'
            $bChoice = (Read-Host '  Choice').Trim()
            $newBackend = switch ($bChoice) {
                '1' { 'ansi' }
                '2' { 'spectre' }
                default { $null }
            }
            if ($null -eq $newBackend -or $bChoice -eq '0') { continue }
            if ($newBackend -eq 'spectre') {
                $result = 'Spectre.Console backend not yet implemented (see Plan.md Phase 13)'
                continue
            }
            if (_Save-UiCfgValue -Key 'displayBackend' -Value $newBackend) {
                Set-FltDisplayBackend -Backend $newBackend -UiRoot (Join-Path $PSScriptRoot '..')
                $result = "Display backend set to '$newBackend' — takes effect immediately"
            } else {
                $result = 'Error: could not save to settings.local.json'
            }
            continue
        }

        $result = "Invalid choice: $choice"
    }
}