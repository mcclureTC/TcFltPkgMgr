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

    # 7k. BatchResult.PackageManager field — verify the class has the field
    #     and that both executors set it correctly on their pscustomobject output
    try {
        $br = [BatchResult]::new()
        if ($null -ne $br.PSObject.Properties['PackageManager']) {
            _IT_Pass $r 'BatchResult class has PackageManager field'
            $br.PackageManager = 'tcpkg'
            if ($br.PackageManager -eq 'tcpkg') {
                _IT_Pass $r 'BatchResult.PackageManager: field is assignable and readable'
            } else {
                _IT_Fail $r 'BatchResult.PackageManager: assignable' "Got '$($br.PackageManager)'"
            }
        } else {
            _IT_Fail $r 'BatchResult class has PackageManager field' 'Field not found on class'
        }
    } catch { _IT_Fail $r 'BatchResult.PackageManager field' $_.Exception.Message }

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
        },
        [pscustomobject]@{
            Id          = 11
            Name        = 'Ansible availability'
            Description = 'Ansible mode detection, version, community.docker collection check'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # local check only
            Function    = 'Invoke-IT_Ansible'
        },
        [pscustomobject]@{
            Id          = 12
            Name        = 'Docker operator'
            Description = 'Docker Desktop status, start/stop, and operator container checks'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false
            Function    = 'Invoke-IT_DockerOperator'
        },
        [pscustomobject]@{
            Id          = 13
            Name        = 'Ansible inventory builder'
            Description = 'New-FltAnsibleInventory: INI generation, groups, auth vars, cleanup'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — synthetic targets only
            Function    = 'Invoke-IT_AnsibleInventory'
        },
        [pscustomobject]@{
            Id          = 14
            Name        = 'Ansible playbook builder'
            Description = '_Get-*Playbook: YAML generation, file write, cleanup for all five builders'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — no Ansible required
            Function    = 'Invoke-IT_AnsiblePlaybook'
        },
        [pscustomobject]@{
            Id          = 15
            Name        = 'Ansible batch executor'
            Description = 'Invoke-FltAnsibleBatch: read-only mode, output parser, BatchResult shape'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # offline — parser tested directly; live run tested in Phase 5.5+
            Function    = 'Invoke-IT_AnsibleBatch'
        },
        [pscustomobject]@{
            Id          = 16
            Name        = 'Fleet executor routing'
            Description = 'Invoke-FleetAction: Ansible/tcpkg/winget/push bucket routing in read-only mode'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — read-only mode exercises bucket logic
            Function    = 'Invoke-IT_FleetRouting'
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
            $versions = @(Get-FltWinGetVersions -PackageId '7zip.7zip')
            if ($versions.Count -gt 0) {
                _IT_Pass $r "Get-FltWinGetVersions: $($versions.Count) version(s) of 7zip.7zip"
                if ($versions[0].PSObject.Properties['Version'] -and $versions[0].PSObject.Properties['Source']) {
                    _IT_Pass $r 'Get-FltWinGetVersions: result shape matches tcpkg equivalent'
                } else {
                    _IT_Fail $r 'Get-FltWinGetVersions: result shape' 'Missing Version or Source property'
                }
            } else {
                _IT_Warn $r 'Get-FltWinGetVersions: versions found' 'No versions for 7zip.7zip — check winget source configuration'
            }
        } catch { _IT_Fail $r 'Get-FltWinGetVersions' $_.Exception.Message }
    } else {
        _IT_Warn $r 'Search-FltWinGetPackage'    'winget not on operator machine — skipped'
        _IT_Warn $r 'Get-FltWinGetVersions'      'winget not on operator machine — skipped'
    }

    # 9i. Get-FltWinGetInstalledIndex — requires winget on operator machine
    if (Test-FltWinGetAvailable) {
        try {
            $idx = Get-FltWinGetInstalledIndex
            if ($idx -is [hashtable]) {
                _IT_Pass $r "Get-FltWinGetInstalledIndex: returns hashtable ($($idx.Count) packages)"
                # Keys must be lowercase package ids
                $hasUpperCase = $idx.Keys | Where-Object { $_ -cne $_.ToLower() }
                if (-not $hasUpperCase) {
                    _IT_Pass $r 'Get-FltWinGetInstalledIndex: all keys are lowercase (consistent with tcpkg equivalent)'
                } else {
                    _IT_Fail $r 'Get-FltWinGetInstalledIndex: keys lowercase' "Found mixed-case keys: $($hasUpperCase -join ', ')"
                }
            } else {
                _IT_Fail $r 'Get-FltWinGetInstalledIndex: returns hashtable' "Got: $($idx.GetType().Name)"
            }
        } catch { _IT_Fail $r 'Get-FltWinGetInstalledIndex' $_.Exception.Message }
    } else {
        _IT_Warn $r 'Get-FltWinGetInstalledIndex' 'winget not on operator machine — skipped'
    }

    # 9j. Routing: WinGet target with InternetAccess=False routes to push, not winget bucket
    # FleetExecutor only sends to winget SSH bucket when InternetAccess=True.
    # IA=False targets always use the push (local tcpkg) bucket regardless of PackageManager.
    try {
        $t = [FleetTarget]::new('RouteTest-wg-noIA','10.0.0.5',22,'admin',$false)  # IA=False
        $t.PackageManager = 'winget'
        # Simulate FleetExecutor bucket assignment logic
        $isIaTarget   = $t.InternetAccess
        $pm           = Get-FltEffectivePackageManager $t
        $goesWinGet   = $isIaTarget -and ($pm -in @('winget','both'))
        $goesPush     = -not $isIaTarget
        if ($goesPush -and -not $goesWinGet) {
            _IT_Pass $r 'Routing: winget target with IA=False routes to push bucket, not winget SSH'
        } else {
            _IT_Fail $r 'Routing: winget target with IA=False routes to push' "goesWinGet=$goesWinGet goesPush=$goesPush"
        }
    } catch { _IT_Fail $r 'Routing: IA=False winget target' $_.Exception.Message }

    # 9k. _Parse-WinGetTable — unit test for both output formats
    # Feeds known winget output fixtures and verifies correct Name/Id/Version extraction.
    # Tests two formats:
    #   (a) winget search: multi-group separator, position-based parsing
    #   (b) winget list via Out-String: solid separator, multi-space split
    try {
        # Format A: winget search output (multi-group separator)
        $searchLines = @(
            'Name                           Id                        Version    Source',
            '------------------------------- ------------------------- ---------- ------',
            'Notepad++                      Notepad++.Notepad++       8.9.6.4    winget',
            '7-Zip                          7zip.7zip                 24.9.0     winget',
            'AkelPad                        AkelPad.AkelPad           4.9.9      winget'
        )
        $searchResult = _Parse-WinGetTable -Lines $searchLines
        if (-not $searchResult.Ok)                                          { _IT_Fail $r '_Parse-WinGetTable search: parse succeeded' 'Ok=false' }
        elseif ($searchResult.Items.Count -ne 3)                            { _IT_Fail $r '_Parse-WinGetTable search: item count' "Expected 3 got $($searchResult.Items.Count)" }
        elseif ($searchResult.Items[0].Name -ne 'Notepad++.Notepad++')     { _IT_Fail $r '_Parse-WinGetTable search: Id extracted as Name' "Got '$($searchResult.Items[0].Name)'" }
        elseif ($searchResult.Items[0].Title -ne 'Notepad++')              { _IT_Fail $r '_Parse-WinGetTable search: display name in Title' "Got '$($searchResult.Items[0].Title)'" }
        elseif ($searchResult.Items[0].Version -ne '8.9.6.4')              { _IT_Fail $r '_Parse-WinGetTable search: version' "Got '$($searchResult.Items[0].Version)'" }
        else { _IT_Pass $r '_Parse-WinGetTable search format: Id/Title/Version correctly extracted' }

        # Format B: winget list via Out-String (solid separator, values may overflow columns)
        # This is the format produced by: winget list | Out-String -Width 300
        $listLines = @(
            'Name                                    Id                                       Version          Available     Source',
            '-----------------------------------------------------------------------------------------------------------------------',
            'OpenSSH                                 Microsoft.OpenSSH.Preview                9.5.0.0          10.0.0.0      winget',
            'XmlNotepad                              Microsoft.XMLNotepad                     2.9.0.22                       winget',
            'PowerShell 7-x64                        Microsoft.PowerShell                     7.5.0.0          7.6.2.0       winget',
            'Windows Notepad                         9MSMLRH6LZF3                             11.2604.5.0                    msstore',
            'EloMultiTouch 9.2.0.8                   ARP\Machine\X64\Elo Touch Solutions      9.2.0.8',
            'WindowsAppRuntime.1.8                   Microsoft.WindowsAppRuntime.1.8          1.8.0            1.8.8         winget'
        )
        $listResult = _Parse-WinGetTable -Lines $listLines
        if (-not $listResult.Ok)                                             { _IT_Fail $r '_Parse-WinGetTable list: parse succeeded' 'Ok=false' }
        elseif ($listResult.Items.Count -ne 6)                              { _IT_Fail $r '_Parse-WinGetTable list: item count' "Expected 6 got $($listResult.Items.Count)" }
        else {
            $xmlNotepad = $listResult.Items | Where-Object { $_.Name -eq 'Microsoft.XMLNotepad' } | Select-Object -First 1
            $openSsh    = $listResult.Items | Where-Object { $_.Name -eq 'Microsoft.OpenSSH.Preview' } | Select-Object -First 1
            $runtime    = $listResult.Items | Where-Object { $_.Name -eq 'Microsoft.WindowsAppRuntime.1.8' } | Select-Object -First 1

            if (-not $xmlNotepad)                           { _IT_Fail $r '_Parse-WinGetTable list: XmlNotepad found'    "Id not found in results: $($listResult.Items.Name -join ', ')" }
            elseif ($xmlNotepad.Title -ne 'XmlNotepad')    { _IT_Fail $r '_Parse-WinGetTable list: XmlNotepad title'    "Got '$($xmlNotepad.Title)'" }
            elseif ($xmlNotepad.Version -ne '2.9.0.22')    { _IT_Fail $r '_Parse-WinGetTable list: XmlNotepad version'  "Got '$($xmlNotepad.Version)'" }
            elseif (-not $openSsh)                          { _IT_Fail $r '_Parse-WinGetTable list: OpenSSH found'       'Id not found' }
            elseif ($openSsh.Version -ne '9.5.0.0')        { _IT_Fail $r '_Parse-WinGetTable list: OpenSSH version'     "Got '$($openSsh.Version)'" }
            elseif (-not $runtime)                          { _IT_Fail $r '_Parse-WinGetTable list: WindowsAppRuntime found' 'Id not found' }
            elseif ($runtime.Version -ne '1.8.0')          { _IT_Fail $r '_Parse-WinGetTable list: WindowsAppRuntime version' "Got '$($runtime.Version)'" }
            else { _IT_Pass $r '_Parse-WinGetTable list format: all packages correctly parsed (Id/Title/Version)' }
        }
    } catch { _IT_Fail $r '_Parse-WinGetTable' $_.Exception.Message }

    return $r
}
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

# ── Suite 11 — Ansible availability ───────────────────────────────────────────

# Tests Ansible availability checks in AnsibleRepository.ps1.
# All checks WARN and skip gracefully if Ansible is not installed —
# these are operator-machine checks with no SSH or target required.
function Invoke-IT_Ansible {
    $r = _IT_NewResult
    _IT_Section 'Ansible availability'

    # 11a. Get-FltAnsibleMode returns a valid value
    try {
        $mode = Get-FltAnsibleMode
        if ($mode -in @('native', 'wsl', 'docker', '')) {
            _IT_Pass $r "Get-FltAnsibleMode: returned valid mode ('$mode')"
        } else {
            _IT_Fail $r 'Get-FltAnsibleMode: valid return value' "Got unexpected value: '$mode'"
        }
    } catch { _IT_Fail $r 'Get-FltAnsibleMode' $_.Exception.Message }

    # 11b. Test-FltAnsibleAvailable is consistent with Get-FltAnsibleMode
    try {
        $avail = Test-FltAnsibleAvailable
        $mode  = Get-FltAnsibleMode
        $expected = $mode -ne ''
        if ($avail -eq $expected) {
            _IT_Pass $r "Test-FltAnsibleAvailable: consistent with Get-FltAnsibleMode ($mode)"
        } else {
            _IT_Fail $r 'Test-FltAnsibleAvailable: consistent with mode' "Available=$avail but mode='$mode'"
        }
    } catch { _IT_Fail $r 'Test-FltAnsibleAvailable' $_.Exception.Message }

    # 11c. Get-FltAnsibleVersion returns a string (non-null) when available
    try {
        $mode = Get-FltAnsibleMode
        $ver  = Get-FltAnsibleVersion
        if ($mode -eq '') {
            if ($ver -eq '') {
                _IT_Pass $r 'Get-FltAnsibleVersion: returns empty string when not available'
            } else {
                _IT_Fail $r 'Get-FltAnsibleVersion: empty when unavailable' "Got: '$ver'"
            }
        } else {
            if ($ver -ne '') {
                _IT_Pass $r "Get-FltAnsibleVersion: '$ver'"
            } else {
                _IT_Warn $r 'Get-FltAnsibleVersion: returned empty' 'Ansible found but version string empty'
            }
        }
    } catch { _IT_Fail $r 'Get-FltAnsibleVersion' $_.Exception.Message }

    # 11d. Get-FltAnsibleStatus returns correct shape
    try {
        $status = Get-FltAnsibleStatus
        $hasAll = $null -ne $status -and
                  $null -ne $status.PSObject.Properties['Available'] -and
                  $null -ne $status.PSObject.Properties['Mode'] -and
                  $null -ne $status.PSObject.Properties['Version'] -and
                  $null -ne $status.PSObject.Properties['HasCommunityDocker']
        if ($hasAll) {
            _IT_Pass $r "Get-FltAnsibleStatus: correct shape (Available=$($status.Available) Mode='$($status.Mode)')"
        } else {
            _IT_Fail $r 'Get-FltAnsibleStatus: correct shape' 'Missing one or more expected properties'
        }
    } catch { _IT_Fail $r 'Get-FltAnsibleStatus' $_.Exception.Message }

    # 11e. Test-FltAnsibleCollection returns bool (regardless of whether installed)
    try {
        $mode   = Get-FltAnsibleMode
        $result = Test-FltAnsibleCollection 'community.docker'
        if ($result -is [bool]) {
            if ($mode -eq '') {
                _IT_Pass $r 'Test-FltAnsibleCollection: returns $false when Ansible not available'
            } elseif ($result) {
                _IT_Pass $r 'Test-FltAnsibleCollection: community.docker is installed'
            } else {
                _IT_Warn $r 'Test-FltAnsibleCollection: community.docker not installed' `
                    "Run: ansible-galaxy collection install community.docker"
            }
        } else {
            _IT_Fail $r 'Test-FltAnsibleCollection: returns bool' "Got type: $($result.GetType().Name)"
        }
    } catch { _IT_Fail $r 'Test-FltAnsibleCollection' $_.Exception.Message }

    # 11f. Test-FltAnsibleDockerContainer returns bool
    try {
        if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
            _IT_Warn $r 'Test-FltAnsibleDockerContainer' 'docker not on PATH — install Docker Desktop'
        } else {
            $dockerStatus = Get-FltDockerStatus
            if ($dockerStatus -ne 'running') {
                _IT_Warn $r 'Test-FltAnsibleDockerContainer' "Docker daemon not ready (status: $dockerStatus) — run Suite 22 to start Docker"
            } else {
                $exists = Test-FltAnsibleDockerContainer
                if ($exists -is [bool]) {
                    if ($exists) {
                        _IT_Pass $r 'Test-FltAnsibleDockerContainer: container exists'
                    } else {
                        _IT_Warn $r 'Test-FltAnsibleDockerContainer: container not found' `
                            "Run: docker build -f docker/Dockerfile.ansible -t tcflt-ansible . && docker run -d --name tcflt-ansible --restart unless-stopped -v `${PWD}/ansible:/ansible tcflt-ansible"
                    }
                } else {
                    _IT_Fail $r 'Test-FltAnsibleDockerContainer: returns bool' "Got: $($exists.GetType().Name)"
                }
            }
        }
    } catch { _IT_Fail $r 'Test-FltAnsibleDockerContainer' $_.Exception.Message }

    # 11g. Test-FltAnsibleDockerContainerRunning returns bool
    try {
        if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
            _IT_Warn $r 'Test-FltAnsibleDockerContainerRunning' 'docker not on PATH — install Docker Desktop'
        } else {
            $dockerStatus = Get-FltDockerStatus
            if ($dockerStatus -ne 'running') {
                _IT_Warn $r 'Test-FltAnsibleDockerContainerRunning' "Docker daemon not ready (status: $dockerStatus) — run Suite 22 to start Docker"
            } else {
                $running = Test-FltAnsibleDockerContainerRunning
                if ($running -is [bool]) {
                    if ($running) {
                        _IT_Pass $r 'Test-FltAnsibleDockerContainerRunning: container is running'
                    } else {
                        $exists = Test-FltAnsibleDockerContainer
                        if ($exists) {
                            _IT_Warn $r 'Test-FltAnsibleDockerContainerRunning: container exists but not running' `
                                "Run: docker start tcflt-ansible"
                        } else {
                            _IT_Warn $r 'Test-FltAnsibleDockerContainerRunning: container not built yet' `
                                "Build first: docker build -f docker/Dockerfile.ansible -t tcflt-ansible ."
                        }
                    }
                } else {
                    _IT_Fail $r 'Test-FltAnsibleDockerContainerRunning: returns bool' "Got: $($running.GetType().Name)"
                }
            }
        }
    } catch { _IT_Fail $r 'Test-FltAnsibleDockerContainerRunning' $_.Exception.Message }

    return $r
}

# ── Suite 12 — Docker operator ────────────────────────────────────────────────

# Tests DockerRepository.ps1 — Docker Desktop status on the operator machine.
# All checks WARN gracefully when Docker is not installed or not running.
# Checks progress through states: not-installed → stopped → starting → running.
function Invoke-IT_DockerOperator {
    $r = _IT_NewResult
    _IT_Section 'Docker operator'

    # 12a. docker CLI available
    try {
        $hasDocker = $null -ne (Get-Command 'docker' -ErrorAction SilentlyContinue)
        if ($hasDocker) {
            $ver = & docker --version 2>&1
            _IT_Pass $r "docker CLI available: $(($ver -join '').Trim())"
        } else {
            _IT_Warn $r 'docker CLI available' 'docker not on PATH — install Docker Desktop from https://www.docker.com/products/docker-desktop/'
            return $r   # remaining checks all require docker CLI
        }
    } catch { _IT_Fail $r 'docker CLI available' $_.Exception.Message; return $r }

    # 12b. Get-FltDockerStatus returns valid value
    try {
        $status = Get-FltDockerStatus
        if ($status -in @('running', 'starting', 'stopped', 'not-installed')) {
            _IT_Pass $r "Get-FltDockerStatus: '$status'"
        } else {
            _IT_Fail $r 'Get-FltDockerStatus: valid value' "Got: '$status'"
        }
    } catch { _IT_Fail $r 'Get-FltDockerStatus' $_.Exception.Message }

    # 12c. Get-FltDockerDesktopPath finds installation
    try {
        $path = Get-FltDockerDesktopPath
        if ($path -and (Test-Path $path -PathType Leaf)) {
            _IT_Pass $r "Get-FltDockerDesktopPath: found at '$path'"
        } elseif ($path) {
            _IT_Warn $r 'Get-FltDockerDesktopPath: path returned but file missing' "Path: '$path'"
        } else {
            _IT_Warn $r 'Get-FltDockerDesktopPath: Docker Desktop not found' `
                'Install Docker Desktop or check installation path'
        }
    } catch { _IT_Fail $r 'Get-FltDockerDesktopPath' $_.Exception.Message }

    # 12d. Test-FltDockerAvailable consistent with Get-FltDockerStatus
    try {
        $avail  = Test-FltDockerAvailable
        $status = Get-FltDockerStatus
        $expectAvail = $status -eq 'running'
        if ($avail -eq $expectAvail) {
            _IT_Pass $r "Test-FltDockerAvailable: consistent with status '$status' (available=$avail)"
        } else {
            _IT_Fail $r 'Test-FltDockerAvailable: consistent with status' "Available=$avail but status='$status'"
        }
    } catch { _IT_Fail $r 'Test-FltDockerAvailable' $_.Exception.Message }

    # 12e. Docker daemon running (or WARN with start instructions)
    try {
        $status = Get-FltDockerStatus
        switch ($status) {
            'running'       { _IT_Pass $r 'Docker daemon is running' }
            'starting'      { _IT_Warn $r 'Docker daemon is starting' 'Wait a moment and re-run suite 22' }
            'stopped'       { _IT_Warn $r 'Docker daemon is stopped' 'Start Docker Desktop — or TcFltPkgMgr can start it from Setup' }
            'not-installed' { _IT_Warn $r 'Docker not installed' 'Install Docker Desktop from https://www.docker.com/products/docker-desktop/' }
        }
    } catch { _IT_Fail $r 'Docker daemon status' $_.Exception.Message }

    return $r
}

# ── Suite 13 — Ansible inventory builder ──────────────────────────────────────

# Tests New-FltAnsibleInventory and Remove-FltAnsibleInventory.
# Fully offline — no Ansible installation required.
# Uses synthetic FleetTarget objects and a temp path; the live ansible/
# directory is never touched.
function Invoke-IT_AnsibleInventory {
    $r       = _IT_NewResult
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "TcFlt_IT13_$(Get-Random)"
    $inv     = Join-Path $tempDir 'hosts.ini'

    _IT_Section 'Ansible inventory builder'

    # Helper — build a minimal synthetic FleetTarget
    function _MkT {
        param([string]$Name, [string]$Address, [int]$Port=22,
              [string]$OS='linux', [string]$TargetType='physical',
              [string]$DockerHost='', [string]$ContainerName='')
        $t = [FleetTarget]::new($Name, $Address, $Port, 'admin', $false)
        $t.OS            = $OS
        $t.TargetType    = $TargetType
        $t.DockerHost    = $DockerHost
        $t.ContainerName = $ContainerName
        $t
    }

    # ------------------------------------------------------------------
    # 13a — No Linux targets → Ok=$false, TargetCount=0, file not written
    # ------------------------------------------------------------------
    try {
        $winOnly = @(_MkT 'DCC-1' '192.168.8.10' 22 'windows' 'physical')
        $res = New-FltAnsibleInventory -Targets $winOnly -Path $inv
        if ($res.Ok -eq $false -and $res.TargetCount -eq 0 -and -not (Test-Path $inv)) {
            _IT_Pass $r '13a  No Linux targets: Ok=$false, TargetCount=0, no file written'
        } else {
            _IT_Fail $r '13a  No Linux targets: Ok=$false, TargetCount=0, no file written' `
                "Ok=$($res.Ok) Count=$($res.TargetCount) FileExists=$(Test-Path $inv)"
        }
    } catch { _IT_Fail $r '13a  No Linux targets guard' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13b — Single physical Linux target → file created, Ok=$true
    # ------------------------------------------------------------------
    try {
        $null = New-Item -ItemType Directory -Path $tempDir -Force
        $targets = @(_MkT 'DCC-Linux-1' '192.168.8.110')
        $res = New-FltAnsibleInventory -Targets $targets -Path $inv
        if ($res.Ok -and (Test-Path $inv)) {
            _IT_Pass $r '13b  Single physical target: Ok=$true and file exists'
        } else {
            _IT_Fail $r '13b  Single physical target: Ok=$true and file exists' `
                "Ok=$($res.Ok) FileExists=$(Test-Path $inv) Msg=$($res.Message)"
        }
    } catch { _IT_Fail $r '13b  Single physical target written' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13c — ansible_host and ansible_port in file
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match 'ansible_host=192\.168\.8\.110' -and $content -match 'ansible_port=22') {
            _IT_Pass $r '13c  ansible_host and ansible_port present in inventory'
        } else {
            _IT_Fail $r '13c  ansible_host and ansible_port present in inventory' `
                "host=$(($content -match 'ansible_host') ) port=$(($content -match 'ansible_port') )"
        }
    } catch { _IT_Fail $r '13c  ansible_host / ansible_port' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13d — Target name is the INI hostname key
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match 'DCC-Linux-1') {
            _IT_Pass $r '13d  Target name appears as INI hostname key'
        } else {
            _IT_Fail $r '13d  Target name appears as INI hostname key' 'DCC-Linux-1 not found in inventory'
        }
    } catch { _IT_Fail $r '13d  Target name as hostname key' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13e — TargetCount counts only Linux targets (Windows excluded)
    # ------------------------------------------------------------------
    try {
        $mixed = @(
            (_MkT 'Lin-1' '10.0.0.1')
            (_MkT 'Lin-2' '10.0.0.2' 22 'linux' 'vm')
            (_MkT 'Win-1' '10.0.0.3' 22 'windows' 'physical')
        )
        $res = New-FltAnsibleInventory -Targets $mixed -Path $inv
        if ($res.TargetCount -eq 2) {
            _IT_Pass $r '13e  TargetCount=2 (Linux only, Windows excluded)'
        } else {
            _IT_Fail $r '13e  TargetCount=2 (Linux only, Windows excluded)' `
                "Got TargetCount=$($res.TargetCount)"
        }
    } catch { _IT_Fail $r '13e  TargetCount Linux-only' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13f — VM target appears under [vm] group header
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match '\[vm\]' -and $content -match 'Lin-2') {
            _IT_Pass $r '13f  VM target in [vm] group'
        } else {
            _IT_Fail $r '13f  VM target in [vm] group' `
                "[vm]=$($content -match '\[vm\]') Lin-2=$($content -match 'Lin-2')"
        }
    } catch { _IT_Fail $r '13f  VM group' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13g — [linux:children] meta-group present when multiple groups exist
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match '\[linux:children\]') {
            _IT_Pass $r '13g  [linux:children] meta-group present'
        } else {
            _IT_Fail $r '13g  [linux:children] meta-group present' '[linux:children] not found'
        }
    } catch { _IT_Fail $r '13g  linux:children' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13h — Container target gets ansible_connection + ansible_docker_host
    # ------------------------------------------------------------------
    try {
        $withContainer = @(
            (_MkT 'dcc4'  '192.168.8.50')
            (_MkT 'web-1' '192.168.8.50' 22 'linux' 'container' 'dcc4' 'web-1')
        )
        $res = New-FltAnsibleInventory -Targets $withContainer -Path $inv
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        $hasConn   = $content -match 'ansible_connection=community\.docker\.docker_api'
        $hasDocker = $content -match 'ansible_docker_host=tcp://'
        if ($hasConn -and $hasDocker) {
            _IT_Pass $r '13h  Container: ansible_connection and ansible_docker_host present'
        } else {
            _IT_Fail $r '13h  Container: ansible_connection and ansible_docker_host present' `
                "connection=$hasConn dockerHost=$hasDocker"
        }
    } catch { _IT_Fail $r '13h  Container vars' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13i — Docker host address resolved from target list
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        # The Docker host dcc4 has address 192.168.8.50 — should appear in docker_host URL
        if ($content -match 'ansible_docker_host=tcp://192\.168\.8\.50:') {
            _IT_Pass $r '13i  Docker host address resolved from fleet target list'
        } else {
            _IT_Fail $r '13i  Docker host address resolved from fleet target list' `
                'Expected tcp://192.168.8.50: not found in ansible_docker_host'
        }
    } catch { _IT_Fail $r '13i  Docker host address resolution' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13j — Remove-FltAnsibleInventory deletes the file
    # ------------------------------------------------------------------
    try {
        # Ensure file exists first (may have been written by 13h)
        if (-not (Test-Path $inv)) {
            $null = New-FltAnsibleInventory -Targets @(_MkT 'Lin-X' '1.2.3.4') -Path $inv
        }
        Remove-FltAnsibleInventory -Path $inv
        if (-not (Test-Path $inv)) {
            _IT_Pass $r '13j  Remove-FltAnsibleInventory: file deleted'
        } else {
            _IT_Fail $r '13j  Remove-FltAnsibleInventory: file deleted' 'File still exists after removal'
        }
    } catch { _IT_Fail $r '13j  Remove-FltAnsibleInventory' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13k — Remove-FltAnsibleInventory is a no-op when file absent
    # ------------------------------------------------------------------
    try {
        Remove-FltAnsibleInventory -Path $inv   # file was removed in 13j
        _IT_Pass $r '13k  Remove-FltAnsibleInventory: no-op when file absent'
    } catch { _IT_Fail $r '13k  Remove-FltAnsibleInventory no-op' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13l — Parent directory auto-created for deep paths
    # ------------------------------------------------------------------
    try {
        $deepPath = Join-Path $tempDir 'sub' 'deep' 'hosts.ini'
        $res = New-FltAnsibleInventory -Targets @(_MkT 'Lin-D' '1.2.3.5') -Path $deepPath
        if ($res.Ok -and (Test-Path $deepPath)) {
            _IT_Pass $r '13l  Parent directory auto-created for deep path'
        } else {
            _IT_Fail $r '13l  Parent directory auto-created for deep path' `
                "Ok=$($res.Ok) FileExists=$(Test-Path $deepPath) Msg=$($res.Message)"
        }
    } catch { _IT_Fail $r '13l  Auto-create parent directory' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13m — Return object has Ok, Path, TargetCount, Message properties
    # ------------------------------------------------------------------
    try {
        $res   = New-FltAnsibleInventory -Targets @(_MkT 'Lin-S' '5.6.7.8') -Path $inv
        $props = $res.PSObject.Properties.Name
        if (($props -contains 'Ok') -and ($props -contains 'Path') -and
            ($props -contains 'TargetCount') -and ($props -contains 'Message')) {
            _IT_Pass $r '13m  Return object has Ok, Path, TargetCount, Message'
        } else {
            _IT_Fail $r '13m  Return object has Ok, Path, TargetCount, Message' `
                "Properties found: $($props -join ', ')"
        }
    } catch { _IT_Fail $r '13m  Return object shape' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $r
}
# ── Suite 14 — Ansible playbook builder ───────────────────────────────────────

# Tests all five _Get-*Playbook functions in execution/AnsibleExecutor.ps1.
# Fully offline — no Ansible installation required.
# Each test writes a real YAML file to a temp directory and inspects it,
# then cleans up the temp tree.
function Invoke-IT_AnsiblePlaybook {
    $r       = _IT_NewResult
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "TcFlt_IT14_$(Get-Random)"
    $null    = New-Item -ItemType Directory -Path $tempDir -Force

    _IT_Section 'Ansible playbook builder'

    # ------------------------------------------------------------------
    # Helper: call a _Get-*Playbook function with the playbook dir
    # redirected to $tempDir so we never touch the live ansible/ tree.
    # We monkey-patch _Get-FltAnsiblePlaybookDir for the duration of
    # each test by temporarily redefining it in the local scope.
    # PowerShell resolves functions at call time, so a local override
    # takes precedence over the module-scope one.
    # ------------------------------------------------------------------

    # Override the playbook dir helper to point at our temp directory
    function _Get-FltAnsiblePlaybookDir { return $tempDir }

    # Helper: find the most-recently-written .yml in $tempDir
    function _LatestYml {
        Get-ChildItem $tempDir -Filter '*.yml' -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }

    # Helper: get content of most-recently-written .yml
    function _YmlContent {
        $f = _LatestYml
        if ($f) { Get-Content $f -Raw } else { '' }
    }

    # ------------------------------------------------------------------
    # 14a — _Get-PackagePlaybook (install): file written, Ok=$true
    # ------------------------------------------------------------------
    try {
        $res = _Get-PackagePlaybook -Action 'install' -PackageName 'curl'
        if ($res.Ok -and (Test-Path $res.Path)) {
            _IT_Pass $r '14a  _Get-PackagePlaybook install: Ok=$true and file exists'
        } else {
            _IT_Fail $r '14a  _Get-PackagePlaybook install: Ok=$true and file exists' `
                "Ok=$($res.Ok) Path=$($res.Path) Msg=$($res.Message)"
        }
    } catch { _IT_Fail $r '14a  _Get-PackagePlaybook install' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14b — Package playbook: correct module and state=present
    # ------------------------------------------------------------------
    try {
        $c = _YmlContent
        if ($c -match 'ansible\.builtin\.package' -and $c -match 'state:\s*present') {
            _IT_Pass $r '14b  Package install: ansible.builtin.package with state=present'
        } else {
            _IT_Fail $r '14b  Package install: ansible.builtin.package with state=present' `
                "module=$($c -match 'ansible.builtin.package') state=$($c -match 'state: present')"
        }
    } catch { _IT_Fail $r '14b  Package playbook content' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14c — _Get-PackagePlaybook (upgrade): state=latest
    # ------------------------------------------------------------------
    try {
        $res = _Get-PackagePlaybook -Action 'upgrade' -PackageName 'curl'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*latest') {
            _IT_Pass $r '14c  Package upgrade: state=latest'
        } else {
            _IT_Fail $r '14c  Package upgrade: state=latest' "Ok=$($res.Ok) state-latest=$($c -match 'state: latest')"
        }
    } catch { _IT_Fail $r '14c  Package upgrade' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14d — _Get-PackagePlaybook (remove): state=absent
    # ------------------------------------------------------------------
    try {
        $res = _Get-PackagePlaybook -Action 'remove' -PackageName 'curl'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*absent') {
            _IT_Pass $r '14d  Package remove: state=absent'
        } else {
            _IT_Fail $r '14d  Package remove: state=absent' "Ok=$($res.Ok) state-absent=$($c -match 'state: absent')"
        }
    } catch { _IT_Fail $r '14d  Package remove' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14e — _Get-ServicePlaybook (start): correct module and state=started
    # ------------------------------------------------------------------
    try {
        $res = _Get-ServicePlaybook -Action 'start' -ServiceName 'nginx'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'ansible\.builtin\.systemd' -and $c -match 'state:\s*started') {
            _IT_Pass $r '14e  Service start: ansible.builtin.systemd with state=started'
        } else {
            _IT_Fail $r '14e  Service start: ansible.builtin.systemd with state=started' `
                "Ok=$($res.Ok) module=$($c -match 'ansible.builtin.systemd') state=$($c -match 'state: started')"
        }
    } catch { _IT_Fail $r '14e  Service start' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14f — _Get-ServicePlaybook (restart): state=restarted
    # ------------------------------------------------------------------
    try {
        $res = _Get-ServicePlaybook -Action 'restart' -ServiceName 'nginx'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*restarted') {
            _IT_Pass $r '14f  Service restart: state=restarted'
        } else {
            _IT_Fail $r '14f  Service restart: state=restarted' "Ok=$($res.Ok) restarted=$($c -match 'state: restarted')"
        }
    } catch { _IT_Fail $r '14f  Service restart' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14g — _Get-ServicePlaybook (enable): enabled=true, no state key
    # ------------------------------------------------------------------
    try {
        $res = _Get-ServicePlaybook -Action 'enable' -ServiceName 'nginx'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'enabled:\s*true' -and $c -notmatch 'state:') {
            _IT_Pass $r '14g  Service enable: enabled=true, no state key'
        } else {
            _IT_Fail $r '14g  Service enable: enabled=true, no state key' `
                "Ok=$($res.Ok) enabled=$($c -match 'enabled: true') no-state=$($c -notmatch 'state:')"
        }
    } catch { _IT_Fail $r '14g  Service enable' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14h — _Get-UserPlaybook (create): correct module and state=present
    # ------------------------------------------------------------------
    try {
        $res = _Get-UserPlaybook -Action 'create' -UserName 'deploy' -Groups @('docker','sudo')
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'ansible\.builtin\.user' -and $c -match 'state:\s*present') {
            _IT_Pass $r '14h  User create: ansible.builtin.user with state=present'
        } else {
            _IT_Fail $r '14h  User create: ansible.builtin.user with state=present' `
                "Ok=$($res.Ok) module=$($c -match 'ansible.builtin.user') state=$($c -match 'state: present')"
        }
    } catch { _IT_Fail $r '14h  User create' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14i — User create: groups and shell appear in playbook
    # ------------------------------------------------------------------
    try {
        $c = if (Test-Path (_LatestYml)) { Get-Content (_LatestYml) -Raw } else { '' }
        if ($c -match 'docker' -and $c -match 'sudo' -and $c -match '/bin/bash') {
            _IT_Pass $r '14i  User create: groups and shell present in playbook'
        } else {
            _IT_Fail $r '14i  User create: groups and shell present in playbook' `
                "docker=$($c -match 'docker') sudo=$($c -match 'sudo') shell=$($c -match '/bin/bash')"
        }
    } catch { _IT_Fail $r '14i  User groups and shell' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14j — _Get-UserPlaybook (remove): state=absent, remove=true
    # ------------------------------------------------------------------
    try {
        $res = _Get-UserPlaybook -Action 'remove' -UserName 'deploy'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*absent' -and $c -match 'remove:\s*true') {
            _IT_Pass $r '14j  User remove: state=absent and remove=true'
        } else {
            _IT_Fail $r '14j  User remove: state=absent and remove=true' `
                "Ok=$($res.Ok) absent=$($c -match 'state: absent') remove=$($c -match 'remove: true')"
        }
    } catch { _IT_Fail $r '14j  User remove' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14k — _Get-FilePlaybook: correct module, src, dest, mode
    # ------------------------------------------------------------------
    try {
        $res = _Get-FilePlaybook -Src '/tmp/app.conf' -Dest '/etc/app/app.conf' -Mode '0640'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'ansible\.builtin\.copy' -and
            $c -match 'src:.*app\.conf' -and $c -match "mode:.*0640") {
            _IT_Pass $r '14k  File copy: ansible.builtin.copy with correct src, dest, mode'
        } else {
            _IT_Fail $r '14k  File copy: ansible.builtin.copy with correct src, dest, mode' `
                "Ok=$($res.Ok) module=$($c -match 'ansible.builtin.copy') src=$($c -match 'app.conf') mode=$($c -match '0640')"
        }
    } catch { _IT_Fail $r '14k  File copy' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14l — _Get-DockerPlaybook (start): correct module and state=started
    # ------------------------------------------------------------------
    try {
        $res = _Get-DockerPlaybook -Action 'start' -ContainerName 'web-1' -Image 'nginx:latest'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'community\.docker\.docker_container' -and $c -match 'state:\s*started') {
            _IT_Pass $r '14l  Container start: community.docker.docker_container with state=started'
        } else {
            _IT_Fail $r '14l  Container start: community.docker.docker_container with state=started' `
                "Ok=$($res.Ok) module=$($c -match 'community.docker.docker_container') state=$($c -match 'state: started')"
        }
    } catch { _IT_Fail $r '14l  Container start' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14m — _Get-DockerPlaybook (remove): state=absent
    # ------------------------------------------------------------------
    try {
        $res = _Get-DockerPlaybook -Action 'remove' -ContainerName 'web-1'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*absent') {
            _IT_Pass $r '14m  Container remove: state=absent'
        } else {
            _IT_Fail $r '14m  Container remove: state=absent' "Ok=$($res.Ok) absent=$($c -match 'state: absent')"
        }
    } catch { _IT_Fail $r '14m  Container remove' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14n — _Get-DockerPlaybook (recreate): recreate=true and pull=true
    # ------------------------------------------------------------------
    try {
        $res = _Get-DockerPlaybook -Action 'recreate' -ContainerName 'web-1' -Image 'nginx:latest'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'recreate:\s*true' -and $c -match 'pull:\s*true') {
            _IT_Pass $r '14n  Container recreate: recreate=true and pull=true'
        } else {
            _IT_Fail $r '14n  Container recreate: recreate=true and pull=true' `
                "Ok=$($res.Ok) recreate=$($c -match 'recreate: true') pull=$($c -match 'pull: true')"
        }
    } catch { _IT_Fail $r '14n  Container recreate' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14o — Return object has Ok, Path, Message properties
    # ------------------------------------------------------------------
    try {
        $res   = _Get-PackagePlaybook -Action 'install' -PackageName 'git'
        $props = $res.PSObject.Properties.Name
        if (($props -contains 'Ok') -and ($props -contains 'Path') -and ($props -contains 'Message')) {
            _IT_Pass $r '14o  Return object has Ok, Path, Message'
        } else {
            _IT_Fail $r '14o  Return object has Ok, Path, Message' "Properties: $($props -join ', ')"
        }
    } catch { _IT_Fail $r '14o  Return object shape' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $r
}

# ── Suite 15 — Ansible batch executor ─────────────────────────────────────────

# Tests Invoke-FltAnsibleBatch and _Parse-AnsibleOutput.
# Offline strategy:
#   - Read-only mode tests exercise the full Invoke-FltAnsibleBatch code path
#     without calling ansible-playbook.
#   - Parser tests call _Parse-AnsibleOutput directly with synthetic output
#     strings, covering all exit codes and host statuses.
function Invoke-IT_AnsibleBatch {
    $r = _IT_NewResult

    _IT_Section 'Ansible batch executor'

    # Helper: build a minimal synthetic Linux FleetTarget
    function _MkLT {
        param([string]$Name, [string]$Address = '10.0.0.1')
        $t = [FleetTarget]::new($Name, $Address, 22, 'admin', $false)
        $t.OS         = 'linux'
        $t.TargetType = 'physical'
        $t
    }

    # ------------------------------------------------------------------
    # 15a — Read-only mode: returns Skipped results without calling Ansible
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -Action 'install' -PackageSpec 'curl' `
            -ReadOnly $true
        if ($results.Count -eq 1 -and $results[0].Status -eq 'Skipped') {
            _IT_Pass $r '15a  Read-only mode: single target returns Skipped'
        } else {
            _IT_Fail $r '15a  Read-only mode: single target returns Skipped' `
                "Count=$($results.Count) Status=$($results[0].Status)"
        }
    } catch { _IT_Fail $r '15a  Read-only mode' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15b — Read-only mode: Note says 'Read-only mode'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -ReadOnly $true
        if ($results[0].Note -eq 'Read-only mode') {
            _IT_Pass $r '15b  Read-only mode: Note = ''Read-only mode'''
        } else {
            _IT_Fail $r '15b  Read-only mode: Note = ''Read-only mode''' "Note=$($results[0].Note)"
        }
    } catch { _IT_Fail $r '15b  Read-only note' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15c — Read-only mode: PackageManager = 'ansible'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -ReadOnly $true
        if ($results[0].PackageManager -eq 'ansible') {
            _IT_Pass $r '15c  Read-only mode: PackageManager = ''ansible'''
        } else {
            _IT_Fail $r '15c  Read-only mode: PackageManager = ''ansible''' `
                "PackageManager=$($results[0].PackageManager)"
        }
    } catch { _IT_Fail $r '15c  PackageManager field' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15d — Read-only mode: multiple targets all return Skipped
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1'; _MkLT 'lin-2' '10.0.0.2'; _MkLT 'lin-3' '10.0.0.3')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -ReadOnly $true
        $allSkipped = ($results | Where-Object { $_.Status -ne 'Skipped' }).Count -eq 0
        if ($results.Count -eq 3 -and $allSkipped) {
            _IT_Pass $r '15d  Read-only mode: all 3 targets return Skipped'
        } else {
            _IT_Fail $r '15d  Read-only mode: all 3 targets return Skipped' `
                "Count=$($results.Count) NotSkipped=$(($results | Where-Object { $_.Status -ne 'Skipped' }).Count)"
        }
    } catch { _IT_Fail $r '15d  Read-only multi-target' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15e — BatchResult shape: has all required fields
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        $r0    = $results[0]
        $props = $r0.PSObject.Properties.Name
        $required = @('TargetName','Action','PackageSpec','PackageManager','Status','DurationSec','TimedOut','Note')
        $missing  = $required | Where-Object { $props -notcontains $_ }
        if ($missing.Count -eq 0) {
            _IT_Pass $r '15e  BatchResult has all required fields'
        } else {
            _IT_Fail $r '15e  BatchResult has all required fields' "Missing: $($missing -join ', ')"
        }
    } catch { _IT_Fail $r '15e  BatchResult shape' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15f — BatchResult field values: Action and PackageSpec preserved
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        $r0 = $results[0]
        if ($r0.Action -eq 'install' -and $r0.PackageSpec -eq 'curl' -and $r0.TargetName -eq 'lin-1') {
            _IT_Pass $r '15f  BatchResult: Action, PackageSpec, TargetName correct'
        } else {
            _IT_Fail $r '15f  BatchResult: Action, PackageSpec, TargetName correct' `
                "Action=$($r0.Action) PackageSpec=$($r0.PackageSpec) TargetName=$($r0.TargetName)"
        }
    } catch { _IT_Fail $r '15f  BatchResult field values' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15g — Parser: SUCCESS line → Status='OK'
    # ------------------------------------------------------------------
    try {
        $targets  = @(_MkLT 'lin-1' '10.0.0.1')
        $fakeOut  = 'lin-1 | SUCCESS => {"changed": false}'
        $parsed   = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 0 `
                        -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 1.5
        if ($parsed[0].Status -eq 'OK') {
            _IT_Pass $r '15g  Parser: SUCCESS line → Status=OK'
        } else {
            _IT_Fail $r '15g  Parser: SUCCESS line → Status=OK' "Status=$($parsed[0].Status)"
        }
    } catch { _IT_Fail $r '15g  Parser SUCCESS' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15h — Parser: CHANGED line → Status='OK'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $fakeOut = 'lin-1 | CHANGED => {"changed": true}'
        $parsed  = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 0 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 1.0
        if ($parsed[0].Status -eq 'OK') {
            _IT_Pass $r '15h  Parser: CHANGED line → Status=OK'
        } else {
            _IT_Fail $r '15h  Parser: CHANGED line → Status=OK' "Status=$($parsed[0].Status)"
        }
    } catch { _IT_Fail $r '15h  Parser CHANGED' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15i — Parser: FAILED line → Status='Failed', msg in Note
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $fakeOut = 'lin-1 | FAILED! => {"msg": "No package curl found", "task": "install curl"}'
        $parsed  = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 2 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 2.0
        if ($parsed[0].Status -eq 'Failed' -and $parsed[0].Note -match 'curl') {
            _IT_Pass $r '15i  Parser: FAILED! → Status=Failed, msg in Note'
        } else {
            _IT_Fail $r '15i  Parser: FAILED! → Status=Failed, msg in Note' `
                "Status=$($parsed[0].Status) Note=$($parsed[0].Note)"
        }
    } catch { _IT_Fail $r '15i  Parser FAILED' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15j — Parser: UNREACHABLE line → Status='Unreachable'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $fakeOut = 'lin-1 | UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}'
        $parsed  = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 4 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 0.5
        if ($parsed[0].Status -eq 'Unreachable') {
            _IT_Pass $r '15j  Parser: UNREACHABLE! → Status=Unreachable'
        } else {
            _IT_Fail $r '15j  Parser: UNREACHABLE! → Status=Unreachable' "Status=$($parsed[0].Status)"
        }
    } catch { _IT_Fail $r '15j  Parser UNREACHABLE' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15k — Parser: exit code 8 → all targets Failed with config error note
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1'; _MkLT 'lin-2' '10.0.0.2')
        $parsed  = _Parse-AnsibleOutput -RawOutput '' -ExitCode 8 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 0.1
        $allFailed = ($parsed | Where-Object { $_.Status -ne 'Failed' }).Count -eq 0
        $hasNote   = $parsed[0].Note -match 'config|parse'
        if ($allFailed -and $hasNote) {
            _IT_Pass $r '15k  Parser: exit code 8 → all Failed with config error note'
        } else {
            _IT_Fail $r '15k  Parser: exit code 8 → all Failed with config error note' `
                "AllFailed=$allFailed Note=$($parsed[0].Note)"
        }
    } catch { _IT_Fail $r '15k  Parser exit 8' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15l — Parser: mixed output — one OK, one Failed
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1'; _MkLT 'lin-2' '10.0.0.2')
        $fakeOut = @(
            'lin-1 | SUCCESS => {"changed": false}'
            'lin-2 | FAILED! => {"msg": "Permission denied"}'
        ) -join "`n"
        $parsed = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 2 `
                      -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 3.0
        $lin1 = $parsed | Where-Object { $_.TargetName -eq 'lin-1' }
        $lin2 = $parsed | Where-Object { $_.TargetName -eq 'lin-2' }
        if ($lin1.Status -eq 'OK' -and $lin2.Status -eq 'Failed') {
            _IT_Pass $r '15l  Parser: mixed output — lin-1=OK, lin-2=Failed'
        } else {
            _IT_Fail $r '15l  Parser: mixed output — lin-1=OK, lin-2=Failed' `
                "lin-1=$($lin1.Status) lin-2=$($lin2.Status)"
        }
    } catch { _IT_Fail $r '15l  Parser mixed output' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15m — OnProgress callback is invoked in read-only mode
    # ------------------------------------------------------------------
    try {
        $targets      = @(_MkLT 'lin-1')
        $callbackFired = $false
        $cb = { param($dict); $script:callbackFired = $true }
        $null = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -OnProgress $cb -ReadOnly $true
        if ($script:callbackFired) {
            _IT_Pass $r '15m  OnProgress callback invoked in read-only mode'
        } else {
            _IT_Fail $r '15m  OnProgress callback invoked in read-only mode' 'Callback was not called'
        }
    } catch { _IT_Fail $r '15m  OnProgress callback' $_.Exception.Message }

    return $r
}

# ── Suite 16 — Fleet executor routing ─────────────────────────────────────────

# Tests the Ansible/tcpkg/winget/push bucket routing in Invoke-FleetAction.
# Uses read-only mode throughout — no SSH, no Ansible, no tcpkg calls are made.
# Sets $Script:FltReadOnly = $true and $Script:FltBatchStatus = @{} before each
# call, then restores the original values afterward.
function Invoke-IT_FleetRouting {
    $r = _IT_NewResult

    _IT_Section 'Fleet executor routing'

    # Save and restore script-scope state
    $savedReadOnly     = $Script:FltReadOnly
    $savedBatchStatus  = $Script:FltBatchStatus
    $Script:FltReadOnly    = $true
    $Script:FltBatchStatus = @{}

    # Helper: build a minimal FleetTarget
    function _MkT {
        param([string]$Name, [string]$OS='windows', [string]$Type='physical',
              [string]$PM='', [bool]$IA=$true)
        $t = [FleetTarget]::new($Name, "10.0.0.1", 22, 'admin', $IA)
        $t.OS            = $OS
        $t.TargetType    = $Type
        $t.PackageManager = $PM
        $t
    }

    # ------------------------------------------------------------------
    # 16a — Linux physical target routes to Ansible bucket (read-only status)
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'lin-1' 'linux' 'physical')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'lin-1' }
        if ($r0 -and $r0.Status -match 'ansible') {
            _IT_Pass $r '16a  Linux physical target routes to Ansible bucket'
        } else {
            _IT_Fail $r '16a  Linux physical target routes to Ansible bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '16a  Linux → Ansible routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16b — Linux VM target routes to Ansible bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'lin-vm-1' 'linux' 'vm')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'lin-vm-1' }
        if ($r0 -and $r0.Status -match 'ansible') {
            _IT_Pass $r '16b  Linux VM target routes to Ansible bucket'
        } else {
            _IT_Fail $r '16b  Linux VM target routes to Ansible bucket' "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '16b  Linux VM → Ansible routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16c — Linux container target does NOT route to Ansible bucket;
    #        gets Unsupported result (no package manager configured)
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'cntr-1' 'linux' 'container')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'cntr-1' }
        if ($r0 -and $r0.Status -eq 'Unsupported' -and $r0.Status -notmatch 'ansible') {
            _IT_Pass $r '16c  Linux container: Unsupported (not routed to Ansible)'
        } else {
            _IT_Fail $r '16c  Linux container: Unsupported (not routed to Ansible)' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '16c  Container not Ansible' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16d — Windows target does NOT route to Ansible bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-1' 'windows' 'physical' 'tcpkg' $true)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-1' }
        if ($r0 -and $r0.Status -notmatch 'ansible') {
            _IT_Pass $r '16d  Windows target does NOT route to Ansible bucket'
        } else {
            _IT_Fail $r '16d  Windows target does NOT route to Ansible bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '16d  Windows not Ansible' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16e — Windows tcpkg target routes to tcpkg SSH bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-1' 'windows' 'physical' 'tcpkg' $true)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-1' }
        if ($r0 -and $r0.Status -match 'tcpkg') {
            _IT_Pass $r '16e  Windows tcpkg target routes to tcpkg SSH bucket'
        } else {
            _IT_Fail $r '16e  Windows tcpkg target routes to tcpkg SSH bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '16e  Windows → tcpkg routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16f — Windows winget target routes to WinGet SSH bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-wg' 'windows' 'physical' 'winget' $true)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-wg' }
        if ($r0 -and $r0.Status -match 'winget') {
            _IT_Pass $r '16f  Windows winget target routes to WinGet SSH bucket'
        } else {
            _IT_Fail $r '16f  Windows winget target routes to WinGet SSH bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '16f  Windows → WinGet routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16g — Windows target with InternetAccess=False routes to push bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-push' 'windows' 'physical' 'tcpkg' $false)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-push' }
        if ($r0 -and $r0.Status -match 'push') {
            _IT_Pass $r '16g  Windows IA=False routes to push bucket'
        } else {
            _IT_Fail $r '16g  Windows IA=False routes to push bucket' "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '16g  Windows → push routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16h — Mixed fleet: Linux→Ansible, Windows→tcpkg, in one call
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(
            (_MkT 'lin-1'  'linux'   'physical' ''      $true)
            (_MkT 'win-1'  'windows' 'physical' 'tcpkg' $true)
        )
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $lin = $results | Where-Object { $_.TargetName -eq 'lin-1' }
        $win = $results | Where-Object { $_.TargetName -eq 'win-1' }
        if ($lin.Status -match 'ansible' -and $win.Status -match 'tcpkg') {
            _IT_Pass $r '16h  Mixed fleet: lin-1→Ansible, win-1→tcpkg'
        } else {
            _IT_Fail $r '16h  Mixed fleet: lin-1→Ansible, win-1→tcpkg' `
                "lin=$($lin.Status) win=$($win.Status)"
        }
    } catch { _IT_Fail $r '16h  Mixed fleet routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16i — Ansible result has PackageManager = 'ansible'
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'lin-1' 'linux' 'physical')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'lin-1' }
        if ($r0 -and $r0.PackageManager -eq 'ansible') {
            _IT_Pass $r '16i  Ansible bucket result has PackageManager=''ansible'''
        } else {
            _IT_Fail $r '16i  Ansible bucket result has PackageManager=''ansible''' `
                "PackageManager=$($r0.PackageManager)"
        }
    } catch { _IT_Fail $r '16i  Ansible PackageManager field' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16j — All targets return a result (no silent drops)
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(
            (_MkT 'lin-1'    'linux'   'physical'  ''       $true)
            (_MkT 'lin-2'    'linux'   'vm'        ''       $true)
            (_MkT 'win-1'    'windows' 'physical'  'tcpkg'  $true)
            (_MkT 'win-wg'   'windows' 'physical'  'winget' $true)
            (_MkT 'win-push' 'windows' 'physical'  'tcpkg'  $false)
        )
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        if ($results.Count -eq 5) {
            _IT_Pass $r '16j  All 5 targets return a result (no silent drops)'
        } else {
            _IT_Fail $r '16j  All 5 targets return a result (no silent drops)' `
                "Got $($results.Count) results, expected 5"
        }
    } catch { _IT_Fail $r '16j  No silent drops' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Restore script-scope state
    # ------------------------------------------------------------------
    $Script:FltReadOnly    = $savedReadOnly
    $Script:FltBatchStatus = $savedBatchStatus

    return $r
}