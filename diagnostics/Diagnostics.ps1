# =============================================================================
#  TcFltPkgMgr — Built-in Diagnostics
#  Run via Setup > 10. Diagnostics
#  Tests adapter wiring, subsystem function, and config integrity.
#  No network, SSH, or tcpkg calls — fully offline.
#
#  Add new tests here as new subsystems are implemented.
#  Follow the _Diag_Pass / _Diag_Fail pattern.
# =============================================================================

function Invoke-FltDiagnostics {
    $pass = 0
    $fail = 0

    function _Diag_Pass([string]$Label) {
        Write-Host ("  {0,-58} " -f $Label) -NoNewline
        Write-Host 'PASS' -ForegroundColor Green
        $Script:_diagPass++
    }
    function _Diag_Fail([string]$Label, [string]$Detail = '') {
        Write-Host ("  {0,-58} " -f $Label) -NoNewline
        Write-Host 'FAIL' -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor Yellow }
        $Script:_diagFail++
    }
    function _Diag_Section([string]$Title) {
        Write-Host ''
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host "  $('-' * 60)" -ForegroundColor DarkGray
    }

    $Script:_diagPass = 0
    $Script:_diagFail = 0

    Write-Host ''
    Write-Host '  TcFltPkgMgr — Internal Diagnostics' -ForegroundColor White
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   PS $($PSVersionTable.PSVersion)   OS: $($Script:FltOS ?? 'unknown')" -ForegroundColor DarkGray

    # ── Display adapter ────────────────────────────────────────────────────────
    _Diag_Section 'Display adapter (0-A.1)'

    if ($Script:FltDisplayBackend) {
        _Diag_Pass "Display backend selected: '$Script:FltDisplayBackend'"
    } else {
        _Diag_Fail 'Display backend selected' 'FltDisplayBackend is null/empty'
    }

    $displayVars = @(
        'FltDisplay_GetSafeWidth', 'FltDisplay_PaintRow', 'FltDisplay_PaintTitleBar',
        'FltDisplay_ShowFleetDashboard', 'FltDisplay_ShowSetupDashboard',
        'FltDisplay_ShowSourcesDashboard', 'FltDisplay_ShowPackageStatusDashboard',
        'FltDisplay_ShowFleetBatchDashboard', 'FltDisplay_UpdateBatchRow',
        'FltDisplay_ShowFltTable'
    )
    $missingDisplay = @($displayVars | Where-Object {
        $v = Get-Variable -Name $_ -Scope Script -ErrorAction SilentlyContinue
        -not $v -or -not $v.Value
    })
    if ($missingDisplay.Count -eq 0) {
        _Diag_Pass 'All 10 display adapter variables wired'
    } else {
        _Diag_Fail "Display adapter variables wired ($($displayVars.Count - $missingDisplay.Count)/$($displayVars.Count))" `
            "Missing: $($missingDisplay -join ', ')"
    }

    # Test Get-FltSafeWidth delegates correctly
    try {
        $w = Get-FltSafeWidth
        if ($w -is [int] -and $w -gt 0) {
            _Diag_Pass "Get-FltSafeWidth returns valid width ($w)"
        } else {
            _Diag_Fail 'Get-FltSafeWidth returns valid width' "Returned: $w"
        }
    } catch {
        _Diag_Fail 'Get-FltSafeWidth delegates without error' $_.Exception.Message
    }

    # Verify DashboardAnsi.ps1 functions exist at script scope
    $ansiFns = @(
        '_Ansi_GetSafeWidth', '_Ansi_PaintRow', '_Ansi_PaintTitleBar',
        '_Ansi_ShowFleetDashboard', '_Ansi_ShowSetupDashboard',
        '_Ansi_ShowSourcesDashboard', '_Ansi_ShowPackageStatusDashboard',
        '_Ansi_ShowFleetBatchDashboard', '_Ansi_UpdateBatchRow', '_Ansi_ShowFltTable'
    )
    $missingAnsi = @($ansiFns | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missingAnsi.Count -eq 0) {
        _Diag_Pass 'All 10 _Ansi_ backend functions defined at script scope'
    } else {
        _Diag_Fail "_Ansi_ functions at script scope ($($ansiFns.Count - $missingAnsi.Count)/$($ansiFns.Count))" `
            "Missing: $($missingAnsi -join ', ')"
    }

    # ── Credential adapter ─────────────────────────────────────────────────────
    _Diag_Section 'Credential adapter (0-A.2)'

    if ($Script:FltCredentialBackend) {
        _Diag_Pass "Credential backend selected: '$Script:FltCredentialBackend'"
    } else {
        _Diag_Fail 'Credential backend selected' 'FltCredentialBackend is null/empty'
    }

    $credVars = @('FltCred_Get', 'FltCred_Set', 'FltCred_Remove')
    $missingCred = @($credVars | Where-Object {
        $v = Get-Variable -Name $_ -Scope Script -ErrorAction SilentlyContinue
        -not $v -or -not $v.Value
    })
    if ($missingCred.Count -eq 0) {
        _Diag_Pass 'All 3 credential adapter variables wired'
    } else {
        _Diag_Fail "Credential adapter variables wired ($($credVars.Count - $missingCred.Count)/$($credVars.Count))" `
            "Missing: $($missingCred -join ', ')"
    }

    # Round-trip test: write, read, delete a test credential
    # Use a simple alphanumeric key — dots in the name can cause cmdkey lookup issues
    $testKey = 'DiagTest' + (Get-Random -Minimum 100000 -Maximum 999999)
    $testVal = 'DiagTestValue_' + (Get-Random)
    try {
        $setOk = Set-FltStoredPassword -CredentialName $testKey -PlainPassword $testVal
        if (-not $setOk) { throw 'Set returned false' }
        $readVal = Get-FltStoredPassword -CredentialName $testKey
        if ($readVal -ne $testVal) { throw "Read returned '$readVal', expected '$testVal'" }
        $delOk = Remove-FltStoredPassword -CredentialName $testKey
        if (-not $delOk) { throw 'Remove returned false' }
        $afterDel = Get-FltStoredPassword -CredentialName $testKey
        # Treat $null or '' as "not found" — backends may differ
        if (-not [string]::IsNullOrEmpty($afterDel)) {
            throw "After delete, Get returned '$afterDel' instead of null/empty"
        }
        _Diag_Pass 'Credential round-trip: Set → Get → Remove → Get=null/empty'
    } catch {
        Remove-FltStoredPassword -CredentialName $testKey -ErrorAction SilentlyContinue | Out-Null
        _Diag_Fail 'Credential round-trip: Set → Get → Remove → Get=null/empty' $_.Exception.Message
    }

    # Confirm Resolve-FltPassword is callable
    if (Get-Command 'Resolve-FltPassword' -ErrorAction SilentlyContinue) {
        _Diag_Pass 'Resolve-FltPassword is defined'
    } else {
        _Diag_Fail 'Resolve-FltPassword is defined' 'Function not found'
    }

    # ── Module load integrity ──────────────────────────────────────────────────
    _Diag_Section 'Module load integrity'

    $requiredFunctions = @(
        'Get-FleetTargets', 'Add-FleetTarget', 'Edit-FleetTarget', 'Remove-FleetTarget',
        'Import-FleetTargetsCsv', 'Export-FleetTargetsCsv',
        'Invoke-FltTcpkg', 'Invoke-FltSshBatch', 'Invoke-FleetAction',
        'Get-FltSources', 'Repair-FltSourcePriorities',
        'Show-FleetDashboard', 'Show-SetupDashboard', 'Show-SourcesDashboard',
        'Show-FleetBatchDashboard', 'Update-FltBatchRow', 'Show-FltTable',
        'Get-FltStoredPassword', 'Set-FltStoredPassword', 'Remove-FltStoredPassword',
        'Resolve-FltPassword', 'Write-FltBatchEntry', 'Invoke-FltWithStdin'
    )
    $missingFns = @($requiredFunctions | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missingFns.Count -eq 0) {
        _Diag_Pass "All $($requiredFunctions.Count) required functions defined"
    } else {
        _Diag_Fail "Required functions defined ($($requiredFunctions.Count - $missingFns.Count)/$($requiredFunctions.Count))" `
            "Missing: $($missingFns -join ', ')"
    }

    # FleetTarget class is loaded
    try {
        $t = [FleetTarget]::new('Test','127.0.0.1',22,'admin',$false)
        if ($t.Name -eq 'Test' -and $t.Address -eq '127.0.0.1') {
            _Diag_Pass 'FleetTarget class instantiates correctly'
        } else {
            _Diag_Fail 'FleetTarget class instantiates correctly' "Name=$($t.Name) Address=$($t.Address)"
        }
    } catch {
        _Diag_Fail 'FleetTarget class instantiates correctly' $_.Exception.Message
    }

    # Script-scope variables
    $requiredVars = @(
        'FltDisplayBackend', 'FltCredentialBackend', 'FltReadOnly',
        'FltConfigDir', 'FltSessionId', 'FleetTargets', 'FltFeeds'
    )
    $missingVars = @($requiredVars | Where-Object {
        $null -eq (Get-Variable -Name $_ -Scope Script -ErrorAction SilentlyContinue)
    })
    if ($missingVars.Count -eq 0) {
        _Diag_Pass "All $($requiredVars.Count) required script variables set"
    } else {
        _Diag_Fail "Required script variables set ($($requiredVars.Count - $missingVars.Count)/$($requiredVars.Count))" `
            "Missing: `$Script:$($missingVars -join ', $Script:')"
    }

    # OS detection — informational only (Phase 0-A.3 will set this)
    $osVal = (Get-Variable -Name 'FltOS' -Scope Script -ErrorAction SilentlyContinue)?.Value
    if ($osVal) {
        _Diag_Pass "OS detected: '$osVal'"
    } else {
        _Diag_Pass 'OS detection not yet implemented (Phase 0-A.3 — expected)'
    }

    # ── Config ─────────────────────────────────────────────────────────────────
    _Diag_Section 'Configuration'

    # settings.default.json is loadable and has expected sections
    $expectedSections = @('ssh','ui','log','tcpkg','security')
    $missingSections  = @($expectedSections | Where-Object { -not (Get-FltCfgValue $_ '' $null) -and
        $null -eq $Script:FltCfg[$_] })
    if ($missingSections.Count -eq 0) {
        _Diag_Pass "Config has all required sections: $($expectedSections -join ', ')"
    } else {
        _Diag_Fail "Config sections present" "Missing: $($missingSections -join ', ')"
    }

    # Config dir exists
    if (Test-Path $Script:FltConfigDir) {
        _Diag_Pass "Config directory exists: $Script:FltConfigDir"
    } else {
        _Diag_Fail 'Config directory exists' $Script:FltConfigDir
    }

    # ── Subsystem functional tests ─────────────────────────────────────────────
    _Diag_Section 'Subsystem functional tests'

    # ConvertFrom-FltTcpkgJson — parses tcpkg JSON without calling tcpkg
    try {
        $testJson = '[{"Name":"TestFeed","Source":"https://example.com","Priority":1,"Enabled":true}]'
        $parsed   = ConvertFrom-FltTcpkgJson @($testJson)
        if ($parsed -and $parsed[0].Name -eq 'TestFeed' -and $parsed[0].Priority -eq 1) {
            _Diag_Pass 'ConvertFrom-FltTcpkgJson parses valid JSON correctly'
        } else {
            _Diag_Fail 'ConvertFrom-FltTcpkgJson parses valid JSON correctly' "Got: $parsed"
        }
    } catch {
        _Diag_Fail 'ConvertFrom-FltTcpkgJson parses valid JSON correctly' $_.Exception.Message
    }

    # ConvertFrom-FltTcpkgJson — handles tcpkg version banner on stderr gracefully
    try {
        $withBanner = @(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('TcPkg 2.4.70'), 'test', 'NotSpecified', $null),
            '[{"Name":"StableFeed","Source":"https://example.com","Priority":2,"Enabled":false}]'
        )
        $parsed2 = ConvertFrom-FltTcpkgJson $withBanner
        if ($parsed2 -and $parsed2[0].Name -eq 'StableFeed') {
            _Diag_Pass 'ConvertFrom-FltTcpkgJson filters ErrorRecord banner lines'
        } else {
            _Diag_Fail 'ConvertFrom-FltTcpkgJson filters ErrorRecord banner lines' "Got: $parsed2"
        }
    } catch {
        _Diag_Fail 'ConvertFrom-FltTcpkgJson filters ErrorRecord banner lines' $_.Exception.Message
    }

    # Get-FltCfgValue — reads known default values without file I/O
    try {
        $timeout = Get-FltCfgValue 'ssh' 'timeoutSeconds' 0
        if ($timeout -gt 0) {
            _Diag_Pass "Get-FltCfgValue reads ssh.timeoutSeconds ($timeout)"
        } else {
            _Diag_Fail 'Get-FltCfgValue reads ssh.timeoutSeconds' "Got: $timeout"
        }
    } catch {
        _Diag_Fail 'Get-FltCfgValue reads ssh.timeoutSeconds' $_.Exception.Message
    }

    # Get-FltCfgValue — returns default when key is missing
    try {
        $missing = Get-FltCfgValue 'nonexistent' 'key' 'defaultValue'
        if ($missing -eq 'defaultValue') {
            _Diag_Pass 'Get-FltCfgValue returns default for missing key'
        } else {
            _Diag_Fail 'Get-FltCfgValue returns default for missing key' "Got: $missing"
        }
    } catch {
        _Diag_Fail 'Get-FltCfgValue returns default for missing key' $_.Exception.Message
    }

    # Get-FltTcpkgExe — resolves to a non-empty string
    try {
        $exe = Get-FltTcpkgExe
        if ($exe -and $exe.Length -gt 0) {
            _Diag_Pass "Get-FltTcpkgExe resolves to: $exe"
        } else {
            _Diag_Fail 'Get-FltTcpkgExe resolves to non-empty string' "Got: '$exe'"
        }
    } catch {
        _Diag_Fail 'Get-FltTcpkgExe resolves to non-empty string' $_.Exception.Message
    }

    # Invoke-FltWithStdin — spawns process, pipes stdin, reads exit code
    try {
        # Use pwsh on all platforms; fall back to cmd.exe on Windows if needed
        $testExe  = if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) { 'pwsh' } else { 'cmd.exe' }
        $testArgs = if ($testExe -eq 'pwsh') { @('-NoProfile','-Command','exit 0') } else { @('/c','exit 0') }
        $exitCode = Invoke-FltWithStdin -Exe $testExe -ArgList $testArgs -StdinText ''
        if ($exitCode -eq 0) {
            _Diag_Pass "Invoke-FltWithStdin spawns process and returns exit code (via $testExe)"
        } else {
            _Diag_Fail 'Invoke-FltWithStdin spawns process and returns exit code' "Exit: $exitCode"
        }
    } catch {
        _Diag_Fail 'Invoke-FltWithStdin spawns process and returns exit code' $_.Exception.Message
    }

    # FleetTarget class fields and methods
    try {
        # Verify field assignment works correctly (used by reachability job)
        $t = [FleetTarget]::new('TestTarget','10.0.0.1',22,'admin',$true)
        $t.Reachable = 'online'
        if ($t.Reachable -eq 'online') {
            _Diag_Pass 'FleetTarget.Reachable field assignment works'
        } else {
            _Diag_Fail 'FleetTarget.Reachable field assignment works' "Got: $($t.Reachable)"
        }
        # Verify InternetAccess field is set correctly by constructor
        if ($t.InternetAccess -eq $true) {
            _Diag_Pass 'FleetTarget.InternetAccess field set correctly by constructor'
        } else {
            _Diag_Fail 'FleetTarget.InternetAccess field set correctly' "Got: $($t.InternetAccess)"
        }
        # Verify InternetAccessDisplay and ReachableIcon are callable (PS7 class method
        # implicit [char] returns are not reliably capturable in test contexts)
        try { $t.InternetAccessDisplay() | Out-Null; $t.ReachableIcon() | Out-Null
            _Diag_Pass 'FleetTarget class methods callable without error'
        } catch { _Diag_Fail 'FleetTarget class methods callable' $_.Exception.Message }
    } catch {
        _Diag_Fail 'FleetTarget class field/method tests' $_.Exception.Message
    }

    # Posh-SSH availability
    try {
        $hasSsh = Ensure-FltPoshSsh
        if ($hasSsh) {
            _Diag_Pass 'Posh-SSH module is available'
        } else {
            _Diag_Fail 'Posh-SSH module is available' 'Install-Module Posh-SSH required'
        }
    } catch {
        _Diag_Fail 'Posh-SSH module is available' $_.Exception.Message
    }

    # Log subsystem — path resolves and directory exists
    try {
        $logPath = Get-FltLogPath
        $logDir  = Split-Path $logPath -Parent
        if ($logPath -and (Test-Path $logDir)) {
            _Diag_Pass "Log path resolves: $logPath"
        } elseif ($logPath) {
            _Diag_Fail 'Log directory exists' "Path: $logDir"
        } else {
            _Diag_Fail 'Log path resolves to non-empty string' ''
        }
    } catch {
        _Diag_Fail 'Log path resolves correctly' $_.Exception.Message
    }

    # Show-FltTable — verify it accepts valid inputs without throwing
    try {
        $testItems = @(
            [pscustomobject]@{ Name='Alpha'; Value='1' },
            [pscustomobject]@{ Name='Beta';  Value='2' }
        )
        $cols = @(
            @{ Header='Name';  Expr={ $_.Name  } },
            @{ Header='Value'; Expr={ $_.Value }; Align='Right' }
        )
        # Capture cursor row, render, then erase rendered lines with ANSI
        $startRow = [Console]::CursorTop
        Show-FltTable -Items $testItems -Columns $cols -Base 1
        $endRow = [Console]::CursorTop
        # Move back and erase each line the table wrote
        for ($r = $startRow; $r -le $endRow; $r++) {
            Write-Host -NoNewline "`e[${r};1H`e[2K"
        }
        # Reposition cursor to where output should continue
        Write-Host -NoNewline "`e[$($startRow);1H"
        _Diag_Pass 'Show-FltTable renders without error'
    } catch {
        _Diag_Fail 'Show-FltTable renders without error' $_.Exception.Message
    }

    # ── Summary ────────────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host "  $('-' * 62)" -ForegroundColor DarkGray
    $total = $Script:_diagPass + $Script:_diagFail
    if ($Script:_diagFail -eq 0) {
        Write-Host "  All $total checks passed." -ForegroundColor Green
    } else {
        Write-Host ("  {0} passed   {1} failed   {2} total" -f `
            $Script:_diagPass, $Script:_diagFail, $total) -ForegroundColor $(if ($Script:_diagFail -gt 0) { 'Red' } else { 'Green' })
    }
    Write-Host ''
}