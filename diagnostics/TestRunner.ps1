# =============================================================================
#  TcFltPkgMgr — Test Runner
#  Unified dashboard for diagnostics and integration tests.
#  Replaces the old Setup > 10. Diagnostics single-button launcher.
#
#  Input scheme (numpad-only):
#    1      Run all diagnostic tests
#    9      Run all integration tests against selected targets
#    11-16  Run a specific integration suite
#    101+   Toggle a target on/off for integration SSH tests
#    0      Back
#
#  Results are persisted to config/test-results.json.
# =============================================================================

# Returns the path where test run history is stored.
function Get-FltTestResultsPath {
    return Join-Path $Script:FltConfigDir 'test-results.json'
}

# Load saved test results. Returns hashtable: SuiteKey -> @{ RunAt; Passed; Failed; Warned }
function Get-FltTestResults {
    $path = Get-FltTestResultsPath
    if (-not (Test-Path $path)) { return @{} }
    try {
        $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $ht   = @{}
        foreach ($prop in $json.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        return $ht
    } catch { return @{} }
}

# Persist a single suite result to test-results.json.
function Save-FltTestResult {
    param([string]$SuiteKey, [int]$Passed, [int]$Failed, [int]$Warned, [int]$Skipped = 0)
    $path    = Get-FltTestResultsPath
    $results = Get-FltTestResults
    $results[$SuiteKey] = [pscustomobject]@{
        RunAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        Passed  = $Passed
        Failed  = $Failed
        Warned  = $Warned
        Skipped = $Skipped
    }
    try {
        $results | ConvertTo-Json -Depth 3 |
            Set-Content -Path $path -Encoding UTF8 -Force
    } catch { Write-Warning "Could not save test results: $_" }
}

# ── Dashboard ─────────────────────────────────────────────────────────────────

# Format a result cell from saved history. Returns (text, colour).
function _TR_ResultCell {
    param($Hist)
    if (-not $Hist) { return '—', 'Dark' }
    $skipped = if ($Hist.PSObject.Properties['Skipped']) { $Hist.Skipped } else { 0 }
    $total   = $Hist.Passed + $Hist.Failed + $Hist.Warned + $skipped
    $skipTag = if ($skipped -gt 0) { " ($skipped skip)" } else { '' }
    if ($Hist.Failed -gt 0) {
        return "$($Hist.Passed)/$total FAIL$skipTag", 'Red'
    } elseif ($Hist.Warned -gt 0) {
        return "$($Hist.Passed)/$total WARN$skipTag", 'Yellow'
    } elseif ($skipped -gt 0) {
        return "$($Hist.Passed)/$total ✓$skipTag", 'Green'
    } else {
        return "$($Hist.Passed)/$total ✓", 'Green'
    }
}

# Render the test runner dashboard.
function _Show-TestRunnerDashboard {
    param(
        [string[]] $SelectedTargets = @(),
        [string]   $Result          = '',
        [string]   $ResultColor     = ''
    )
    $sw      = Get-FltSafeWidth
    $history = Get-FltTestResults
    $itSuites = Get-IT_Suites

    Clear-Host
    Paint-FltTitleBar 1 'Tests'

    $hdr = '  {0,-4}  {1,-42}  {2,-5}  {3,-16}  {4}' -f '#', 'Suite', 'Tests', 'Last run', 'Result'
    Paint-FltRow 2 $hdr 'Dark'
    $row = 3

    # ── Diagnostics — single entry ─────────────────────────────────────────────
    Paint-FltRow $row '  ── Diagnostics ──────────────────────────────────────────────────────' 'Dark'
    $row++

    $hist = $history['DIAG']
    $res, $clr = _TR_ResultCell $hist
    $runAt = if ($hist) { $hist.RunAt } else { 'never' }
    Paint-FltRow $row ('  {0,-4}  {1,-42}  {2,-5}  {3,-16}  {4}' -f '1', 'All diagnostic tests', '29', $runAt, $res) $clr
    $row++

    # ── Integration suites ────────────────────────────────────────────────────
    Paint-FltRow $row '  ── Integration ──────────────────────────────────────────────────────' 'Dark'
    $row++
    foreach ($s in $itSuites) {
        $hist  = $history["IT$($s.Id)"]
        $res, $clr = _TR_ResultCell $hist
        $runAt = if ($hist) { $hist.RunAt } else { 'never' }
        $tag   = if ($s.NeedsSSH) { '  [needs target]' } else { '' }
        $name  = "$($s.Name)$tag"
        $dispId = $s.Id
        Paint-FltRow $row ('  {0,-4}  {1,-42}  {2,-5}  {3,-16}  {4}' -f $dispId, $name, '?', $runAt, $res) $clr
        $row++
    }

    # ── Target list ───────────────────────────────────────────────────────────
    $n = $Script:FleetTargets.Count
    if ($n -gt 0) {
        Paint-FltRow $row '  ── Targets for integration tests (101+ to toggle) ───────────────────' 'Dark'
        $row++
        for ($i = 0; $i -lt $n; $i++) {
            $t    = $Script:FleetTargets[$i]
            $tick = if ($SelectedTargets -contains $t.Name) { [char]0x25CF } else { ' ' }
            $clr  = if ($SelectedTargets -contains $t.Name) { 'Green' } else { 'Dark' }
            Paint-FltRow $row ('  {0,-4}  {1} {2,-24}  {3}' -f (101+$i), $tick, $t.Name, $t.Address) $clr
            $row++
        }
    }

    $sepRow    = $row
    $footerRow = $sepRow + 1
    $sep2Row   = $footerRow + 1
    $resRow    = $sep2Row + 1
    $promptRow = $resRow + 1

    Paint-FltRow $sepRow    ('-' * $sw) 'Dark'
    Paint-FltRow $footerRow '  1. All diagnostics   9. All integration   00. Clear results   0. Back' 'Dark'
    Paint-FltRow $sep2Row   '  11-99. Integration suite   101+. Toggle target (101,103 or 101-104 or 101..104)' 'Dark'

    if ($Result) {
        $clr = if ($ResultColor) { $ResultColor }
               elseif ($Result -match 'FAIL') { 'Red' }
               elseif ($Result -match 'WARN') { 'Yellow' }
               elseif ($Result -match '✓|passed') { 'Green' }
               else { '' }
        Paint-FltRow $resRow "  $Result" $clr
    }

    Paint-FltRow $promptRow '' ''
    Write-Host -NoNewline "`e[${promptRow};1H"
}

# ── Run helpers ───────────────────────────────────────────────────────────────

# Run all diagnostics, display results, wait for Enter, return counts.
function _TR_RunDiag {
    Clear-Host
    Invoke-FltDiagnostics
    if ($Script:_diagFail -gt 0 -or $Script:_diagWarn -gt 0) {
        Read-Host '  Press Enter to return'
    } else {
        Start-Sleep -Milliseconds 400
    }
    return [pscustomobject]@{
        Passed = $Script:_diagPass
        Failed = $Script:_diagFail
        Warned = $Script:_diagWarn
    }
}

# Run a single integration suite against all selected targets, display results, wait for Enter.
function _TR_RunIntSuite {
    param(
        [pscustomobject] $Suite,
        [FleetTarget[]]  $Targets    = @(),
        [System.Management.Automation.PSCredential] $Credential = $null
    )
    Clear-Host
    Write-Host ''
    Write-Host "  Integration Test: $($Suite.Name)" -ForegroundColor White
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    if ($Targets.Count -gt 0) {
        Write-Host "  Targets: $($Targets.Name -join ', ')" -ForegroundColor DarkGray
    }
    Write-Host ''

    $r = _IT_NewResult

    # Suites that run once regardless of target count
    if (-not $Suite.PerTarget -or $Targets.Count -eq 0) {
        # Run once regardless of target count
        $r = switch ($Suite.Function) {
            'Invoke-IT_FileIO'          { Invoke-IT_FileIO }
            'Invoke-IT_Pagination'      { Invoke-IT_Pagination }
            'Invoke-IT_ReadOnly'        { Invoke-IT_ReadOnly }
            'Invoke-IT_Log'             { Invoke-IT_Log }
            'Invoke-IT_WinGet'          { Invoke-IT_WinGet }
            'Invoke-IT_Ansible'         { Invoke-IT_Ansible }
            'Invoke-IT_DockerOperator'  { Invoke-IT_DockerOperator }
            'Invoke-IT_AnsibleInventory' { Invoke-IT_AnsibleInventory }
            'Invoke-IT_AnsiblePlaybook'  { Invoke-IT_AnsiblePlaybook }
            'Invoke-IT_AnsibleBatch'     { Invoke-IT_AnsibleBatch }
            'Invoke-IT_FleetRouting'     { Invoke-IT_FleetRouting }
            'Invoke-IT_AnsibleVault'     { Invoke-IT_AnsibleVault }
            'Invoke-IT_ContainerExecutor' { Invoke-IT_ContainerExecutor }
            'Invoke-IT_ContainerTargetFlow' { Invoke-IT_ContainerTargetFlow }
            'Invoke-IT_BatchPagination'     { Invoke-IT_BatchPagination }
            'Invoke-IT_Phase80PreWork'      { Invoke-IT_Phase80PreWork }
            'Invoke-IT_ContainerAdminMenu'  { Invoke-IT_ContainerAdminMenu }
            'Invoke-IT_ComposeRepository'   { Invoke-IT_ComposeRepository }
            'Invoke-IT_ContainerTargetReg'  { Invoke-IT_ContainerTargetReg }
            'Invoke-IT_SSH'             { Invoke-IT_SSH -Target ($Targets | Select-Object -First 1) -Credential $Credential }
            'Invoke-IT_ReachCache'      { Invoke-IT_ReachCache -Target ($Targets | Select-Object -First 1) }
            'Invoke-IT_TcpkgLocal'      { Invoke-IT_TcpkgLocal -Target ($Targets | Select-Object -First 1) }
            'Invoke-IT_PackageQueries'  { Invoke-IT_PackageQueries -Target ($Targets | Select-Object -First 1) }
            default {
                Write-Host "  Unknown suite: $($Suite.Function)" -ForegroundColor Red
                _IT_NewResult
            }
        }
    } else {
        # Run per-target suites against every selected target
        foreach ($target in $Targets) {
            Write-Host "  ── $($target.Name) ($($target.Address)) " -ForegroundColor Cyan
            $tr = switch ($Suite.Function) {
                'Invoke-IT_SSH'             { Invoke-IT_SSH -Target $target -Credential $Credential }
                'Invoke-IT_ReachCache'      { Invoke-IT_ReachCache -Target $target }
                'Invoke-IT_TcpkgLocal'      { Invoke-IT_TcpkgLocal -Target $target }
                'Invoke-IT_PackageQueries'  { Invoke-IT_PackageQueries -Target $target }
                'Invoke-IT_WinGet'           { Invoke-IT_WinGet }
                'Invoke-IT_WinGetLive'       { Invoke-IT_WinGetLive -Target $target -Credential $Credential }
                'Invoke-IT_Ansible'          { Invoke-IT_Ansible }
                'Invoke-IT_DockerOperator'   { Invoke-IT_DockerOperator }
                'Invoke-IT_AnsibleInventory'  { Invoke-IT_AnsibleInventory }
                'Invoke-IT_AnsiblePlaybook'   { Invoke-IT_AnsiblePlaybook }
                'Invoke-IT_AnsibleBatch'      { Invoke-IT_AnsibleBatch }
                'Invoke-IT_FleetRouting'      { Invoke-IT_FleetRouting }
                'Invoke-IT_AnsibleVault'      { Invoke-IT_AnsibleVault }
                'Invoke-IT_ContainerExecutor' { Invoke-IT_ContainerExecutor }
                'Invoke-IT_ContainerTargetFlow' { Invoke-IT_ContainerTargetFlow }
                'Invoke-IT_BatchPagination'     { Invoke-IT_BatchPagination }
                'Invoke-IT_Phase80PreWork'      { Invoke-IT_Phase80PreWork }
                'Invoke-IT_ContainerAdminMenu'  { Invoke-IT_ContainerAdminMenu }
                'Invoke-IT_ComposeRepository'   { Invoke-IT_ComposeRepository }
                'Invoke-IT_ContainerTargetReg'  { Invoke-IT_ContainerTargetReg }
                default {
                    Write-Host "  Unknown suite: $($Suite.Function)" -ForegroundColor Red
                    _IT_NewResult
                }
            }
            # Accumulate results
            $r.Passed += $tr.Passed
            $r.Failed += $tr.Failed
            $r.Warned += $tr.Warned
            foreach ($res in $tr.Results) { $r.Results.Add($res) }
        }
    }

    $skipped   = if ($r.PSObject.Properties['Skipped']) { $r.Skipped } else { 0 }
    $shown     = $r.Passed + $r.Failed + $r.Warned + $skipped
    $defined   = if ($Suite.PSObject.Properties['CheckCount']) { $Suite.CheckCount } else { $shown }
    $notShown  = [Math]::Max(0, $defined - $shown)
    $skipStr   = if ($skipped  -gt 0) { "   $skipped skipped" } else { '' }
    Write-Host ''
    Write-Host "  $('-' * 64)" -ForegroundColor DarkGray
    if     ($r.Failed -eq 0 -and $r.Warned -eq 0 -and $skipped -eq 0) {
        Write-Host "  All $($r.Passed) checks passed." -ForegroundColor Green
    } elseif ($r.Failed -eq 0) {
        Write-Host "  $($r.Passed) passed   $($r.Warned) warnings$skipStr   $shown shown" -ForegroundColor Yellow
    } else {
        Write-Host "  $($r.Passed) passed   $($r.Failed) failed   $($r.Warned) warnings$skipStr   $shown shown" -ForegroundColor Red
    }
    if ($notShown -gt 0) {
        Write-Host "  ($notShown of $defined defined checks not shown — only fire on failure or unmet prerequisites)" -ForegroundColor DarkGray
    }
    Write-Host ''
    # Auto-continue when all checks passed; pause on any failure or warning
    if ($r.Failed -gt 0 -or $r.Warned -gt 0) {
        Read-Host '  Press Enter to return'
    } else {
        Start-Sleep -Milliseconds 400   # brief pause so the result is visible
    }
    return $r
}

# Prompt for SSH credentials when a suite needs SSH.
function _TR_GetCredential {
    param([FleetTarget]$Target)
    Write-Host ''
    Write-Host '  SSH credentials for integration tests:' -ForegroundColor Cyan
    Write-Host '   1. Use stored credential'
    Write-Host '   2. Enter password'
    Write-Host '   0. Skip (SSH tests will report as warnings)'
    Write-Host ''
    $choice = (Read-Host '  Choice').Trim()

    if ($choice -eq '1' -and $Target) {
        $pwd = Resolve-FltPassword -CredentialName $Target.Name -PromptLabel '' -Silent
        if ($pwd) {
            $sec = ConvertTo-SecureString $pwd -AsPlainText -Force
            return [System.Management.Automation.PSCredential]::new($Target.User, $sec)
        }
        Write-Host '  No stored credential found — enter password instead.' -ForegroundColor Yellow
        $choice = '2'
    }
    if ($choice -eq '2') {
        $user = if ($Target) { $Target.User } else { (Read-Host '  Username').Trim() }
        $pwd  = (Read-Host "  Password for $user").Trim()
        $sec  = ConvertTo-SecureString $pwd -AsPlainText -Force
        return [System.Management.Automation.PSCredential]::new($user, $sec)
    }
    return $null
}

# ── Main entry point ──────────────────────────────────────────────────────────

# The test runner menu — called from Setup > 10.
function Invoke-FltTestRunner {
    $itSuites        = Get-IT_Suites
    $selectedTargets = [System.Collections.Generic.List[string]]::new()
    $result          = ''
    $resultClr       = ''

    while ($true) {
        _Show-TestRunnerDashboard -SelectedTargets $selectedTargets `
            -Result $result -ResultColor $resultClr
        $result = ''; $resultClr = ''

        $choice = (Read-Host '  Choice').Trim()

        # Accept pure digits OR range expressions starting with 101+ (e.g. "101,103" "101-104" "101..104")
        $isRange = $choice -match '^1[01][0-9]' -and $choice -match '[,\.\-]'
        if (-not $isRange -and -not ($choice -match '^\d+$')) {
            $result = 'Numbers only — see footer for valid choices'
            $resultClr = 'Yellow'
            continue
        }
        $num = if ($choice -match '^\d+$') { [int]$choice } else { [int]($choice -split '[,\.\-\s]')[0] }

        # 00 — clear all test results (check before 0-back so '00' → 0 doesn't exit)
        if ($choice -eq '00') {
            Write-Host '  Clear all test results? The Result column will show — for all suites.' -ForegroundColor Yellow
            $confirm = (Read-Host '  1. Yes   0. No').Trim()
            if ($confirm -eq '1') {
                try {
                    Remove-Item (Get-FltTestResultsPath) -Force -ErrorAction Stop
                    $result = 'All test results cleared'; $resultClr = 'Green'
                } catch {
                    $result = "Could not clear results: $($_.Exception.Message)"; $resultClr = 'Red'
                }
            }
            continue
        }

        # 0 — back
        if ($num -eq 0) { return }

        # 1 — run all diagnostics
        if ($num -eq 1) {
            $r = _TR_RunDiag
            Save-FltTestResult -SuiteKey 'DIAG' `
                -Passed $r.Passed -Failed $r.Failed -Warned $r.Warned
            $total = $r.Passed + $r.Failed + $r.Warned
            $result = "Diagnostics: $($r.Passed)/$total passed"
            $resultClr = if ($r.Failed -gt 0) { 'Red' } elseif ($r.Warned -gt 0) { 'Yellow' } else { 'Green' }
            continue
        }

        # 9 — run all integration suites
        if ($num -eq 9) {
            $selObjs = @($Script:FleetTargets | Where-Object { $selectedTargets -contains $_.Name })
            $cred    = $null
            if ($itSuites | Where-Object { $_.NeedsSSH }) {
                if ($selObjs.Count -eq 0) {
                    $result = 'SSH suite needs a target — toggle one with 101+'
                    $resultClr = 'Yellow'
                    continue
                }
                $cred = _TR_GetCredential -Target ($selObjs | Select-Object -First 1)
            }
            $tp = 0; $tf = 0; $tw = 0
            foreach ($suite in $itSuites) {
                $r = _TR_RunIntSuite -Suite $suite -Targets $selObjs -Credential $cred
                $sk1 = if ($r.PSObject.Properties['Skipped']) { $r.Skipped } else { 0 }
          Save-FltTestResult -SuiteKey "IT$($suite.Id)" `
                    -Passed $r.Passed -Failed $r.Failed -Warned $r.Warned -Skipped $sk1
                $tp += $r.Passed; $tf += $r.Failed; $tw += $r.Warned
            }
            $total = $tp + $tf + $tw
            $result = "Integration: $tp/$total passed"
            $resultClr = if ($tf -gt 0) { 'Red' } elseif ($tw -gt 0) { 'Yellow' } else { 'Green' }
            continue
        }

        # 11-27 — run specific integration suite (Id matches UI display number)
        if ($num -ge 11 -and $num -le 99) {
            $suite = $itSuites | Where-Object { $_.Id -eq $num }
            if (-not $suite) { $result = "No suite $num"; continue }

            $selObjs = @($Script:FleetTargets | Where-Object { $selectedTargets -contains $_.Name })
            $cred    = $null
            if ($suite.NeedsSSH) {
                if ($selObjs.Count -eq 0) {
                    $result = "Suite '$($suite.Name)' needs a target — toggle one with 21+"
                    $resultClr = 'Yellow'
                    continue
                }
                $cred = _TR_GetCredential -Target ($selObjs | Select-Object -First 1)
            }
            $r = _TR_RunIntSuite -Suite $suite -Targets $selObjs -Credential $cred
            $sk2 = if ($r.PSObject.Properties['Skipped']) { $r.Skipped } else { 0 }
            Save-FltTestResult -SuiteKey "IT$num" `
                -Passed $r.Passed -Failed $r.Failed -Warned $r.Warned -Skipped $sk2
            $total = $r.Passed + $r.Failed + $r.Warned
            $result = "$($r.Passed)/$total passed"
            $resultClr = if ($r.Failed -gt 0) { 'Red' } elseif ($r.Warned -gt 0) { 'Yellow' } else { 'Green' }
            continue
        }

        # 101+ — toggle target selection (single, comma list, or range: 101,103 or 101-104 or 101..104)
        if ($num -ge 101) {
            # Re-read the raw input to support ranges — $choice already has the first number
            # but the user may have typed "21,23,24" or "21-24"
            $indices = @(Expand-FltSelectionRange -RawInput $choice -Max (100 + $Script:FleetTargets.Count))
            $toggled = @()
            foreach ($idx_num in $indices) {
                $idx = $idx_num - 101
                if ($idx -ge 0 -and $idx -lt $Script:FleetTargets.Count) {
                    $tName = $Script:FleetTargets[$idx].Name
                    if ($selectedTargets -contains $tName) {
                        $selectedTargets.Remove($tName) | Out-Null
                        $toggled += "-$tName"
                    } else {
                        $selectedTargets.Add($tName)
                        $toggled += "+$tName"
                    }
                }
            }
            if ($toggled.Count -gt 0) {
                $result    = "Toggled: $($toggled -join ', ')"
                $resultClr = 'Green'
            } else {
                $result    = "No targets matched '$choice'"
                $resultClr = 'Yellow'
            }
            continue
        }

        $result = 'Invalid: 1 (diagnostics), 9 (all integration), 11-99 (suite), 101+ or 101-104 (toggle targets), 0 (back)'
        $resultClr = 'Yellow'
    }
}