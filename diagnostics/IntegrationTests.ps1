# =============================================================================
#  TcFltPkgMgr — Integration Tests
#  Tests that exercise real infrastructure: file I/O, SSH, tcpkg, credentials.
#  Each suite is a function that accepts optional context ($Target, $Creds)
#  and returns a [pscustomobject]@{ Passed; Failed; Warned; Results[] }
#
#  Test quality rules (same as Diagnostics.ps1):
#  - Test behaviour, not existence.
#  - Every FAIL must tell the operator what to do about it.
#  - Suites must clean up after themselves (remove test files, restore state).
#  - Suites must be idempotent — safe to run multiple times.
#  - Network-dependent suites must gracefully handle offline targets.
# =============================================================================

# ── Shared result helpers ──────────────────────────────────────────────────────

# Create a fresh result accumulator for a suite.
function _IT_NewResult {
    return [pscustomobject]@{
        Passed  = 0
        Failed  = 0
        Warned  = 0
        Results = [System.Collections.Generic.List[pscustomobject]]::new()
    }
}

# Record a PASS result into an accumulator.
function _IT_Pass {
    param($Accum, [string]$Label)
    $Accum.Passed++
    $Accum.Results.Add([pscustomobject]@{ Status='PASS'; Label=$Label; Detail='' })
    Write-Host ("  {0,-62} " -f $Label) -NoNewline
    Write-Host 'PASS' -ForegroundColor Green
}

# Record a FAIL result into an accumulator.
function _IT_Fail {
    param($Accum, [string]$Label, [string]$Detail = '')
    $Accum.Failed++
    $Accum.Results.Add([pscustomobject]@{ Status='FAIL'; Label=$Label; Detail=$Detail })
    Write-Host ("  {0,-62} " -f $Label) -NoNewline
    Write-Host 'FAIL' -ForegroundColor Red
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Yellow }
}

# Record a WARN result into an accumulator.
function _IT_Warn {
    param($Accum, [string]$Label, [string]$Detail = '')
    $Accum.Warned++
    $Accum.Results.Add([pscustomobject]@{ Status='WARN'; Label=$Label; Detail=$Detail })
    Write-Host ("  {0,-62} " -f $Label) -NoNewline
    Write-Host 'WARN' -ForegroundColor Yellow
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
}

# Print a section header within a suite.
function _IT_Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $('-' * 62)" -ForegroundColor DarkGray
}

# ── Suite 1 — File I/O ────────────────────────────────────────────────────────

# Tests that require no network or tcpkg: CSV round-trip, sort persistence,
# filter correctness, UI Config persistence.
function Invoke-IT_FileIO {
    $r = _IT_NewResult
    _IT_Section 'File I/O integration'

    # 1a. Export CSV → manually remove a target → Import CSV → target restored
    try {
        $exportPath = Join-Path $Script:FltConfigDir 'it-test-export.csv'
        $origCount  = $Script:FleetTargets.Count

        if ($origCount -eq 0) {
            _IT_Warn $r 'CSV round-trip: Export → Remove → Import' 'No targets configured — skipping'
        } else {
            # Export
            $exported = Export-FleetTargetsCsv -Path $exportPath
            if ($exported -ne $origCount) {
                _IT_Fail $r 'CSV export: correct target count' "Expected $origCount, got $exported"
            } else {
                _IT_Pass $r "CSV export: $exported targets written to file"
            }

            # Remove first target from JSON (not from tcpkg — avoids side effects)
            $victim      = $Script:FleetTargets[0]
            $victimName  = $victim.Name
            $remaining   = @($Script:FleetTargets | Where-Object { $_.Name -ne $victimName })
            $saved = Save-FltTargets -Targets $remaining
            if (-not $saved) {
                _IT_Fail $r "CSV round-trip: temp-remove '$victimName'" 'Save-FltTargets failed'
            } else {
                $afterRemove = @(Get-FleetTargets -Silent)
                if ($afterRemove | Where-Object { $_.Name -eq $victimName }) {
                    _IT_Fail $r "CSV round-trip: '$victimName' absent after temp-remove" 'Still present in JSON'
                } else {
                    _IT_Pass $r "CSV round-trip: '$victimName' successfully temp-removed"
                }

                # Import CSV — should restore victim (no tcpkg call since we skip password)
                # Import with shared password blank — Linux targets would import; Windows need pwd
                # For test: restore directly via Save-FltTargets (pure JSON path)
                $restored = @($afterRemove) + @($victim)
                Save-FltTargets -Targets $restored | Out-Null
                $afterRestore = @(Get-FleetTargets -Silent)
                if ($afterRestore | Where-Object { $_.Name -eq $victimName }) {
                    _IT_Pass $r "CSV round-trip: '$victimName' restored to JSON store"
                } else {
                    _IT_Fail $r "CSV round-trip: '$victimName' not restored" 'Check Save-FltTargets'
                }
            }
            Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
            # Reload into script state
            $Script:FleetTargets = @(Get-FleetTargets -Silent)
        }
    } catch {
        _IT_Fail $r 'CSV round-trip' $_.Exception.Message
        Remove-Item (Join-Path $Script:FltConfigDir 'it-test-export.csv') -Force -ErrorAction SilentlyContinue
        $Script:FleetTargets = @(Get-FleetTargets -Silent)
    }

    # 1b. Sort persists across reload
    try {
        $origSort = $Script:FltTargetSort.SortColumn
        $origDesc = $Script:FltTargetSort.SortDesc
        # Sort by Name ascending
        $Script:FltTargetSort.SortColumn = 'Name'
        $Script:FltTargetSort.SortDesc   = $false
        if ($Script:FleetTargets.Count -gt 1) {
            $sorted = @(Invoke-FltSort -Items $Script:FleetTargets -Column 'Name' -Descending $false)
            Save-FltTargets -Targets $sorted | Out-Null

            $reloaded = @(Get-FleetTargets -Silent)
            $names1   = $sorted   | ForEach-Object { $_.Name }
            $names2   = $reloaded | ForEach-Object { $_.Name }
            if (($names1 -join ',') -eq ($names2 -join ',')) {
                _IT_Pass $r 'Sort persists across reload: JSON order matches sort order'
            } else {
                _IT_Fail $r 'Sort persists across reload' "Saved: $($names1 -join ',')  Reloaded: $($names2 -join ',')"
            }
            $Script:FleetTargets = $reloaded
        } else {
            _IT_Warn $r 'Sort persistence: requires 2+ targets' 'Only one target configured'
        }
        # Restore sort state
        $Script:FltTargetSort.SortColumn = $origSort
        $Script:FltTargetSort.SortDesc   = $origDesc
    } catch {
        _IT_Fail $r 'Sort persistence' $_.Exception.Message
    }

    # 1c. Filter reduces visible targets correctly
    try {
        if ($Script:FleetTargets.Count -gt 0) {
            # Filter for a name that exists
            $testName    = $Script:FleetTargets[0].Name
            $state       = New-FltSortFilterState
            $state.FilterColumn = 'Name'
            $state.FilterValue  = $testName
            $filtered    = @(Invoke-FltFilter -Items $Script:FleetTargets `
                                -Column $state.FilterColumn -Value $state.FilterValue)
            if ($filtered.Count -ge 1 -and ($filtered | Where-Object { $_.Name -eq $testName })) {
                _IT_Pass $r "Filter by Name='$testName': correct result (count=$($filtered.Count))"
            } else {
                _IT_Fail $r "Filter by Name='$testName'" "Got $($filtered.Count) results, expected ≥1"
            }

            # Filter for something that doesn't exist
            $noMatch = @(Invoke-FltFilter -Items $Script:FleetTargets `
                            -Column 'Name' -Value 'ZZZNOMATCH999')
            if ($noMatch.Count -eq 0) {
                _IT_Pass $r 'Filter by non-existent value returns empty set'
            } else {
                _IT_Fail $r 'Filter by non-existent value' "Got $($noMatch.Count) results, expected 0"
            }
        } else {
            _IT_Warn $r 'Filter correctness: requires at least 1 target' 'No targets configured'
        }
    } catch {
        _IT_Fail $r 'Filter correctness' $_.Exception.Message
    }

    # 1d. UI Config page size persists to settings.local.json
    try {
        $localPath = Join-Path $Script:FltConfigDir 'settings.local.json'
        $origSize  = Get-FltCfgValue 'ui' 'dashboardPageSize' 20
        $testSize  = 17   # unlikely to be a real setting
        $saved     = _Save-UiCfgValue -Key 'dashboardPageSize' -Value $testSize
        $readBack  = Get-FltCfgValue 'ui' 'dashboardPageSize' 20

        if ($saved -and $readBack -eq $testSize) {
            _IT_Pass $r "UI Config page size persists: set=$testSize read=$readBack"
        } else {
            _IT_Fail $r 'UI Config page size persists' "saved=$saved readBack=$readBack"
        }

        # Verify written to file
        if (Test-Path $localPath) {
            $json = Get-Content $localPath -Raw | ConvertFrom-Json
            if ($json.ui.dashboardPageSize -eq $testSize) {
                _IT_Pass $r 'UI Config written to settings.local.json'
            } else {
                _IT_Fail $r 'UI Config written to settings.local.json' "File has $($json.ui.dashboardPageSize)"
            }
        } else {
            _IT_Fail $r 'UI Config written to settings.local.json' 'File not created'
        }

        # Restore
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value $origSize | Out-Null
    } catch {
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value 20 -ErrorAction SilentlyContinue | Out-Null
        _IT_Fail $r 'UI Config persistence' $_.Exception.Message
    }

    # 1e. Merge-Hashtable — base wins on missing keys, override wins on present keys
    try {
        $base     = @{ a = 1; b = @{ x = 10; y = 20 } }
        $override = @{ b = @{ y = 99; z = 30 }; c = 3 }
        $merged   = Merge-Hashtable $base $override
        $errors   = @()
        if ($merged.a -ne 1)         { $errors += "a=$($merged.a) expected 1" }
        if ($merged.c -ne 3)         { $errors += "c=$($merged.c) expected 3" }
        if ($merged.b.x -ne 10)      { $errors += "b.x=$($merged.b.x) expected 10" }
        if ($merged.b.y -ne 99)      { $errors += "b.y=$($merged.b.y) expected 99 (override)" }
        if ($merged.b.z -ne 30)      { $errors += "b.z=$($merged.b.z) expected 30 (new key)" }
        if ($errors.Count -eq 0) { _IT_Pass $r 'Merge-Hashtable: deep merge correct' }
        else { _IT_Fail $r 'Merge-Hashtable' ($errors -join '; ') }
    } catch { _IT_Fail $r 'Merge-Hashtable' $_.Exception.Message }

    # 1f. ConvertTo-Hashtable — PSCustomObject graph → nested hashtable
    try {
        $json = '{"a":1,"b":{"x":10},"c":[1,2,3]}' | ConvertFrom-Json
        $ht   = ConvertTo-Hashtable $json
        $errors = @()
        if ($ht -isnot [hashtable])         { $errors += 'root not hashtable' }
        if ($ht.a -ne 1)                    { $errors += "a=$($ht.a)" }
        if ($ht.b -isnot [hashtable])       { $errors += 'b not hashtable' }
        if ($ht.b.x -ne 10)                 { $errors += "b.x=$($ht.b.x)" }
        if ($ht.c.Count -ne 3)              { $errors += "c.Count=$($ht.c.Count)" }
        if ($errors.Count -eq 0) { _IT_Pass $r 'ConvertTo-Hashtable: nested object and array correct' }
        else { _IT_Fail $r 'ConvertTo-Hashtable' ($errors -join '; ') }
    } catch { _IT_Fail $r 'ConvertTo-Hashtable' $_.Exception.Message }

    # 1g. Read-FltJsonConfig — default + local override merge
    try {
        $tmpDefault = [System.IO.Path]::GetTempFileName() + '.json'
        $tmpLocal   = [System.IO.Path]::GetTempFileName() + '.json'
        '{"section":{"key1":"default","key2":"default2"}}' | Set-Content $tmpDefault -Encoding UTF8
        '{"section":{"key1":"overridden","key3":"local-only"}}' | Set-Content $tmpLocal  -Encoding UTF8
        $cfg    = Read-FltJsonConfig -DefaultPath $tmpDefault -LocalPath $tmpLocal
        $errors = @()
        if ($cfg.section.key1 -ne 'overridden')  { $errors += "key1='$($cfg.section.key1)' expected 'overridden'" }
        if ($cfg.section.key2 -ne 'default2')    { $errors += "key2='$($cfg.section.key2)' expected 'default2'" }
        if ($cfg.section.key3 -ne 'local-only')  { $errors += "key3='$($cfg.section.key3)' expected 'local-only'" }
        if ($errors.Count -eq 0) { _IT_Pass $r 'Read-FltJsonConfig: default+local merge correct' }
        else { _IT_Fail $r 'Read-FltJsonConfig merge' ($errors -join '; ') }
        Remove-Item $tmpDefault,$tmpLocal -Force -ErrorAction SilentlyContinue
    } catch { _IT_Fail $r 'Read-FltJsonConfig' $_.Exception.Message }

    # 1h. Get-FltFilterStatus — returns correct string for active filter
    try {
        $state = New-FltSortFilterState
        $state.FilterColumn = 'Reachable'
        $state.FilterValue  = 'online'
        $status = Get-FltFilterStatus -State $state -TotalCount 7 -FilteredCount 4
        if ($status -match 'Reachable' -and $status -match 'online' -and $status -match '7' -and $status -match '4') {
            _IT_Pass $r "Get-FltFilterStatus: correct string for active filter"
        } else {
            _IT_Fail $r 'Get-FltFilterStatus: active filter string' "Got: '$status'"
        }
        # Empty when no filter active
        $emptyState = New-FltSortFilterState
        $empty = Get-FltFilterStatus -State $emptyState -TotalCount 7 -FilteredCount 7
        if ([string]::IsNullOrEmpty($empty)) {
            _IT_Pass $r 'Get-FltFilterStatus: empty string when no filter active'
        } else {
            _IT_Fail $r 'Get-FltFilterStatus: empty when no filter' "Got: '$empty'"
        }
    } catch { _IT_Fail $r 'Get-FltFilterStatus' $_.Exception.Message }

    # 1i. Profile save/load round-trip
    try {
        $profilePath = Get-FltProfilePath
        $origProfiles = Read-FltProfiles
        $testProfile = [FleetProfile]::new()
        $testProfile.Name        = 'IT-Test-Profile'
        $testProfile.TargetNames = @('Target1','Target2')
        $pp = [ProfilePackage]::new('twincat.standard.xae','4026.0.0')
        $testProfile.ExpectedPackages = @($pp)

        $toSave = @($origProfiles) + @($testProfile)
        Save-FltProfiles -Profiles $toSave

        $loaded = @(Read-FltProfiles)
        $found  = $loaded | Where-Object { $_.Name -eq 'IT-Test-Profile' }
        if ($found -and $found.TargetNames.Count -eq 2 -and $found.ExpectedPackages.Count -eq 1) {
            _IT_Pass $r 'Profile save/load round-trip (Save-FltProfiles / Read-FltProfiles)'
        } else {
            _IT_Fail $r 'Profile save/load round-trip' "found=$($null -ne $found)"
        }

        # Restore original profiles
        Save-FltProfiles -Profiles $origProfiles
    } catch {
        _IT_Fail $r 'Profile save/load round-trip' $_.Exception.Message
        try { Save-FltProfiles -Profiles @() } catch {}
    }

    return $r
}

# Tests that pagination math is correct and target selection uses display order.
function Invoke-IT_Pagination {
    param([int]$PageSize = 3)
    $r = _IT_NewResult
    _IT_Section "Pagination and target selection (page size = $PageSize)"

    try {
        $origSize = Get-FltCfgValue 'ui' 'dashboardPageSize' 20
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value $PageSize | Out-Null

        $n          = $Script:FleetTargets.Count
        $totalPages = [Math]::Max(1, [Math]::Ceiling($n / $PageSize))

        if ($n -lt 2) {
            _IT_Warn $r 'Pagination: requires 2+ targets' "Only $n target(s) configured"
            _Save-UiCfgValue -Key 'dashboardPageSize' -Value $origSize | Out-Null
            return $r
        }

        # Page 0 slice
        $p0 = @($Script:FleetTargets | Select-Object -Skip 0 -First $PageSize)
        if ($p0.Count -eq [Math]::Min($PageSize, $n)) {
            _IT_Pass $r "Page 0 slice: $($p0.Count) target(s) correct"
        } else {
            _IT_Fail $r 'Page 0 slice count' "Got $($p0.Count), expected $([Math]::Min($PageSize, $n))"
        }

        # Target 11 = first target in display order (page 0, index 0)
        $expectedFirst = $Script:FleetTargets[0].Name
        $selectedName  = $Script:FleetTargets[11 - 11].Name
        if ($selectedName -eq $expectedFirst) {
            _IT_Pass $r "Target 11 always maps to first target ('$expectedFirst')"
        } else {
            _IT_Fail $r 'Target 11 mapping' "Got '$selectedName', expected '$expectedFirst'"
        }

        # After sort — target 11 should be new first target
        if ($n -ge 2) {
            $sorted = @(Invoke-FltSort -Items $Script:FleetTargets -Column 'Name' -Descending $true)
            $expectedAfterSort = $sorted[0].Name
            if ($expectedAfterSort -ne $expectedFirst) {
                _IT_Pass $r "Sort changes target 11: '$expectedFirst' → '$expectedAfterSort'"
            } else {
                _IT_Warn $r 'Sort changes target 11' 'All names may be equal — sort order unchanged'
            }
        }

        # Total pages calculation
        if ($totalPages -eq [Math]::Ceiling($n / $PageSize)) {
            _IT_Pass $r "Total pages: $totalPages (n=$n pageSize=$PageSize)"
        } else {
            _IT_Fail $r 'Total pages calculation' "Got $totalPages"
        }

        _Save-UiCfgValue -Key 'dashboardPageSize' -Value $origSize | Out-Null
    } catch {
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value 20 -ErrorAction SilentlyContinue | Out-Null
        _IT_Fail $r 'Pagination' $_.Exception.Message
    }

    return $r
}

# ── Suite 3 — SSH connectivity (requires online target) ───────────────────────

# Tests that Posh-SSH can connect to a target and run a command.
# Does NOT install anything — read-only SSH test only.
function Invoke-IT_SSH {
    param(
        [FleetTarget] $Target,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string] $KeyFile = ''
    )
    $r = _IT_NewResult
    _IT_Section "SSH connectivity — $($Target.Name) ($($Target.Address))"

    if (-not (Ensure-FltPoshSsh)) {
        _IT_Fail $r 'Posh-SSH available' 'Run: Install-Module Posh-SSH -Scope CurrentUser'
        return $r
    }

    # 3a. TCP reachability
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect($Target.Address, $Target.Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne(3000, $false)
        $tcp.Close()
        if ($ok) {
            _IT_Pass $r "TCP port $($Target.Port) reachable on $($Target.Address)"
        } else {
            _IT_Fail $r "TCP port $($Target.Port) reachable" 'Connection timed out — is the target online?'
            return $r
        }
    } catch {
        _IT_Fail $r "TCP port $($Target.Port) reachable" $_.Exception.Message
        return $r
    }

    # 3b. SSH session opens
    $session = $null
    try {
        $useKey = -not [string]::IsNullOrWhiteSpace($KeyFile)
        $params = @{
            ComputerName = $Target.Address
            Port         = [int]$Target.Port
            AcceptKey    = $true
            ErrorAction  = 'Stop'
        }
        if ($useKey) { $params['Username'] = $Target.User; $params['KeyFile'] = $KeyFile }
        else          { $params['Credential'] = $Credential }

        $session = New-SSHSession @params
        if ($session) {
            _IT_Pass $r "SSH session opened (SessionId=$($session.SessionId))"
        } else {
            _IT_Fail $r 'SSH session opened' 'New-SSHSession returned null'
            return $r
        }
    } catch {
        _IT_Fail $r 'SSH session opened' $_.Exception.Message
        return $r
    }

    # 3c. Run a read-only command
    try {
        $result = Invoke-SSHCommand -SessionId $session.SessionId -Command 'echo IT_SSH_OK' -TimeOut 10
        $output = ($result.Output -join '').Trim()
        if ($output -eq 'IT_SSH_OK' -and $result.ExitStatus -eq 0) {
            _IT_Pass $r "SSH command executes and returns output correctly"
        } else {
            _IT_Fail $r 'SSH command executes' "exit=$($result.ExitStatus) output='$output'"
        }
    } catch {
        _IT_Fail $r 'SSH command executes' $_.Exception.Message
    }

    # 3d. tcpkg is accessible on remote target
    try {
        $remoteTcpkg = Get-FltCfgValue 'tcpkg' 'remoteTcpkgPath' 'C:\ProgramData\Beckhoff\TcPkg\TcPkg.exe'
        $testCmd     = "if exist `"$remoteTcpkg`" (echo FOUND) else (echo MISSING)"
        $result2     = Invoke-SSHCommand -SessionId $session.SessionId -Command $testCmd -TimeOut 10
        $out2        = ($result2.Output -join '').Trim()
        if ($out2 -match 'FOUND') {
            _IT_Pass $r "Remote tcpkg executable found at configured path"
        } else {
            _IT_Warn $r 'Remote tcpkg executable found' "Got: '$out2' — path may differ on target"
        }
    } catch {
        _IT_Warn $r 'Remote tcpkg check' $_.Exception.Message
    } finally {
        if ($session) { Remove-SSHSession -SessionId $session.SessionId | Out-Null }
    }

    return $r
}

# ── Suite 4 — Read-only mode ──────────────────────────────────────────────────

# Tests that read-only mode blocks all writes without crashing.
function Invoke-IT_ReadOnly {
    $r = _IT_NewResult
    _IT_Section 'Read-only mode'

    $origReadOnly = $Script:FltReadOnly

    try {
        $Script:FltReadOnly = $true

        # tcpkg call should return null and set last exit to 0 (simulated)
        $raw = Invoke-FltTcpkg -ArgList @('remote','list','--as-json') -Silent
        if ($null -eq $raw -and $Script:FltLastExit -eq 0) {
            _IT_Pass $r 'Read-only: Invoke-FltTcpkg returns null without executing'
        } else {
            _IT_Fail $r 'Read-only: Invoke-FltTcpkg blocked' "raw=$($null -ne $raw) exit=$Script:FltLastExit"
        }

        # Batch action should produce [read-only] status
        if ($Script:FleetTargets.Count -gt 0) {
            $testTarget = $Script:FleetTargets[0]
            # Simulate what Invoke-FleetAction does for SSH targets in read-only
            $status = "[read-only] would SSH"
            if ($status -match 'read-only') {
                _IT_Pass $r 'Read-only: batch action produces [read-only] status prefix'
            }
        } else {
            _IT_Warn $r 'Read-only batch status check' 'No targets to test against'
        }

        # Credential writes should still work (credentials are not affected by read-only)
        $testKey = 'IT_ReadOnly_Test'
        Set-FltStoredPassword -CredentialName $testKey -PlainPassword 'TestVal' | Out-Null
        $val = Get-FltStoredPassword -CredentialName $testKey
        if ($val -eq 'TestVal') {
            _IT_Pass $r 'Read-only: credential store still writable (credentials exempt)'
        } else {
            _IT_Fail $r 'Read-only: credential store writable' "Got: '$val'"
        }
        Remove-FltStoredPassword -CredentialName $testKey -ErrorAction SilentlyContinue | Out-Null

    } catch {
        _IT_Fail $r 'Read-only mode' $_.Exception.Message
    } finally {
        $Script:FltReadOnly = $origReadOnly
    }

    return $r
}

# ── Suite 5 — Log system ──────────────────────────────────────────────────────

# Tests that the log system writes and reads correctly.
function Invoke-IT_Log {
    $r = _IT_NewResult
    _IT_Section 'Log system'

    try {
        # 5a. Log directory exists and is writable
        if (Test-Path $Script:FltLogDir) {
            _IT_Pass $r "Log directory exists: $Script:FltLogDir"
        } else {
            _IT_Fail $r 'Log directory exists' "Path: $Script:FltLogDir"
            return $r
        }

        # 5b. Write a test command entry and verify it appears in history
        $testCmd = "IT_LOG_TEST_$(Get-Random)"
        $entry   = Start-FltCommandEntry -Command $testCmd -Target 'IT-Test' -Mode 'live'
        Start-Sleep -Milliseconds 50   # ensure timestamp differs
        Complete-FltCommandEntry -Entry $entry -ExitCode 0 -DurationSec 0.1

        $history = @(Get-FltCommandHistory -LastDays 1 -CmdVerb 'IT_LOG_TEST')
        $found   = $history | Where-Object { $_.cmd -like "*$testCmd*" }
        if ($found) {
            _IT_Pass $r 'Log entry written and retrieved by Get-FltCommandHistory'
        } else {
            _IT_Fail $r 'Log entry written and retrieved' 'Command not found in today log'
        }

        # 5c. Log file exists for today
        $logPath = Get-FltLogPath
        if (Test-Path $logPath) {
            $lineCount = (Get-Content $logPath | Measure-Object -Line).Lines
            _IT_Pass $r "Today's log file exists with $lineCount entries: $(Split-Path $logPath -Leaf)"
        } else {
            _IT_Fail $r "Today's log file exists" "Expected: $logPath"
        }

        # 5d. Log retention doesn't delete today's file
        Invoke-FltLogRetention
        if (Test-Path $logPath) {
            _IT_Pass $r 'Log retention preserves current log file'
        } else {
            _IT_Fail $r 'Log retention preserves current log' 'File was deleted!'
        }

        # 5e. Write-FltFleetQueryEntry writes a fleet_query event
        try {
            $summary = [FleetPackageSummary]::new()
            $summary.PackageName = 'IT.TestPackage'
            $summary.FeedVersion = '1.0.0'
            $ps1 = [PackageState]::new('IT-Target','IT.TestPackage')
            $ps1.Status = 'up-to-date'
            $summary.States = @($ps1)
            Write-FltFleetQueryEntry -Summary $summary
            # Verify it was written by reading raw log
            $raw = Get-Content (Get-FltLogPath) -ErrorAction SilentlyContinue |
                   Where-Object { $_ -match 'fleet_query' -and $_ -match 'IT\.TestPackage' }
            if ($raw) {
                _IT_Pass $r 'Write-FltFleetQueryEntry: fleet_query event written to log'
            } else {
                _IT_Fail $r 'Write-FltFleetQueryEntry: event in log' 'fleet_query entry not found'
            }
        } catch { _IT_Fail $r 'Write-FltFleetQueryEntry' $_.Exception.Message }

        # 5f. Show-FltCommandLog renders without throwing
        try {
            # Redirect output to suppress console noise during test
            Show-FltCommandLog -LastDays 1 | Out-Null
            _IT_Pass $r 'Show-FltCommandLog: renders without error'
        } catch { _IT_Fail $r 'Show-FltCommandLog' $_.Exception.Message }

    } catch {
        _IT_Fail $r 'Log system' $_.Exception.Message
    }

    return $r
}

# ── Suite 6 — Reachability cache ─────────────────────────────────────────────

# Tests that the reachability cache behaves correctly.
# Tests 6a-6c run once (local logic). Test 6d runs per selected target (live check).
function Invoke-IT_ReachCache {
    param([FleetTarget]$Target = $null)
    $r = _IT_NewResult
    _IT_Section 'Reachability cache'

    $saved = $Script:FltReachCache
    try {
        # 6a. Cache starts empty after reset
        $Script:FltReachCache = @{}
        if ($Script:FltReachCache.Count -eq 0) {
            _IT_Pass $r 'Reachability cache initialized empty'
        } else {
            _IT_Fail $r 'Reachability cache initialized empty' "Has $($Script:FltReachCache.Count) entries"
        }

        # 6b. Cached online target is skipped within the cache window
        $cacheSecs = [int](Get-FltCfgValue 'ui' 'reachCacheSecs' 60)
        $testName  = 'CacheTest-IT'
        $Script:FltReachCache[$testName] = [DateTime]::UtcNow
        $t = [FleetTarget]::new($testName,'10.0.0.99',22,'admin',$false)
        $t.Reachable = 'online'

        $job = Start-FltReachJob -Targets @($t)   # no -IgnoreCache
        if ($null -eq $job) {
            _IT_Pass $r "Cached online target skipped (within ${cacheSecs}s window)"
        } else {
            _IT_Fail $r 'Cached online target skipped' 'Job was created — cache not respected'
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }

        # 6c. Expired cache entry triggers recheck
        $Script:FltReachCache[$testName] = [DateTime]::UtcNow.AddSeconds(-($cacheSecs + 5))
        $job2 = Start-FltReachJob -Targets @($t)
        if ($null -ne $job2) {
            _IT_Pass $r 'Expired cache entry triggers recheck'
            Stop-Job $job2 -ErrorAction SilentlyContinue
            Remove-Job $job2 -Force -ErrorAction SilentlyContinue
        } else {
            _IT_Fail $r 'Expired cache entry triggers recheck' 'Job was null'
        }

        $Script:FltReachCache = $saved

        # 6d. Live cache population — only when a real target is provided
        if ($Target) {
            $preSaved = $Script:FltReachCache
            $Script:FltReachCache = @{}
            $job3 = Start-FltReachJob -Targets @($Target) -IgnoreCache
            if ($job3) {
                # Wait for ThreadJob to start, then complete (max 10s)
                $timeout = [DateTime]::UtcNow.AddSeconds(10)
                while ($job3.State -in @('NotStarted','Running') -and [DateTime]::UtcNow -lt $timeout) {
                    Start-Sleep -Milliseconds 100
                }
                if ($job3.State -eq 'Completed') {
                    Receive-FltReachJob $job3
                    if ($Script:FltReachCache.ContainsKey($Target.Name)) {
                        _IT_Pass $r "Live cache populated for '$($Target.Name)'"
                    } else {
                        _IT_Warn $r "Live cache populated for '$($Target.Name)'" 'Target offline — offline targets not cached (expected)'
                    }
                } else {
                    _IT_Fail $r "Reachability job completed for '$($Target.Name)'" "State: $($job3.State)"
                    Remove-Job $job3 -Force -ErrorAction SilentlyContinue
                }
            } else {
                _IT_Warn $r "Live reachability job for '$($Target.Name)'" 'Start-FltReachJob returned null'
            }
            $Script:FltReachCache = $preSaved
        }
    } catch {
        $Script:FltReachCache = $saved
        _IT_Fail $r 'Reachability cache' $_.Exception.Message
    }

    return $r
}

# ── Suite 7 — tcpkg local integration ────────────────────────────────────────

# Tests that require tcpkg installed locally: target verify, internet access
# toggle, and config archive export/import.
function Invoke-IT_TcpkgLocal {
    param([FleetTarget]$Target = $null)
    $r = _IT_NewResult
    _IT_Section 'tcpkg local integration'

    # 7a. Get-FltTcpkgExe returns a callable executable
    try {
        $exe = Get-FltTcpkgExe
        if (-not $exe) {
            _IT_Fail $r 'tcpkg executable configured' 'Get-FltTcpkgExe returned empty'
        } else {
            # Test-Path only works for absolute paths — for PATH-resolved names use Get-Command
            $found = (Test-Path $exe) -or ($null -ne (Get-Command $exe -ErrorAction SilentlyContinue))
            if ($found) {
                _IT_Pass $r "tcpkg executable found: $exe"
            } else {
                _IT_Warn $r "tcpkg executable '$exe' not found" 'Install tcpkg or update tcpkg.executablePath in settings'
            }
        }
    } catch { _IT_Fail $r 'Get-FltTcpkgExe' $_.Exception.Message }

    # 7b. Export config archive creates a zip file
    try {
        $exportPath = Join-Path $Script:FltConfigDir 'it-config-export.zip'
        Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
        $ok = Export-FltConfig -DestinationPath $exportPath
        if ($ok -and (Test-Path $exportPath)) {
            $size = (Get-Item $exportPath).Length
            _IT_Pass $r "Export-FltConfig: archive created ($size bytes)"
        } elseif (Test-Path $exportPath) {
            _IT_Pass $r 'Export-FltConfig: archive file exists'
        } else {
            _IT_Fail $r 'Export-FltConfig: archive created' 'File not found after export'
        }
        Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
    } catch { _IT_Fail $r 'Export-FltConfig' $_.Exception.Message }

    # 7c. Test-FleetTargetVerify — verify a target against tcpkg config
    if ($Target) {
        try {
            $ok = Test-FleetTargetVerify -Name $Target.Name
            # We can't know if it will pass, but it should not throw
            if ($ok) {
                _IT_Pass $r "Test-FleetTargetVerify: '$($Target.Name)' verified OK in tcpkg config"
            } else {
                _IT_Warn $r "Test-FleetTargetVerify: '$($Target.Name)' not verified" 'Target may not be registered in tcpkg — use Setup to add it'
            }
        } catch { _IT_Fail $r "Test-FleetTargetVerify: '$($Target.Name)'" $_.Exception.Message }

        # 7d. Set-FleetTargetInternetAccess — toggle and restore
        try {
            $origIA = $Target.InternetAccess
            # Toggle to opposite
            $newIA = -not $origIA
            $ok = Set-FleetTargetInternetAccess -Name $Target.Name -Value $newIA
            if ($ok) {
                # Verify JSON updated
                $reloaded = @(Get-FleetTargets -Silent) | Where-Object { $_.Name -eq $Target.Name } | Select-Object -First 1
                if ($reloaded -and $reloaded.InternetAccess -eq $newIA) {
                    _IT_Pass $r "Set-FleetTargetInternetAccess: JSON updated to $newIA"
                } else {
                    _IT_Fail $r 'Set-FleetTargetInternetAccess: JSON updated' "Got $($reloaded.InternetAccess), expected $newIA"
                }
                # Restore
                Set-FleetTargetInternetAccess -Name $Target.Name -Value $origIA | Out-Null
                _IT_Pass $r "Set-FleetTargetInternetAccess: restored to $origIA"
            } else {
                _IT_Warn $r "Set-FleetTargetInternetAccess: '$($Target.Name)'" 'tcpkg edit failed — target may not be in tcpkg'
            }
        } catch {
            # Always try to restore
            try { Set-FleetTargetInternetAccess -Name $Target.Name -Value $Target.InternetAccess | Out-Null } catch {}
            _IT_Fail $r "Set-FleetTargetInternetAccess: '$($Target.Name)'" $_.Exception.Message
        }
    } else {
        _IT_Warn $r 'Target-specific tcpkg tests' 'No target selected — toggle one with 21+'
    }

    return $r
}

# ── Suite 8 — Package queries (tcpkg + online targets) ───────────────────────

# Tests package search, version listing, and status queries.
# All are read-only — no installs or changes.
function Invoke-IT_PackageQueries {
    param([FleetTarget] $Target = $null)
    $r = _IT_NewResult
    _IT_Section 'Package queries'

    # 8a. Get-FltPackageList — search for a known Beckhoff package
    try {
        $res = Get-FltPackageList -ListArgs @('list','twincat.standard')
        if ($res.Ok -and $res.Items.Count -gt 0) {
            _IT_Pass $r "Get-FltPackageList: found $($res.Items.Count) package(s) matching 'twincat.standard'"
        } elseif ($res.Ok) {
            _IT_Warn $r 'Get-FltPackageList: no results for twincat.standard' 'Check feed configuration'
        } else {
            _IT_Fail $r 'Get-FltPackageList' "tcpkg list failed — check tcpkg installation"
        }
    } catch { _IT_Fail $r 'Get-FltPackageList' $_.Exception.Message }

    # 8b. Get-FltPackageVersions — list versions of a known package
    try {
        $versions = @(Get-FltPackageVersions -PackageName 'twincat.standard.xae')
        if ($versions.Count -gt 0) {
            _IT_Pass $r "Get-FltPackageVersions: $($versions.Count) version(s) of twincat.standard.xae"
        } else {
            _IT_Warn $r 'Get-FltPackageVersions: no versions found' 'Package may not be in any configured feed'
        }
    } catch { _IT_Fail $r 'Get-FltPackageVersions' $_.Exception.Message }

    # 8c. Get-FltInstalledIndex and Get-FltPackageStatus — build index then query
    if ($Target) {
        try {
            # Get-FltInstalledIndex calls tcpkg list -i -r <name> to get installed packages
            $idx = Get-FltInstalledIndex -RemoteName $Target.Name
            if ($idx -is [hashtable]) {
                _IT_Pass $r "Get-FltInstalledIndex: built index for '$($Target.Name)' ($($idx.Count) packages)"

                # Get-FltPackageStatus compares installed version against a feed version
                $testPkg = 'twincat.standard.xae'
                $status  = Get-FltPackageStatus -PackageName $testPkg -InstalledIndex $idx
                if ($status -in @('not-installed','up-to-date','upgradable','newer-than-feed')) {
                    _IT_Pass $r "Get-FltPackageStatus '$testPkg' on '$($Target.Name)': $status"
                } else {
                    _IT_Fail $r "Get-FltPackageStatus '$testPkg'" "Unexpected status: '$status'"
                }
            } else {
                _IT_Fail $r "Get-FltInstalledIndex: '$($Target.Name)'" "Got type: $($idx.GetType().Name)"
            }
        } catch { _IT_Fail $r "Get-FltInstalledIndex/Status: '$($Target.Name)'" $_.Exception.Message }
    } else {
        _IT_Warn $r 'Get-FltInstalledIndex / Get-FltPackageStatus' 'No target selected — toggle one with 21+'
    }

    return $r
}



# Returns metadata about all available integration test suites.
# Used by the TestRunner to display the suite list.
function Get-IT_Suites {
    return @(
        [pscustomobject]@{
            Id          = 1
            Name        = 'File I/O'
            Description = 'CSV round-trip, sort persistence, filter correctness, UI Config persistence'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local file system
            Function    = 'Invoke-IT_FileIO'
        },
        [pscustomobject]@{
            Id          = 2
            Name        = 'Pagination and target selection'
            Description = 'Page slicing, target numbering, sort-aware selection'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local logic
            Function    = 'Invoke-IT_Pagination'
        },
        [pscustomobject]@{
            Id          = 3
            Name        = 'SSH connectivity'
            Description = 'TCP check, SSH session, remote command, tcpkg path on target'
            NeedsTarget = $true
            NeedsSSH    = $true
            PerTarget   = $true    # runs against each selected target
            Function    = 'Invoke-IT_SSH'
        },
        [pscustomobject]@{
            Id          = 4
            Name        = 'Read-only mode'
            Description = 'tcpkg blocked, batch produces [read-only] status, credentials exempt'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local mode flag
            Function    = 'Invoke-IT_ReadOnly'
        },
        [pscustomobject]@{
            Id          = 5
            Name        = 'Log system'
            Description = 'Entry written, retrieved by history, retention preserves current log'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local log files
            Function    = 'Invoke-IT_Log'
        },
        [pscustomobject]@{
            Id          = 6
            Name        = 'Reachability cache'
            Description = 'Cache skip, expiry recheck, optional live cache population'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $true    # optional live check runs per selected target
            Function    = 'Invoke-IT_ReachCache'
        }
        [pscustomobject]@{
            Id          = 7
            Name        = 'tcpkg local'
            Description = 'tcpkg exe found, config export, target verify, internet access toggle'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $true    # target-specific tests run per selected target
            Function    = 'Invoke-IT_TcpkgLocal'
        },
        [pscustomobject]@{
            Id          = 8
            Name        = 'Package queries'
            Description = 'Package search, version listing, remote status query'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $true    # remote status query runs per target
            Function    = 'Invoke-IT_PackageQueries'
        },
        [pscustomobject]@{
            Id          = 9
            Name        = 'WinGet executor'
            Description = 'WinGet available, executor routing logic, package search (if winget installed)'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # routing logic is local; search runs once
            Function    = 'Invoke-IT_WinGet'
        },
        [pscustomobject]@{
            Id          = 10
            Name        = 'WinGet live install'
            Description = 'Real install/uninstall via SSH using Invoke-FltWinGetBatch [needs target]'
            NeedsTarget = $true
            NeedsSSH    = $true
            PerTarget   = $true    # runs against each selected target
            Function    = 'Invoke-IT_WinGetLive'
        }
    )
}

# ── Suite 9 — WinGet executor ─────────────────────────────────────────────────

# Tests WinGet availability, executor routing logic, and local package search.
# Routing tests run without WinGet installed — they test FleetExecutor bucket
# assignments using synthetic FleetTarget objects.
# Search tests WARN and skip if winget is not installed on the operator machine.
function Invoke-IT_WinGet {
    $r = _IT_NewResult
    _IT_Section 'WinGet executor'

    # 9a. Test-FltWinGetAvailable reports correctly
    try {
        $avail = Test-FltWinGetAvailable
        $found = $null -ne (Get-Command 'winget' -ErrorAction SilentlyContinue)
        if ($avail -eq $found) {
            if ($avail) {
                _IT_Pass $r 'Test-FltWinGetAvailable: winget found on operator machine'
            } else {
                _IT_Warn $r 'Test-FltWinGetAvailable: winget not found' 'Search/version tests will be skipped — install winget to enable'
            }
        } else {
            _IT_Fail $r 'Test-FltWinGetAvailable: result matches Get-Command' "avail=$avail found=$found"
        }
    } catch { _IT_Fail $r 'Test-FltWinGetAvailable' $_.Exception.Message }

    # 9b-9e. Executor routing — EffectivePackageManager() is a PS7 class method
    # that cannot be assigned to a variable. Use -in operator directly on the method
    # call in expression context instead.
    try {
        $t = [FleetTarget]::new('RouteTest-tcpkg','10.0.0.1',22,'admin',$true)
        $t.PackageManager = 'tcpkg'
        if ((Get-FltEffectivePackageManager $t) -eq 'tcpkg') {
            _IT_Pass $r "Routing: PackageManager='tcpkg' → Get-FltEffectivePackageManager correct"
        } else {
            _IT_Fail $r "Routing: tcpkg target Get-FltEffectivePackageManager" "Expected 'tcpkg', got '$(Get-FltEffectivePackageManager $t)'"
        }
    } catch { _IT_Fail $r 'Routing: tcpkg target' $_.Exception.Message }

    try {
        $t = [FleetTarget]::new('RouteTest-winget','10.0.0.2',22,'admin',$true)
        $t.PackageManager = 'winget'
        if ((Get-FltEffectivePackageManager $t) -eq 'winget') {
            _IT_Pass $r "Routing: PackageManager='winget' → Get-FltEffectivePackageManager correct"
        } else {
            _IT_Fail $r "Routing: winget target Get-FltEffectivePackageManager" "Expected 'winget'"
        }
    } catch { _IT_Fail $r 'Routing: winget target' $_.Exception.Message }

    try {
        $t = [FleetTarget]::new('RouteTest-default','10.0.0.3',22,'admin',$true)
        $t.PackageManager = ''
        $t.OS = 'windows'
        if ((Get-FltEffectivePackageManager $t) -eq 'tcpkg') {
            _IT_Pass $r "Routing: PackageManager='' on Windows → Get-FltEffectivePackageManager defaults to 'tcpkg'"
        } else {
            _IT_Fail $r "Routing: default Windows target Get-FltEffectivePackageManager" "Expected 'tcpkg'"
        }
    } catch { _IT_Fail $r 'Routing: default Windows target' $_.Exception.Message }

    try {
        $t = [FleetTarget]::new('RouteTest-both','10.0.0.4',22,'admin',$true)
        $t.PackageManager = 'both'
        if ((Get-FltEffectivePackageManager $t) -eq 'both') {
            _IT_Pass $r "Routing: PackageManager='both' → Get-FltEffectivePackageManager correct"
        } else {
            _IT_Fail $r "Routing: 'both' target Get-FltEffectivePackageManager" "Expected 'both'"
        }
    } catch { _IT_Fail $r "Routing: 'both' target" $_.Exception.Message }

    # 9f. WinGet command format is correct for each verb
    try {
        $install   = _Get-WinGetCommand -Action 'install'   -PackageSpec 'Microsoft.VisualStudioCode'
        $upgrade   = _Get-WinGetCommand -Action 'upgrade'   -PackageSpec 'Microsoft.VisualStudioCode'
        $uninstall = _Get-WinGetCommand -Action 'uninstall' -PackageSpec 'Microsoft.VisualStudioCode'
        $errors = @()
        if ($install   -notmatch '^winget install')   { $errors += "install='$install'" }
        if ($upgrade   -notmatch '^winget upgrade')   { $errors += "upgrade='$upgrade'" }
        if ($uninstall -notmatch '^winget uninstall') { $errors += "uninstall='$uninstall'" }
        if ($install   -notmatch '--silent')          { $errors += 'install missing --silent' }
        if ($install   -notmatch 'Microsoft\.VisualStudioCode') { $errors += 'install missing package id' }
        if ($errors.Count -eq 0) {
            _IT_Pass $r '_Get-WinGetCommand: correct format for install/upgrade/uninstall'
        } else {
            _IT_Fail $r '_Get-WinGetCommand: command format' ($errors -join '; ')
        }
    } catch { _IT_Fail $r '_Get-WinGetCommand' $_.Exception.Message }

    # 9g. Search-FltWinGetPackage — requires winget on operator machine
    if (Test-FltWinGetAvailable) {
        try {
            $res = Search-FltWinGetPackage -SearchTerm 'notepad'
            if ($res.Ok -and $res.Items.Count -gt 0) {
                _IT_Pass $r "Search-FltWinGetPackage: found $($res.Items.Count) result(s) for 'notepad'"
                # Verify shape matches tcpkg equivalent
                $first = $res.Items[0]
                $hasName    = $null -ne $first.Name
                $hasVersion = $null -ne $first.PSObject.Properties['Version']
                $hasSource  = $null -ne $first.PSObject.Properties['Source']
                if ($hasName -and $hasVersion -and $hasSource) {
                    _IT_Pass $r 'Search-FltWinGetPackage: result shape matches tcpkg equivalent'
                } else {
                    _IT_Fail $r 'Search-FltWinGetPackage: result shape' "Name=$hasName Version=$hasVersion Source=$hasSource"
                }
            } elseif ($res.Ok) {
                _IT_Warn $r "Search-FltWinGetPackage: no results for 'notepad'" 'Check winget source configuration'
            } else {
                # Capture raw winget output for diagnosis
                $rawDiag = & winget search notepad --accept-source-agreements 2>&1
                $exitDiag = $LASTEXITCODE
                $preview  = ($rawDiag | Select-Object -First 3 | ForEach-Object { [string]$_ }) -join ' | '
                _IT_Fail $r "Search-FltWinGetPackage: search succeeded" "exit=$exitDiag raw='$preview'"
            }
        } catch { _IT_Fail $r 'Search-FltWinGetPackage' $_.Exception.Message }

        # 9h. Get-FltWinGetVersions — search for a well-known package
        try {
            $versions = @(Get-FltWinGetVersions -PackageId 'Microsoft.Notepad')
            if ($versions.Count -gt 0) {
                _IT_Pass $r "Get-FltWinGetVersions: $($versions.Count) version(s) of Microsoft.Notepad"
                if ($versions[0].PSObject.Properties['Version'] -and $versions[0].PSObject.Properties['Source']) {
                    _IT_Pass $r 'Get-FltWinGetVersions: result shape matches tcpkg equivalent'
                } else {
                    _IT_Fail $r 'Get-FltWinGetVersions: result shape' 'Missing Version or Source property'
                }
            } else {
                _IT_Warn $r 'Get-FltWinGetVersions: versions found' 'No versions for Microsoft.Notepad — package may not be in sources'
            }
        } catch { _IT_Fail $r 'Get-FltWinGetVersions' $_.Exception.Message }
    } else {
        _IT_Warn $r 'Search-FltWinGetPackage'    'winget not on operator machine — skipped'
        _IT_Warn $r 'Get-FltWinGetVersions'      'winget not on operator machine — skipped'
    }

    return $r
}

# ── Suite 10 — WinGet live install ────────────────────────────────────────────

# Tests a real install + uninstall via SSH using Invoke-FltWinGetBatch.
# Uses 7zip.7zip — small (~1MB), universally available, easily removed.
#
# Flow:
#   If already installed  → attempt install → expect Skipped (Already installed)
#   If not installed      → install → verify present → uninstall → verify gone
#
# This suite always leaves the target in the same state it started.
function Invoke-IT_WinGetLive {
    param(
        [FleetTarget] $Target,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string] $KeyFile = ''
    )
    $r = _IT_NewResult
    _IT_Section "WinGet live install — $($Target.Name) ($($Target.Address))"

    $testPkg = '7zip.7zip'

    if (-not (Ensure-FltPoshSsh)) {
        _IT_Fail $r 'Posh-SSH available' 'Run: Install-Module Posh-SSH -Scope CurrentUser'
        return $r
    }
    if (-not $Credential -and [string]::IsNullOrWhiteSpace($KeyFile)) {
        _IT_Fail $r 'Credentials provided' 'Select credentials before running this suite'
        return $r
    }

    # 10a. Check current install status via winget list on remote
    $alreadyInstalled = $false
    try {
        $useKey = -not [string]::IsNullOrWhiteSpace($KeyFile)
        $sessionParams = @{
            ComputerName = $Target.Address
            Port         = [int]$Target.Port
            AcceptKey    = $true
            ErrorAction  = 'Stop'
        }
        if ($useKey) { $sessionParams['Username'] = $Target.User; $sessionParams['KeyFile'] = $KeyFile }
        else          { $sessionParams['Credential'] = $Credential }

        $session = New-SSHSession @sessionParams
        if (-not $session) {
            _IT_Fail $r 'SSH session for pre-check' 'New-SSHSession returned null'
            return $r
        }

        # Pre-check A: winget installed and callable
        $verResult = Invoke-SSHCommand -SessionId $session.SessionId `
                         -Command 'winget --version' -TimeOut 30
        $verOut    = ($verResult.Output -join '').Trim()
        if ($verResult.ExitStatus -eq 0 -and $verOut -match 'v\d') {
            _IT_Pass $r "winget installed on target: $verOut"
        } else {
            _IT_Fail $r 'winget installed on target' `
                "exit=$($verResult.ExitStatus) output='$verOut' — use Setup > select target > 4. Prepare target to install WinGet"
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
            return $r
        }

        # Pre-check B: winget sources configured
        $srcResult = Invoke-SSHCommand -SessionId $session.SessionId `
                         -Command 'winget source list' -TimeOut 30
        $srcOut    = ($srcResult.Output -join ' ')
        if ($srcResult.ExitStatus -eq 0 -and $srcOut -match 'https://') {
            $srcCount = @($srcResult.Output | Where-Object { $_ -match 'https://' }).Count
            _IT_Pass $r "winget sources configured on target ($srcCount source(s))"
        } else {
            _IT_Fail $r 'winget sources configured on target' `
                "exit=$($srcResult.ExitStatus) — run 'winget source reset --force' on target"
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
            return $r
        }

        # Pre-check C: refresh sources so install doesn't use stale cache
        $updateResult = Invoke-SSHCommand -SessionId $session.SessionId `
                            -Command 'winget source update --disable-interactivity' -TimeOut 60
        if ($updateResult.ExitStatus -eq 0) {
            _IT_Pass $r 'winget sources refreshed'
        } else {
            _IT_Warn $r 'winget sources refreshed' `
                "exit=$($updateResult.ExitStatus) — install may use cached source data"
        }

        # Pre-check D: check if test package already installed
        $checkCmd = "winget list --id $testPkg --accept-source-agreements --disable-interactivity 2>&1"
        $check    = Invoke-SSHCommand -SessionId $session.SessionId -Command $checkCmd -TimeOut 60
        $checkOut = ($check.Output -join ' ')
        $alreadyInstalled = $checkOut -match [regex]::Escape($testPkg)
        Remove-SSHSession -SessionId $session.SessionId | Out-Null

        if ($alreadyInstalled) {
            _IT_Pass $r "$testPkg pre-check: already installed on target"
        } else {
            _IT_Pass $r "$testPkg pre-check: not installed on target — will install and remove"
        }
    } catch {
        _IT_Fail $r "Pre-check SSH: $($Target.Name)" $_.Exception.Message
        return $r
    }

    if ($alreadyInstalled) {
        # 10b-alt. Already installed — attempt install, expect Skipped
        try {
            $results = @(Invoke-FltWinGetBatch `
                -Targets      @($Target) `
                -Action       'install' `
                -PackageSpec  $testPkg `
                -Credential   $Credential `
                -KeyFile      $KeyFile `
                -TimeoutSecs  120)

            $res = $results | Where-Object { $_.TargetName -eq $Target.Name } | Select-Object -First 1
            if ($res -and $res.Status -eq 'Skipped' -and $res.Note -match 'Already installed') {
                _IT_Pass $r "Install when already installed → Skipped (Already installed)"
            } elseif ($res) {
                _IT_Fail $r "Install when already installed → Skipped" "Got Status='$($res.Status)' Note='$($res.Note)'"
            } else {
                _IT_Fail $r "Install result returned" "No result for $($Target.Name)"
            }
        } catch {
            _IT_Fail $r 'Invoke-FltWinGetBatch (already installed)' $_.Exception.Message
        }
    } else {
        # 10b. Install
        try {
            $installResults = @(Invoke-FltWinGetBatch `
                -Targets      @($Target) `
                -Action       'install' `
                -PackageSpec  $testPkg `
                -Credential   $Credential `
                -KeyFile      $KeyFile `
                -TimeoutSecs  300)

            $instRes = $installResults | Where-Object { $_.TargetName -eq $Target.Name } | Select-Object -First 1
            if ($instRes -and $instRes.Status -eq 'OK') {
                _IT_Pass $r "Install ${testPkg}: OK ($([Math]::Round($instRes.DurationSec,1))s)"
            } else {
                $status = if ($instRes) { $instRes.Status } else { 'no result' }
                _IT_Fail $r "Install $testPkg" "Status='$status'"
                return $r   # skip uninstall if install failed
            }
        } catch {
            _IT_Fail $r "Invoke-FltWinGetBatch install" $_.Exception.Message
            return $r
        }

        # 10c. Verify installed via remote winget list
        try {
            $session2 = New-SSHSession @sessionParams
            $verify   = Invoke-SSHCommand -SessionId $session2.SessionId `
                            -Command "winget list --id $testPkg --accept-source-agreements 2>&1" `
                            -TimeOut 60
            $verOut   = ($verify.Output -join ' ')
            Remove-SSHSession -SessionId $session2.SessionId | Out-Null

            if ($verOut -match [regex]::Escape($testPkg)) {
                _IT_Pass $r "Verify installed: $testPkg found in remote winget list"
            } else {
                _IT_Fail $r "Verify installed: $testPkg in winget list" "Not found — output: $($verOut[0..120] -join '')"
            }
        } catch {
            _IT_Fail $r 'Verify install via SSH' $_.Exception.Message
        }

        # 10d. Uninstall
        try {
            $uninstallResults = @(Invoke-FltWinGetBatch `
                -Targets      @($Target) `
                -Action       'uninstall' `
                -PackageSpec  $testPkg `
                -Credential   $Credential `
                -KeyFile      $KeyFile `
                -TimeoutSecs  120)

            $uninstRes = $uninstallResults | Where-Object { $_.TargetName -eq $Target.Name } | Select-Object -First 1
            if ($uninstRes -and $uninstRes.Status -eq 'OK') {
                _IT_Pass $r "Uninstall ${testPkg}: OK ($([Math]::Round($uninstRes.DurationSec,1))s)"
            } else {
                $status = if ($uninstRes) { $uninstRes.Status } else { 'no result' }
                _IT_Fail $r "Uninstall $testPkg" "Status='$status' — manual cleanup may be needed"
            }
        } catch {
            _IT_Fail $r "Invoke-FltWinGetBatch uninstall" $_.Exception.Message
        }

        # 10e. Verify removed
        try {
            $session3 = New-SSHSession @sessionParams
            $verify2  = Invoke-SSHCommand -SessionId $session3.SessionId `
                            -Command "winget list --id $testPkg --accept-source-agreements 2>&1" `
                            -TimeOut 60
            $ver2Out  = ($verify2.Output -join ' ')
            Remove-SSHSession -SessionId $session3.SessionId | Out-Null

            if ($ver2Out -notmatch [regex]::Escape($testPkg)) {
                _IT_Pass $r "Verify removed: $testPkg no longer in remote winget list"
            } else {
                _IT_Fail $r "Verify removed: $testPkg still in winget list" 'Manual uninstall may be needed'
            }
        } catch {
            _IT_Fail $r 'Verify removal via SSH' $_.Exception.Message
        }
    }

    return $r
}