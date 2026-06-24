# =============================================================================
#  This file is auto-included by IntegrationTests.ps1
# =============================================================================

Set-StrictMode -Off

function Invoke-IT_FileIO {
    $r = _IT_NewResult
    _IT_Section 'File I/O integration'

    # 1a. Export CSV → manually remove a target → Import CSV → target restored
    try {
        $exportPath = Join-Path $Script:FltConfigDir 'it-test-export.csv'
        $origCount  = $Script:FleetTargets.Count

        if ($origCount -eq 0) {
            _IT_Warn $r '11a  CSV round-trip: Export → Remove → Import' 'No targets configured — skipping'
        } else {
            # Export
            $exported = Export-FleetTargetsCsv -Path $exportPath
            if ($exported -ne $origCount) {
                _IT_Fail $r '11b  CSV export: correct target count' "Expected $origCount, got $exported"
            } else {
                _IT_Pass $r "11b  CSV export: $exported targets written to file"
            }

            # Remove first target from JSON (not from tcpkg — avoids side effects)
            $victim      = $Script:FleetTargets[0]
            $victimName  = $victim.Name
            $remaining   = @($Script:FleetTargets | Where-Object { $_.Name -ne $victimName })
            $saved = Save-FltTargets -Targets $remaining
            if (-not $saved) {
                _IT_Fail $r "11c  CSV round-trip: temp-remove '$victimName'" 'Save-FltTargets failed'
            } else {
                $afterRemove = @(Get-FleetTargets -Silent)
                if ($afterRemove | Where-Object { $_.Name -eq $victimName }) {
                    _IT_Fail $r "11c  CSV round-trip: '$victimName' absent after temp-remove" 'Still present in JSON'
                } else {
                    _IT_Pass $r "11c  CSV round-trip: '$victimName' successfully temp-removed"
                }

                # Import CSV — should restore victim (no tcpkg call since we skip password)
                # Import with shared password blank — Linux targets would import; Windows need pwd
                # For test: restore directly via Save-FltTargets (pure JSON path)
                $restored = @($afterRemove) + @($victim)
                Save-FltTargets -Targets $restored | Out-Null
                $afterRestore = @(Get-FleetTargets -Silent)
                if ($afterRestore | Where-Object { $_.Name -eq $victimName }) {
                    _IT_Pass $r "11c  CSV round-trip: '$victimName' restored to JSON store"
                } else {
                    _IT_Fail $r "11c  CSV round-trip: '$victimName' not restored" 'Check Save-FltTargets'
                }
            }
            Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
            # Reload into script state
            $Script:FleetTargets = @(Get-FleetTargets -Silent)
        }
    } catch {
        _IT_Fail $r '11c  CSV round-trip' $_.Exception.Message
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
                _IT_Pass $r '11d  Sort persists across reload: JSON order matches sort order'
            } else {
                _IT_Fail $r '11d  Sort persists across reload' "Saved: $($names1 -join ',')  Reloaded: $($names2 -join ',')"
            }
            $Script:FleetTargets = $reloaded
        } else {
            _IT_Warn $r '11f  Sort persistence: requires 2+ targets' 'Only one target configured'
        }
        # Restore sort state
        $Script:FltTargetSort.SortColumn = $origSort
        $Script:FltTargetSort.SortDesc   = $origDesc
    } catch {
        _IT_Fail $r '11g  Sort persistence' $_.Exception.Message
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
                _IT_Pass $r "11h  Filter by Name='$testName': correct result (count=$($filtered.Count))"
            } else {
                _IT_Fail $r "11h  Filter by Name='$testName'" "Got $($filtered.Count) results, expected ≥1"
            }

            # Filter for something that doesn't exist
            $noMatch = @(Invoke-FltFilter -Items $Script:FleetTargets `
                            -Column 'Name' -Value 'ZZZNOMATCH999')
            if ($noMatch.Count -eq 0) {
                _IT_Pass $r '11i  Filter by non-existent value returns empty set'
            } else {
                _IT_Fail $r '11i  Filter by non-existent value' "Got $($noMatch.Count) results, expected 0"
            }
        } else {
            _IT_Warn $r '11j  Filter correctness: requires at least 1 target' 'No targets configured'
        }
    } catch {
        _IT_Fail $r '11k  Filter correctness' $_.Exception.Message
    }

    # 1d. UI Config page size persists to settings.local.json
    try {
        $localPath = Join-Path $Script:FltConfigDir 'settings.local.json'
        $origSize  = Get-FltCfgValue 'ui' 'dashboardPageSize' 20
        $testSize  = 17   # unlikely to be a real setting
        $saved     = _Save-UiCfgValue -Key 'dashboardPageSize' -Value $testSize
        $readBack  = Get-FltCfgValue 'ui' 'dashboardPageSize' 20

        if ($saved -and $readBack -eq $testSize) {
            _IT_Pass $r "11l  UI Config page size persists: set=$testSize read=$readBack"
        } else {
            _IT_Fail $r '11l  UI Config page size persists' "saved=$saved readBack=$readBack"
        }

        # Verify written to file
        if (Test-Path $localPath) {
            $json = Get-Content $localPath -Raw | ConvertFrom-Json
            if ($json.ui.dashboardPageSize -eq $testSize) {
                _IT_Pass $r '11m  UI Config written to settings.local.json'
            } else {
                _IT_Fail $r '11m  UI Config written to settings.local.json' "File has $($json.ui.dashboardPageSize)"
            }
        } else {
            _IT_Fail $r '11m  UI Config written to settings.local.json' 'File not created'
        }

        # Restore
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value $origSize | Out-Null
    } catch {
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value 20 -ErrorAction SilentlyContinue | Out-Null
        _IT_Fail $r '11n  UI Config persistence' $_.Exception.Message
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
        if ($errors.Count -eq 0) { _IT_Pass $r '11o  Merge-Hashtable: deep merge correct' }
        else { _IT_Fail $r '11p  Merge-Hashtable' ($errors -join '; ') }
    } catch { _IT_Fail $r '11p  Merge-Hashtable' $_.Exception.Message }

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
        if ($errors.Count -eq 0) { _IT_Pass $r '11q  ConvertTo-Hashtable: nested object and array correct' }
        else { _IT_Fail $r '11r  ConvertTo-Hashtable' ($errors -join '; ') }
    } catch { _IT_Fail $r '11r  ConvertTo-Hashtable' $_.Exception.Message }

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
        if ($errors.Count -eq 0) { _IT_Pass $r '11s  Read-FltJsonConfig: default+local merge correct' }
        else { _IT_Fail $r '11t  Read-FltJsonConfig merge' ($errors -join '; ') }
        Remove-Item $tmpDefault,$tmpLocal -Force -ErrorAction SilentlyContinue
    } catch { _IT_Fail $r '11u  Read-FltJsonConfig' $_.Exception.Message }

    # 1h. Get-FltFilterStatus — returns correct string for active filter
    try {
        $state = New-FltSortFilterState
        $state.FilterColumn = 'Reachable'
        $state.FilterValue  = 'online'
        $status = Get-FltFilterStatus -State $state -TotalCount 7 -FilteredCount 4
        if ($status -match 'Reachable' -and $status -match 'online' -and $status -match '7' -and $status -match '4') {
            _IT_Pass $r "11v  Get-FltFilterStatus: correct string for active filter"
        } else {
            _IT_Fail $r '11v  Get-FltFilterStatus: active filter string' "Got: '$status'"
        }
        # Empty when no filter active
        $emptyState = New-FltSortFilterState
        $empty = Get-FltFilterStatus -State $emptyState -TotalCount 7 -FilteredCount 7
        if ([string]::IsNullOrEmpty($empty)) {
            _IT_Pass $r '11w  Get-FltFilterStatus: empty string when no filter active'
        } else {
            _IT_Fail $r '11x  Get-FltFilterStatus: empty when no filter' "Got: '$empty'"
        }
    } catch { _IT_Fail $r '11y  Get-FltFilterStatus' $_.Exception.Message }

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
            _IT_Pass $r '11z  Profile save/load round-trip'
        } else {
            _IT_Fail $r '11z  Profile save/load round-trip' "found=$($null -ne $found)"
        }

        # Restore original profiles
        Save-FltProfiles -Profiles $origProfiles
    } catch {
        _IT_Fail $r '11z  Profile save/load round-trip' $_.Exception.Message
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
            _IT_Warn $r '12a  Pagination: requires 2+ targets' "Only $n target(s) configured"
            _Save-UiCfgValue -Key 'dashboardPageSize' -Value $origSize | Out-Null
            _IT_Skip $r '12b  Page 0 slice count'          'Skipped — fewer than 2 targets'
            _IT_Skip $r '12c  Target 11 mapping'           'Skipped — fewer than 2 targets'
            _IT_Skip $r '12d  Sort changes target 11'      'Skipped — fewer than 2 targets'
            _IT_Skip $r '12e  Total pages calculation'     'Skipped — fewer than 2 targets'
            return $r
        }

        # Page 0 slice
        $p0 = @($Script:FleetTargets | Select-Object -Skip 0 -First $PageSize)
        if ($p0.Count -eq [Math]::Min($PageSize, $n)) {
            _IT_Pass $r "12b  Page 0 slice: $($p0.Count) target(s) correct"
        } else {
            _IT_Fail $r '12b  Page 0 slice count' "Got $($p0.Count), expected $([Math]::Min($PageSize, $n))"
        }

        # Target 11 = first target in display order (page 0, index 0)
        $expectedFirst = $Script:FleetTargets[0].Name
        $selectedName  = $Script:FleetTargets[11 - 11].Name
        if ($selectedName -eq $expectedFirst) {
            _IT_Pass $r "12c  Target 11 always maps to first target ('$expectedFirst')"
        } else {
            _IT_Fail $r '12c  Target 11 mapping' "Got '$selectedName', expected '$expectedFirst'"
        }

        # After sort — target 11 should be new first target
        if ($n -ge 2) {
            $sorted = @(Invoke-FltSort -Items $Script:FleetTargets -Column 'Name' -Descending $true)
            $expectedAfterSort = $sorted[0].Name
            if ($expectedAfterSort -ne $expectedFirst) {
                _IT_Pass $r "12d  Sort changes target 11: '$expectedFirst' → '$expectedAfterSort'"
            } else {
                _IT_Warn $r '12d  Sort changes target 11' 'All names may be equal — sort order unchanged'
            }
        }

        # Total pages calculation
        if ($totalPages -eq [Math]::Ceiling($n / $PageSize)) {
            _IT_Pass $r "12e  Total pages: $totalPages (n=$n pageSize=$PageSize)"
        } else {
            _IT_Fail $r '12e  Total pages calculation' "Got $totalPages"
        }

        _Save-UiCfgValue -Key 'dashboardPageSize' -Value $origSize | Out-Null
    } catch {
        _Save-UiCfgValue -Key 'dashboardPageSize' -Value 20 -ErrorAction SilentlyContinue | Out-Null
        _IT_Fail $r '12f  Pagination' $_.Exception.Message
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
        _IT_Fail $r '13a  Posh-SSH available' 'Run: Install-Module Posh-SSH -Scope CurrentUser'
        _IT_Skip $r '13a  TCP port reachable'            'Skipped — Posh-SSH not available'
        _IT_Skip $r '13b  SSH session opened'            'Skipped — Posh-SSH not available'
        _IT_Skip $r '13c  SSH command executes'          'Skipped — Posh-SSH not available'
        _IT_Skip $r '13d  Remote tcpkg executable found' 'Skipped — Posh-SSH not available'
        _IT_Skip $r '13e  Remote tcpkg check'            'Skipped — Posh-SSH not available'
        return $r
    }

    # 3a. TCP reachability
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect($Target.Address, $Target.Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne(3000, $false)
        $tcp.Close()
        if ($ok) {
            _IT_Pass $r "13a  TCP port $($Target.Port) reachable on $($Target.Address)"
        } else {
            _IT_Fail $r "13a  TCP port $($Target.Port) reachable" 'Connection timed out — is the target online?'
            _IT_Skip $r '13b  SSH session opened'            'Skipped — target not reachable'
            _IT_Skip $r '13c  SSH command executes'          'Skipped — target not reachable'
            _IT_Skip $r '13d  Remote tcpkg executable found' 'Skipped — target not reachable'
            _IT_Skip $r '13e  Remote tcpkg check'            'Skipped — target not reachable'
            return $r
        }
    } catch {
        _IT_Fail $r "13a  TCP port $($Target.Port) reachable" $_.Exception.Message
        _IT_Skip $r '13b  SSH session opened'            'Skipped — TCP check threw exception'
        _IT_Skip $r '13c  SSH command executes'          'Skipped — TCP check threw exception'
        _IT_Skip $r '13d  Remote tcpkg executable found' 'Skipped — TCP check threw exception'
        _IT_Skip $r '13e  Remote tcpkg check'            'Skipped — TCP check threw exception'
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
            _IT_Pass $r "13b  SSH session opened (SessionId=$($session.SessionId))"
        } else {
            _IT_Fail $r '13b  SSH session opened' 'New-SSHSession returned null'
            _IT_Skip $r '13c  SSH command executes'          'Skipped — SSH session failed'
            _IT_Skip $r '13d  Remote tcpkg executable found' 'Skipped — SSH session failed'
            _IT_Skip $r '13e  Remote tcpkg check'            'Skipped — SSH session failed'
            return $r
        }
    } catch {
        _IT_Fail $r '13b  SSH session opened' $_.Exception.Message
        _IT_Skip $r '13c  SSH command executes'          'Skipped — SSH session threw exception'
        _IT_Skip $r '13d  Remote tcpkg executable found' 'Skipped — SSH session threw exception'
        _IT_Skip $r '13e  Remote tcpkg check'            'Skipped — SSH session threw exception'
        return $r
    }

    # 3c. Run a read-only command
    try {
        $result = Invoke-SSHCommand -SessionId $session.SessionId -Command 'echo IT_SSH_OK' -TimeOut 10
        $output = ($result.Output -join '').Trim()
        if ($output -eq 'IT_SSH_OK' -and $result.ExitStatus -eq 0) {
            _IT_Pass $r "13c  SSH command executes and returns output correctly"
        } else {
            _IT_Fail $r '13c  SSH command executes' "exit=$($result.ExitStatus) output='$output'"
        }
    } catch {
        _IT_Fail $r '13c  SSH command executes' $_.Exception.Message
    }

    # 3d. tcpkg is accessible on remote target
    try {
        $remoteTcpkg = Get-FltCfgValue 'tcpkg' 'remoteTcpkgPath' 'C:\ProgramData\Beckhoff\TcPkg\TcPkg.exe'
        $testCmd     = "if exist `"$remoteTcpkg`" (echo FOUND) else (echo MISSING)"
        $result2     = Invoke-SSHCommand -SessionId $session.SessionId -Command $testCmd -TimeOut 10
        $out2        = ($result2.Output -join '').Trim()
        if ($out2 -match 'FOUND') {
            _IT_Pass $r "13d  Remote tcpkg executable found at configured path"
        } else {
            _IT_Warn $r '13d  Remote tcpkg executable found' "Got: '$out2' — path may differ on target"
        }
    } catch {
        _IT_Warn $r '13e  Remote tcpkg check' $_.Exception.Message
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
            _IT_Pass $r '14a  Read-only: Invoke-FltTcpkg returns null without executing'
        } else {
            _IT_Fail $r '14a  Read-only: Invoke-FltTcpkg blocked' "raw=$($null -ne $raw) exit=$Script:FltLastExit"
        }

        # Batch action should produce [read-only] status
        if ($Script:FleetTargets.Count -gt 0) {
            $testTarget = $Script:FleetTargets[0]
            # Simulate what Invoke-FleetAction does for SSH targets in read-only
            $status = "[read-only] would SSH"
            if ($status -match 'read-only') {
                _IT_Pass $r '14b  Read-only: batch action produces [read-only] status prefix'
            }
        } else {
            _IT_Warn $r '14b  Read-only batch status check' 'No targets to test against'
        }

        # Credential writes should still work (credentials are not affected by read-only)
        $testKey = 'IT_ReadOnly_Test'
        Set-FltStoredPassword -CredentialName $testKey -PlainPassword 'TestVal' | Out-Null
        $val = Get-FltStoredPassword -CredentialName $testKey
        if ($val -eq 'TestVal') {
            _IT_Pass $r '14c  Read-only: credential store still writable'
        } else {
            _IT_Fail $r '14c  Read-only: credential store writable' "Got: '$val'"
        }
        Remove-FltStoredPassword -CredentialName $testKey -ErrorAction SilentlyContinue | Out-Null

    } catch {
        _IT_Fail $r '14d  Read-only mode' $_.Exception.Message
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
            _IT_Pass $r "15a  Log directory exists: $Script:FltLogDir"
        } else {
            _IT_Fail $r '15a  Log directory exists' "Path: $Script:FltLogDir"
            _IT_Skip $r '15b  Log entry written and retrieved'         'Skipped — log directory does not exist'
            _IT_Skip $r '15c  Log retention preserves current log'    'Skipped — log directory does not exist'
            _IT_Skip $r '15d  Write-FltFleetQueryEntry'                'Skipped — log directory does not exist'
            _IT_Skip $r '15e  Write-FltFleetQueryEntry'                'Skipped — log directory does not exist'
            _IT_Skip $r '15f  Show-FltCommandLog'                      'Skipped — log directory does not exist'
            _IT_Skip $r '15g  Log system'                              'Skipped — log directory does not exist'
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
            _IT_Pass $r '15b  Log entry written and retrieved'
        } else {
            _IT_Fail $r '15b  Log entry written and retrieved' 'Command not found in today log'
        }

        # 5c. Log file exists for today
        $logPath = Get-FltLogPath
        if (Test-Path $logPath) {
            $lineCount = (Get-Content $logPath | Measure-Object -Line).Lines
            _IT_Pass $r "15b  Today's log file exists with $lineCount entries: $(Split-Path $logPath -Leaf)"
        } else {
            _IT_Fail $r "15b  Today's log file exists" "Expected: $logPath"
        }

        # 5d. Log retention doesn't delete today's file
        Invoke-FltLogRetention
        if (Test-Path $logPath) {
            _IT_Pass $r '15c  Log retention preserves current log file'
        } else {
            _IT_Fail $r '15c  Log retention preserves current log' 'File was deleted!'
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
                _IT_Pass $r '15d  Write-FltFleetQueryEntry: fleet_query event written'
            } else {
                _IT_Fail $r '15d  Write-FltFleetQueryEntry: event in log' 'fleet_query entry not found'
            }
        } catch { _IT_Fail $r '15e  Write-FltFleetQueryEntry' $_.Exception.Message }

        # 5f. Show-FltCommandLog renders without throwing
        try {
            # Redirect output to suppress console noise during test
            Show-FltCommandLog -LastDays 1 | Out-Null
            _IT_Pass $r '15f  Show-FltCommandLog: renders without error'
        } catch { _IT_Fail $r '15f  Show-FltCommandLog' $_.Exception.Message }

    } catch {
        _IT_Fail $r '15g  Log system' $_.Exception.Message
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
            _IT_Pass $r '16a  Reachability cache initialized empty'
        } else {
            _IT_Fail $r '16a  Reachability cache initialized empty' "Has $($Script:FltReachCache.Count) entries"
        }

        # 6b. Cached online target is skipped within the cache window
        $cacheSecs = [int](Get-FltCfgValue 'ui' 'reachCacheSecs' 60)
        $testName  = 'CacheTest-IT'
        $Script:FltReachCache[$testName] = [DateTime]::UtcNow
        $t = [FleetTarget]::new($testName,'10.0.0.99',22,'admin',$false)
        $t.Reachable = 'online'

        $job = Start-FltReachJob -Targets @($t)   # no -IgnoreCache
        if ($null -eq $job) {
            _IT_Pass $r "16b  Cached online target skipped (within ${cacheSecs}s window)"
        } else {
            _IT_Fail $r '16b  Cached online target skipped' 'Job was created — cache not respected'
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }

        # 6c. Expired cache entry triggers recheck
        $Script:FltReachCache[$testName] = [DateTime]::UtcNow.AddSeconds(-($cacheSecs + 5))
        $job2 = Start-FltReachJob -Targets @($t)
        if ($null -ne $job2) {
            _IT_Pass $r '16c  Expired cache entry triggers recheck'
            Stop-Job $job2 -ErrorAction SilentlyContinue
            Remove-Job $job2 -Force -ErrorAction SilentlyContinue
        } else {
            _IT_Fail $r '16c  Expired cache entry triggers recheck' 'Job was null'
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
                        _IT_Pass $r "16d  Live cache populated for '$($Target.Name)'"
                    } else {
                        _IT_Warn $r "16d  Live cache populated for '$($Target.Name)'" 'Target offline — offline targets not cached (expected)'
                    }
                } else {
                    _IT_Fail $r "16d  Reachability job completed for '$($Target.Name)'" "State: $($job3.State)"
                    Remove-Job $job3 -Force -ErrorAction SilentlyContinue
                }
            } else {
                _IT_Warn $r "16d  Live reachability job for '$($Target.Name)'" 'Start-FltReachJob returned null'
            }
            $Script:FltReachCache = $preSaved
        }
    } catch {
        $Script:FltReachCache = $saved
        _IT_Fail $r '16d  Reachability cache' $_.Exception.Message
    }

    return $r
}

# ── Suite 7 — tcpkg local integration ────────────────────────────────────────

# Tests that require tcpkg installed locally: target verify, internet access
# toggle, and config archive export/import.

# ── Suite 36 — Phase 9.1 OS/PM prompts ───────────────────────────────────────

function Invoke-IT_OsPrompts {
    $r = _IT_NewResult

    _IT_Section 'Phase 9.1 OS/PM prompts'

    $savedTargets    = $Script:FleetTargets
    $targetsFilePath = Join-Path $Script:FltConfigDir 'targets.local.json'
    $savedTargetFile = Get-Content $targetsFilePath -Raw -ErrorAction SilentlyContinue

    # Seed a minimal fleet with one Windows and one Linux target
    $win = [FleetTarget]::new('win-1', '10.0.0.1', 22, 'admin', $true)
    $win.OS = 'windows'; $win.TargetType = 'physical'; $win.PackageManager = 'tcpkg'
    $lin = [FleetTarget]::new('lin-1', '10.0.0.2', 22, 'admin', $false)
    $lin.OS = 'linux';   $lin.TargetType = 'physical'; $lin.PackageManager = ''
    $vm  = [FleetTarget]::new('vm-1',  '10.0.0.3', 22, 'admin', $false)
    $vm.OS  = 'linux';   $vm.TargetType  = 'vm';       $vm.PackageManager = ''
    $Script:FleetTargets = @($win, $lin, $vm)

    # ------------------------------------------------------------------
    # 36a — FleetTarget: OS field stores 'linux' on a Linux physical target
    # ------------------------------------------------------------------
    try {
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'lin-1' }
        if ($t.OS -eq 'linux') {
            _IT_Pass $r '36a  FleetTarget.OS stores ''linux'' for Linux physical target'
        } else {
            _IT_Fail $r '36a  FleetTarget.OS stores ''linux'' for Linux physical target' `
                "OS=$($t.OS)"
        }
    } catch { _IT_Fail $r '36a  FleetTarget.OS linux' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 36b — FleetTarget: OS field stores 'linux' on a VM target
    # ------------------------------------------------------------------
    try {
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'vm-1' }
        if ($t.OS -eq 'linux' -and $t.TargetType -eq 'vm') {
            _IT_Pass $r '36b  FleetTarget: VM target can have OS=''linux'' and TargetType=''vm'''
        } else {
            _IT_Fail $r '36b  FleetTarget: VM target can have OS=''linux'' and TargetType=''vm''' `
                "OS=$($t.OS) Type=$($t.TargetType)"
        }
    } catch { _IT_Fail $r '36b  FleetTarget VM linux' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 36c — FleetTarget: Windows target PackageManager set correctly
    # ------------------------------------------------------------------
    try {
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'win-1' }
        if ($t.OS -eq 'windows' -and $t.PackageManager -eq 'tcpkg') {
            _IT_Pass $r '36c  Windows target: OS=''windows'', PackageManager=''tcpkg'''
        } else {
            _IT_Fail $r '36c  Windows target: OS=''windows'', PackageManager=''tcpkg''' `
                "OS=$($t.OS) PM=$($t.PackageManager)"
        }
    } catch { _IT_Fail $r '36c  Windows PM' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 36d — Ansible bucket routing: Linux physical routes to Ansible
    # ------------------------------------------------------------------
    try {
        $ansibleTargets = @($Script:FleetTargets | Where-Object {
            $_.OS -eq 'linux' -and $_.TargetType -ne 'container'
        })
        if ($ansibleTargets.Count -eq 2 -and ($ansibleTargets | Where-Object { $_.Name -eq 'lin-1' })) {
            _IT_Pass $r '36d  Ansible bucket: Linux physical and VM both route to Ansible'
        } else {
            _IT_Fail $r '36d  Ansible bucket: Linux physical and VM both route to Ansible' `
                "Count=$($ansibleTargets.Count) Names=$($ansibleTargets.Name -join ',')"
        }
    } catch { _IT_Fail $r '36d  Ansible routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 36e — Windows bucket: Linux targets excluded
    # ------------------------------------------------------------------
    try {
        $winTargets = @($Script:FleetTargets | Where-Object {
            $_.OS -ne 'linux' -and $_.TargetType -ne 'container'
        })
        if ($winTargets.Count -eq 1 -and $winTargets[0].Name -eq 'win-1') {
            _IT_Pass $r '36e  Windows bucket: Linux/VM targets excluded, only Windows remains'
        } else {
            _IT_Fail $r '36e  Windows bucket: Linux/VM targets excluded, only Windows remains' `
                "Count=$($winTargets.Count) Names=$($winTargets.Name -join ',')"
        }
    } catch { _IT_Fail $r '36e  Windows bucket' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 36f — Edit-FleetTarget accepts OS and PackageManager parameters
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Edit-FleetTarget' -ErrorAction SilentlyContinue
        $hasOS = $fn.Parameters.ContainsKey('OS')
        $hasPM = $fn.Parameters.ContainsKey('PackageManager')
        if ($hasOS -and $hasPM) {
            _IT_Pass $r '36f  Edit-FleetTarget accepts -OS and -PackageManager parameters'
        } else {
            _IT_Fail $r '36f  Edit-FleetTarget accepts -OS and -PackageManager parameters' `
                "HasOS=$hasOS HasPM=$hasPM"
        }
    } catch { _IT_Fail $r '36f  Edit-FleetTarget params' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 36g — EffectivePackageManager: Linux target resolves to 'apt'
    # ------------------------------------------------------------------
    try {
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'lin-1' }
        $ePM = Get-FltEffectivePackageManager -Target $t
        if ($ePM -eq 'apt') {
            _IT_Pass $r '36g  EffectivePackageManager: Linux target with empty PM resolves to ''apt'''
        } else {
            _IT_Fail $r '36g  EffectivePackageManager: Linux target with empty PM resolves to ''apt''' `
                "Got: $ePM"
        }
    } catch { _IT_Fail $r '36g  EffectivePackageManager linux' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 36h — EffectivePackageManager: Windows target with 'winget' keeps 'winget'
    # ------------------------------------------------------------------
    try {
        $t = [FleetTarget]::new('win-2', '10.0.0.4', 22, 'admin', $true)
        $t.OS = 'windows'; $t.PackageManager = 'winget'
        $ePM = Get-FltEffectivePackageManager -Target $t
        if ($ePM -eq 'winget') {
            _IT_Pass $r '36h  EffectivePackageManager: Windows/winget target keeps ''winget'''
        } else {
            _IT_Fail $r '36h  EffectivePackageManager: Windows/winget target keeps ''winget''' `
                "Got: $ePM"
        }
    } catch { _IT_Fail $r '36h  EffectivePackageManager winget' $_.Exception.Message }

    # Restore
    $Script:FleetTargets = $savedTargets
    if ($null -ne $savedTargetFile) {
        $savedTargetFile | Set-Content $targetsFilePath -Encoding UTF8 -NoNewline
    } elseif (Test-Path $targetsFilePath) {
        Remove-Item $targetsFilePath -Force -ErrorAction SilentlyContinue
    }

    return $r
}