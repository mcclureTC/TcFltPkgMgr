# =============================================================================
#  TcFltPkgMgr — Built-in Diagnostics
#  Run via Setup > 10. Diagnostics
#  Tests what actually matters — adapter wiring, real encryption round-trips,
#  functional correctness of core subsystems. No network, SSH, or tcpkg calls.
#
#  Test quality rules:
#  - Test behaviour, not existence. A function name check is a load test,
#    not a functional test. Prefer calling the function with known inputs.
#  - Redundant tests should be removed or merged.
#  - Every FAIL must tell the operator what to do about it.
#  - Add tests here when new subsystems are implemented.
# =============================================================================

function Invoke-FltDiagnostics {

    function _Diag_Pass([string]$Label) {
        Write-Host ("  {0,-60} " -f $Label) -NoNewline
        Write-Host 'PASS' -ForegroundColor Green
        $Script:_diagPass++
    }
    function _Diag_Fail([string]$Label, [string]$Detail = '') {
        Write-Host ("  {0,-60} " -f $Label) -NoNewline
        Write-Host 'FAIL' -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor Yellow }
        $Script:_diagFail++
    }
    function _Diag_Warn([string]$Label, [string]$Detail = '') {
        Write-Host ("  {0,-60} " -f $Label) -NoNewline
        Write-Host 'WARN' -ForegroundColor Yellow
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
        $Script:_diagWarn++
    }
    function _Diag_Section([string]$Title) {
        Write-Host ''
        Write-Host "  $Title" -ForegroundColor Cyan
        Write-Host "  $('-' * 62)" -ForegroundColor DarkGray
    }

    $Script:_diagPass = 0
    $Script:_diagFail = 0
    $Script:_diagWarn = 0

    Write-Host ''
    Write-Host '  TcFltPkgMgr — Internal Diagnostics' -ForegroundColor White
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')   PS $($PSVersionTable.PSVersion)   OS: $($Script:FltOS ?? 'unknown')" -ForegroundColor DarkGray

    # ── Display adapter (0-A.1) ────────────────────────────────────────────────
    _Diag_Section 'Display adapter (0-A.1)'

    # The critical test: does delegation actually work end-to-end?
    # Get-FltSafeWidth calls the adapter which calls the backend. If wiring is
    # broken this throws or returns garbage. Covers all 10 wired variables
    # indirectly — if wiring code ran correctly for one, it ran for all.
    try {
        $w = Get-FltSafeWidth
        if ($w -is [int] -and $w -gt 0) {
            _Diag_Pass "Display adapter delegates correctly — width=$w backend='$Script:FltDisplayBackend'"
        } else {
            _Diag_Fail 'Display adapter delegates correctly' "Get-FltSafeWidth returned: $w"
        }
    } catch {
        _Diag_Fail 'Display adapter delegates correctly' $_.Exception.Message
    }

    # Verify _Ansi_ backend functions are at script scope (catches the dot-source
    # scoping bug we hit during development — functions defined inside a function
    # scope disappear when the function returns)
    $missingAnsi = @(
        '_Ansi_GetSafeWidth','_Ansi_PaintRow','_Ansi_PaintTitleBar',
        '_Ansi_ShowFleetDashboard','_Ansi_ShowSetupDashboard',
        '_Ansi_ShowSourcesDashboard','_Ansi_ShowPackageStatusDashboard',
        '_Ansi_ShowFleetBatchDashboard','_Ansi_UpdateBatchRow','_Ansi_ShowFltTable'
    ) | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
    if ($missingAnsi.Count -eq 0) {
        _Diag_Pass 'All _Ansi_ backend functions defined at script scope'
    } else {
        _Diag_Fail "_Ansi_ functions at script scope" "Missing: $($missingAnsi -join ', ')"
    }

    # ── Credential adapter (0-A.2) ─────────────────────────────────────────────
    _Diag_Section 'Credential adapter (0-A.2)'

    # Real round-trip test — exercises actual encryption and decryption.
    # If this passes, the backend is fully functional.
    $testKey = 'DiagTest' + (Get-Random -Minimum 100000 -Maximum 999999)
    $testVal = 'DiagTestPassword_' + (Get-Random)
    try {
        if (-not (Set-FltStoredPassword -CredentialName $testKey -PlainPassword $testVal)) {
            throw 'Set-FltStoredPassword returned false'
        }
        $readVal = Get-FltStoredPassword -CredentialName $testKey
        if ($readVal -ne $testVal) {
            throw "Read '$readVal', expected '$testVal'"
        }
        if (-not (Remove-FltStoredPassword -CredentialName $testKey)) {
            throw 'Remove-FltStoredPassword returned false'
        }
        $afterDel = Get-FltStoredPassword -CredentialName $testKey
        if (-not [string]::IsNullOrEmpty($afterDel)) {
            throw "After Remove, Get returned '$afterDel'"
        }
        _Diag_Pass "Credential round-trip OK (backend='$Script:FltCredentialBackend')"
    } catch {
        Remove-FltStoredPassword -CredentialName $testKey -ErrorAction SilentlyContinue | Out-Null
        _Diag_Fail "Credential round-trip (backend='$Script:FltCredentialBackend')" $_.Exception.Message
    }

    # Resolve-FltPassword should return a stored credential without prompting.
    $resolveKey = 'DiagResolve' + (Get-Random -Minimum 100000 -Maximum 999999)
    $resolveVal = 'ResolveTestPwd_' + (Get-Random)
    try {
        Set-FltStoredPassword -CredentialName $resolveKey -PlainPassword $resolveVal | Out-Null
        $resolved = Resolve-FltPassword -CredentialName $resolveKey -PromptLabel 'Should not appear' -Silent
        if ($resolved -eq $resolveVal) {
            _Diag_Pass 'Resolve-FltPassword returns stored credential without prompting'
        } else {
            _Diag_Fail 'Resolve-FltPassword returns stored credential' "Got: '$resolved'"
        }
    } catch {
        _Diag_Fail 'Resolve-FltPassword returns stored credential' $_.Exception.Message
    } finally {
        Remove-FltStoredPassword -CredentialName $resolveKey -ErrorAction SilentlyContinue | Out-Null
    }

    # Config directory must be writable — silent failures here break credential saves
    try {
        $testFile = Join-Path $Script:FltConfigDir '.diag_write_test'
        [System.IO.File]::WriteAllText($testFile, 'test')
        Remove-Item $testFile -Force
        _Diag_Pass "Config directory is writable: $Script:FltConfigDir"
    } catch {
        _Diag_Fail 'Config directory is writable' "Saves will fail silently: $($_.Exception.Message)"
    }

    # ── Platform and feature gating (0-A.3) ────────────────────────────────────
    _Diag_Section 'Platform and feature gating (0-A.3)'

    if ($Script:FltOS -and $Script:FltOS -ne 'unknown') {
        _Diag_Pass "OS detected: '$Script:FltOS'"
    } else {
        _Diag_Fail 'OS detected' "Got '$Script:FltOS' — check TcFltPkgMgr.ps1 startup"
    }

    # Feature map correctness — not just that it exists, but that platform values are right
    try {
        $sshFeature     = Test-FltFeatureAvailable 'posh-ssh'   # true on all platforms
        $unknownFeature = Test-FltFeatureAvailable 'nonexistent' # should default true
        $tcpkgLocal     = Test-FltFeatureAvailable 'tcpkg-local' # true on Windows only

        if ($sshFeature -ne $true) {
            _Diag_Fail "Feature 'posh-ssh' should be available on all platforms" "Got: $sshFeature"
        } elseif ($unknownFeature -ne $true) {
            _Diag_Fail "Unknown feature should default to available" "Got: $unknownFeature"
        } elseif ($IsWindows -and $tcpkgLocal -ne $true) {
            _Diag_Fail "Feature 'tcpkg-local' should be true on Windows" "Got: $tcpkgLocal"
        } elseif (-not $IsWindows -and $tcpkgLocal -ne $false) {
            _Diag_Fail "Feature 'tcpkg-local' should be false on non-Windows" "Got: $tcpkgLocal"
        } else {
            _Diag_Pass "Feature gating correct for OS '$Script:FltOS' (tcpkg-local=$tcpkgLocal)"
        }
    } catch {
        _Diag_Fail 'Test-FltFeatureAvailable works' $_.Exception.Message
    }

    # ── Core subsystems ────────────────────────────────────────────────────────
    _Diag_Section 'Core subsystems'

    # ConvertFrom-FltTcpkgJson: parses valid JSON
    try {
        $json   = '[{"Name":"TestFeed","Source":"https://example.com","Priority":1,"Enabled":true}]'
        $parsed = ConvertFrom-FltTcpkgJson @($json)
        if ($parsed -and $parsed[0].Name -eq 'TestFeed' -and $parsed[0].Priority -eq 1) {
            _Diag_Pass 'ConvertFrom-FltTcpkgJson: parses JSON correctly'
        } else {
            _Diag_Fail 'ConvertFrom-FltTcpkgJson: parses JSON correctly' "Got: $parsed"
        }
    } catch { _Diag_Fail 'ConvertFrom-FltTcpkgJson: parses JSON correctly' $_.Exception.Message }

    # ConvertFrom-FltTcpkgJson: filters the version banner ErrorRecord tcpkg always emits
    try {
        $withBanner = @(
            [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('TcPkg 2.4.70'), 'test', 'NotSpecified', $null),
            '[{"Name":"StableFeed","Source":"https://example.com","Priority":2,"Enabled":false}]'
        )
        $parsed2 = ConvertFrom-FltTcpkgJson $withBanner
        if ($parsed2 -and $parsed2[0].Name -eq 'StableFeed') {
            _Diag_Pass 'ConvertFrom-FltTcpkgJson: filters tcpkg version banner'
        } else {
            _Diag_Fail 'ConvertFrom-FltTcpkgJson: filters tcpkg version banner' "Got: $parsed2"
        }
    } catch { _Diag_Fail 'ConvertFrom-FltTcpkgJson: filters tcpkg version banner' $_.Exception.Message }

    # Config: critical values are loaded with expected defaults
    try {
        $timeout  = Get-FltCfgValue 'ssh' 'timeoutSeconds' 0
        $throttle = Get-FltCfgValue 'ssh' 'throttleLimit' 0
        $remote   = Get-FltCfgValue 'tcpkg' 'remoteTcpkgPath' ''
        $missing  = Get-FltCfgValue 'nonexistent' 'key' 'sentinel'
        $ok = $timeout -gt 0 -and $throttle -gt 0 -and $remote -ne '' -and $missing -eq 'sentinel'
        if ($ok) {
            _Diag_Pass "Config values loaded (timeout=${timeout}s throttle=$throttle remote='$remote')"
        } else {
            _Diag_Fail 'Config values loaded' "timeout=$timeout throttle=$throttle remote='$remote' missing='$missing'"
        }
    } catch { _Diag_Fail 'Config values loaded correctly' $_.Exception.Message }

    # Feeds list is populated — empty FltFeeds would break all package search
    if ($Script:FltFeeds -and @($Script:FltFeeds).Count -gt 0) {
        _Diag_Pass "Feed list loaded ($(@($Script:FltFeeds).Count) feeds configured)"
    } else {
        _Diag_Warn 'Feed list loaded' 'No feeds in $Script:FltFeeds — package search will be empty. Run: Setup > 5. Gen config'
    }

    # Log directory is writable — silent log failures are hard to diagnose
    try {
        $logPath = Get-FltLogPath
        $logDir  = Split-Path $logPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $testLog = Join-Path $logDir '.diag_write_test'
        [System.IO.File]::WriteAllText($testLog, 'test')
        Remove-Item $testLog -Force
        _Diag_Pass "Log directory writable: $logDir"
    } catch { _Diag_Fail 'Log directory writable' $_.Exception.Message }

    # Invoke-FltWithStdin: spawns a real process and reads its exit code
    # This is the mechanism used for all tcpkg operations requiring stdin
    try {
        $testExe  = if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) { 'pwsh' } else { 'cmd.exe' }
        $testArgs = if ($testExe -eq 'pwsh') { @('-NoProfile','-Command','exit 0') } else { @('/c','exit 0') }
        $exit0    = Invoke-FltWithStdin -Exe $testExe -ArgList $testArgs -StdinText ''

        $testArgs1 = if ($testExe -eq 'pwsh') { @('-NoProfile','-Command','exit 1') } else { @('/c','exit 1') }
        $exit1    = Invoke-FltWithStdin -Exe $testExe -ArgList $testArgs1 -StdinText ''

        if ($exit0 -eq 0 -and $exit1 -eq 1) {
            _Diag_Pass "Invoke-FltWithStdin: exit codes correct (0→$exit0, 1→$exit1)"
        } else {
            _Diag_Fail 'Invoke-FltWithStdin: exit codes correct' "exit0=$exit0 exit1=$exit1"
        }
    } catch { _Diag_Fail 'Invoke-FltWithStdin: process spawn and exit code' $_.Exception.Message }

    # FleetTarget: field assignment and defaults (reachability job depends on this)
    try {
        $t = [FleetTarget]::new('PC-1','192.168.100.101',22,'admin',$true)
        $errors = @()
        if ($t.Name    -ne 'PC-1')              { $errors += "Name='$($t.Name)'" }
        if ($t.Address -ne '192.168.100.101')   { $errors += "Address='$($t.Address)'" }
        if ($t.Port    -ne 22)                  { $errors += "Port=$($t.Port)" }
        if ($t.User    -ne 'admin')             { $errors += "User='$($t.User)'" }
        if ($t.InternetAccess -ne $true)        { $errors += "InternetAccess=$($t.InternetAccess)" }
        if ($t.Reachable -ne 'unknown')         { $errors += "Reachable='$($t.Reachable)'" }
        # Verify field mutation (used by reachability background job)
        $t.Reachable = 'online'
        if ($t.Reachable -ne 'online')          { $errors += "Reachable mutation failed" }
        if ($errors.Count -eq 0) {
            _Diag_Pass 'FleetTarget: fields and mutation correct'
        } else {
            _Diag_Fail 'FleetTarget: fields and mutation correct' ($errors -join ', ')
        }
    } catch { _Diag_Fail 'FleetTarget: fields and mutation' $_.Exception.Message }

    # _Save-UiCfgValue: updates in-memory config and persists to settings.local.json
    try {
        $origVal  = Get-FltCfgValue 'ui' 'dashboardPageSize' 20
        $testVal  = 99
        $saved    = _Save-UiCfgValue -Key 'dashboardPageSize' -Value $testVal
        $readBack = Get-FltCfgValue 'ui' 'dashboardPageSize' 20

        # Verify in-memory update
        if (-not $saved) {
            _Diag_Fail '_Save-UiCfgValue persists setting' 'Function returned false'
        } elseif ($readBack -ne $testVal) {
            _Diag_Fail '_Save-UiCfgValue updates in-memory config' "Got $readBack, expected $testVal"
        } else {
            _Diag_Pass "_Save-UiCfgValue round-trip OK (set=$testVal read=$readBack)"
        }

        # Verify settings.local.json was written
        $localPath = Join-Path $Script:FltConfigDir 'settings.local.json'
        if (Test-Path $localPath) {
            $localJson = Get-Content $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($localJson.ui.dashboardPageSize -eq $testVal) {
                _Diag_Pass '_Save-UiCfgValue wrote to settings.local.json'
            } else {
                _Diag_Fail '_Save-UiCfgValue wrote to settings.local.json' `
                    "File has $($localJson.ui.dashboardPageSize), expected $testVal"
            }
        } else {
            _Diag_Fail '_Save-UiCfgValue wrote to settings.local.json' 'File not created'
        }

        # Restore original value
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value $origVal | Out-Null
    } catch {
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value 20 -ErrorAction SilentlyContinue | Out-Null
        _Diag_Fail '_Save-UiCfgValue round-trip' $_.Exception.Message
    }

    # Pagination math: verify page slicing with known inputs
    try {
        # Simulate 7 targets, page size 3
        $fakeTargets = 1..7 | ForEach-Object { [FleetTarget]::new("PC-$_","10.0.0.$_",22,'admin',$true) }
        $pageSize    = 3
        $errors      = @()

        # Page 0: items 0-2 (targets 11-13)
        $p0 = @($fakeTargets | Select-Object -Skip 0 -First $pageSize)
        if ($p0.Count -ne 3 -or $p0[0].Name -ne 'PC-1' -or $p0[2].Name -ne 'PC-3') {
            $errors += "Page 0 wrong: got $($p0.Name -join ',')"
        }

        # Page 1: items 3-5 (targets 14-16)
        $p1 = @($fakeTargets | Select-Object -Skip 3 -First $pageSize)
        if ($p1.Count -ne 3 -or $p1[0].Name -ne 'PC-4' -or $p1[2].Name -ne 'PC-6') {
            $errors += "Page 1 wrong: got $($p1.Name -join ',')"
        }

        # Page 2: item 6 only (target 17)
        $p2 = @($fakeTargets | Select-Object -Skip 6 -First $pageSize)
        if ($p2.Count -ne 1 -or $p2[0].Name -ne 'PC-7') {
            $errors += "Page 2 wrong: got $($p2.Name -join ',')"
        }

        # Total pages
        $totalPages = [Math]::Ceiling($fakeTargets.Count / $pageSize)
        if ($totalPages -ne 3) { $errors += "Total pages wrong: got $totalPages" }

        if ($errors.Count -eq 0) {
            _Diag_Pass 'Pagination math correct (7 targets / page size 3 = 3 pages)'
        } else {
            _Diag_Fail 'Pagination math correct' ($errors -join '; ')
        }
    } catch {
        _Diag_Fail 'Pagination math' $_.Exception.Message
    }

    # Throttle limits are within safe operating bounds (Phase 0.2)
    try {
        $sshThrottle    = [int](Get-FltCfgValue 'ssh'    'throttleLimit' 25)
        $dockerThrottle = [int](Get-FltCfgValue 'docker' 'throttleLimit' 20)
        $errors = @()
        if ($sshThrottle    -lt 1 -or $sshThrottle    -gt 50) { $errors += "ssh.throttleLimit=$sshThrottle (must be 1-50)" }
        if ($dockerThrottle -lt 1 -or $dockerThrottle -gt 50) { $errors += "docker.throttleLimit=$dockerThrottle (must be 1-50)" }
        if ($errors.Count -eq 0) {
            _Diag_Pass "Throttle limits in safe range (ssh=$sshThrottle docker=$dockerThrottle)"
        } else {
            _Diag_Fail 'Throttle limits in safe range' ($errors -join '; ')
        }
    } catch { _Diag_Fail 'Throttle limits readable from config' $_.Exception.Message }

    # Start-FltReachJob returns a job object without error
    # Does not wait for TCP — just verifies the parallel job structure is valid
    try {
        $testTarget = [FleetTarget]::new('DiagTest','127.0.0.1',22,'admin',$false)
        $job = Start-FltReachJob -Targets @($testTarget)
        if ($job -and $job.Id -gt 0) {
            _Diag_Pass "Start-FltReachJob creates parallel background job (id=$($job.Id))"
            Stop-Job   $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } else {
            _Diag_Fail 'Start-FltReachJob creates background job' "Got: $job"
        }
    } catch { _Diag_Fail 'Start-FltReachJob callable without error' $_.Exception.Message }

    try {
        if (Ensure-FltPoshSsh) {
            _Diag_Pass 'Posh-SSH module available'
        } else {
            _Diag_Fail 'Posh-SSH module available' 'Run: Install-Module Posh-SSH -Scope CurrentUser'
        }
    } catch { _Diag_Fail 'Posh-SSH module available' $_.Exception.Message }

    # Module load: check that all required functions exist (load test, not functional)
    $requiredFunctions = @(
        'Get-FleetTargets','Add-FleetTarget','Edit-FleetTarget','Remove-FleetTarget',
        'Import-FleetTargetsCsv','Export-FleetTargetsCsv',
        'Invoke-FltTcpkg','Invoke-FltSshBatch','Invoke-FleetAction',
        'Get-FltSources','Repair-FltSourcePriorities',
        'Show-FleetDashboard','Show-SetupDashboard','Show-SourcesDashboard',
        'Show-FleetBatchDashboard','Update-FltBatchRow','Show-FltTable',
        'Get-FltStoredPassword','Set-FltStoredPassword','Remove-FltStoredPassword',
        'Resolve-FltPassword','Write-FltBatchEntry','Invoke-FltWithStdin',
        'Test-FltFeatureAvailable','Get-FltTcpkgExe',
        'Invoke-UiConfigMenu','_Save-UiCfgValue'
    )
    $missingFns = @($requiredFunctions | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
    if ($missingFns.Count -eq 0) {
        _Diag_Pass "All $($requiredFunctions.Count) required functions loaded"
    } else {
        _Diag_Fail "Required functions loaded ($($requiredFunctions.Count-$missingFns.Count)/$($requiredFunctions.Count))" `
            "Missing: $($missingFns -join ', ')"
    }

    # ── Summary ────────────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host "  $('-' * 64)" -ForegroundColor DarkGray
    $total = $Script:_diagPass + $Script:_diagFail + $Script:_diagWarn
    if ($Script:_diagFail -eq 0 -and $Script:_diagWarn -eq 0) {
        Write-Host "  All $($Script:_diagPass) checks passed." -ForegroundColor Green
    } elseif ($Script:_diagFail -eq 0) {
        Write-Host ("  {0} passed   {1} warnings   {2} total" -f `
            $Script:_diagPass, $Script:_diagWarn, $total) -ForegroundColor Yellow
    } else {
        Write-Host ("  {0} passed   {1} failed   {2} warnings   {3} total" -f `
            $Script:_diagPass, $Script:_diagFail, $Script:_diagWarn, $total) -ForegroundColor Red
    }
    Write-Host ''
}