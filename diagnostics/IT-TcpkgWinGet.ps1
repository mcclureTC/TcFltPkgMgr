# =============================================================================
#  This file is auto-included by IntegrationTests.ps1
# =============================================================================

Set-StrictMode -Off

function Invoke-IT_TcpkgLocal {
    param([FleetTarget]$Target = $null)
    $r = _IT_NewResult
    _IT_Section 'tcpkg local integration'

    # 7a. Get-FltTcpkgExe returns a callable executable
    try {
        $exe = Get-FltTcpkgExe
        if (-not $exe) {
            _IT_Fail $r '17a  tcpkg executable configured' 'Get-FltTcpkgExe returned empty'
        } else {
            # Test-Path only works for absolute paths — for PATH-resolved names use Get-Command
            $found = (Test-Path $exe) -or ($null -ne (Get-Command $exe -ErrorAction SilentlyContinue))
            if ($found) {
                _IT_Pass $r "17a  tcpkg executable found: $exe"
            } else {
                _IT_Warn $r "17a  tcpkg executable '$exe' not found" 'Install tcpkg or update tcpkg.executablePath in settings'
            }
        }
    } catch { _IT_Fail $r '17b  Get-FltTcpkgExe' $_.Exception.Message }

    # 7b. Export config archive creates a zip file
    try {
        $exportPath = Join-Path $Script:FltConfigDir 'it-config-export.zip'
        Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
        $ok = Export-FltConfig -DestinationPath $exportPath
        if ($ok -and (Test-Path $exportPath)) {
            $size = (Get-Item $exportPath).Length
            _IT_Pass $r "17c  Export-FltConfig: archive created ($size bytes)"
        } elseif (Test-Path $exportPath) {
            _IT_Pass $r '17c  Export-FltConfig: archive file exists'
        } else {
            _IT_Fail $r '17c  Export-FltConfig: archive created' 'File not found after export'
        }
        Remove-Item $exportPath -Force -ErrorAction SilentlyContinue
    } catch { _IT_Fail $r '17d  Export-FltConfig' $_.Exception.Message }

    # 7c. Test-FleetTargetVerify — verify a target against tcpkg config
    if ($Target) {
        try {
            $ok = Test-FleetTargetVerify -Name $Target.Name
            # We can't know if it will pass, but it should not throw
            if ($ok) {
                _IT_Pass $r "17f  Test-FleetTargetVerify: '$($Target.Name)' verified OK in tcpkg config"
            } else {
                _IT_Warn $r "17f  Test-FleetTargetVerify: '$($Target.Name)' not verified" 'Target may not be registered in tcpkg — use Setup to add it'
            }
        } catch { _IT_Fail $r "17f  Test-FleetTargetVerify: '$($Target.Name)'" $_.Exception.Message }

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
                    _IT_Pass $r "17e  Set-FleetTargetInternetAccess: JSON updated to $newIA"
                } else {
                    _IT_Fail $r '17e  Set-FleetTargetInternetAccess: JSON updated' "Got $($reloaded.InternetAccess), expected $newIA"
                }
                # Restore
                Set-FleetTargetInternetAccess -Name $Target.Name -Value $origIA | Out-Null
                _IT_Pass $r "17e  Set-FleetTargetInternetAccess: restored to $origIA"
            } else {
                _IT_Warn $r "17e  Set-FleetTargetInternetAccess: '$($Target.Name)'" 'tcpkg edit failed — target may not be in tcpkg'
            }
        } catch {
            # Always try to restore
            try { Set-FleetTargetInternetAccess -Name $Target.Name -Value $Target.InternetAccess | Out-Null } catch {}
            _IT_Fail $r "17e  Set-FleetTargetInternetAccess: '$($Target.Name)'" $_.Exception.Message
        }
    } else {
        _IT_Warn $r '17f  Target-specific tcpkg tests' 'No target selected — toggle one with 21+'
    }

    # 7k. BatchResult.PackageManager field — verify the class has the field
    #     and that both executors set it correctly on their pscustomobject output
    try {
        $br = [BatchResult]::new()
        if ($null -ne $br.PSObject.Properties['PackageManager']) {
            _IT_Pass $r '17g  BatchResult class has PackageManager field'
            $br.PackageManager = 'tcpkg'
            if ($br.PackageManager -eq 'tcpkg') {
                _IT_Pass $r '17h  BatchResult.PackageManager: field is assignable and readable'
            } else {
                _IT_Fail $r '17h  BatchResult.PackageManager: assignable' "Got '$($br.PackageManager)'"
            }
        } else {
            _IT_Fail $r '17g  BatchResult class has PackageManager field' 'Field not found on class'
        }
    } catch { _IT_Fail $r '17i  BatchResult.PackageManager field' $_.Exception.Message }

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
            _IT_Pass $r "18a  Get-FltPackageList: found $($res.Items.Count) package(s) matching 'twincat.standard'"
        } elseif ($res.Ok) {
            _IT_Warn $r '18a  Get-FltPackageList: no results for twincat.standard' 'Check feed configuration'
        } else {
            _IT_Fail $r '18a  Get-FltPackageList' "tcpkg list failed — check tcpkg installation"
        }
    } catch { _IT_Fail $r '18a  Get-FltPackageList' $_.Exception.Message }

    # 8b. Get-FltPackageVersions — list versions of a known package
    try {
        $versions = @(Get-FltPackageVersions -PackageName 'twincat.standard.xae')
        if ($versions.Count -gt 0) {
            _IT_Pass $r "18b  Get-FltPackageVersions: $($versions.Count) version(s) of twincat.standard.xae"
        } else {
            _IT_Warn $r '18b  Get-FltPackageVersions: no versions found' 'Package may not be in any configured feed'
        }
    } catch { _IT_Fail $r '18b  Get-FltPackageVersions' $_.Exception.Message }

    # 8c. Get-FltInstalledIndex and Get-FltPackageStatus — build index then query
    if ($Target) {
        try {
            # Get-FltInstalledIndex calls tcpkg list -i -r <name> to get installed packages
            $idx = Get-FltInstalledIndex -RemoteName $Target.Name
            if ($idx -is [hashtable]) {
                _IT_Pass $r "18c  Get-FltInstalledIndex: built index for '$($Target.Name)' ($($idx.Count) packages)"

                # Get-FltPackageStatus compares installed version against a feed version
                $testPkg = 'twincat.standard.xae'
                $status  = Get-FltPackageStatus -PackageName $testPkg -InstalledIndex $idx
                if ($status -in @('not-installed','up-to-date','upgradable','newer-than-feed')) {
                    _IT_Pass $r "18c  Get-FltPackageStatus '$testPkg' on '$($Target.Name)': $status"
                } else {
                    _IT_Fail $r "18c  Get-FltPackageStatus '$testPkg'" "Unexpected status: '$status'"
                }
            } else {
                _IT_Fail $r "18c  Get-FltInstalledIndex: '$($Target.Name)'" "Got type: $($idx.GetType().Name)"
            }
        } catch { _IT_Fail $r "18c  Get-FltInstalledIndex/Status: '$($Target.Name)'" $_.Exception.Message }
    } else {
        _IT_Warn $r '18c  Get-FltInstalledIndex / Get-FltPackageStatus' 'No target selected — toggle one with 21+'
    }

    return $r
}



# Returns metadata about all available integration test suites.
# Used by the TestRunner to display the suite list.
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
                _IT_Pass $r '19a  Test-FltWinGetAvailable: winget found on operator machine'
            } else {
                _IT_Warn $r '19a  Test-FltWinGetAvailable: winget not found' 'Search/version tests will be skipped — install winget to enable'
            }
        } else {
            _IT_Fail $r '19a  Test-FltWinGetAvailable: result matches Get-Command' "avail=$avail found=$found"
        }
    } catch { _IT_Fail $r '19a  Test-FltWinGetAvailable' $_.Exception.Message }

    # 9b-9e. Executor routing — EffectivePackageManager() is a PS7 class method
    # that cannot be assigned to a variable. Use -in operator directly on the method
    # call in expression context instead.
    try {
        $t = [FleetTarget]::new('RouteTest-tcpkg','10.0.0.1',22,'admin',$true)
        $t.PackageManager = 'tcpkg'
        if ((Get-FltEffectivePackageManager $t) -eq 'tcpkg') {
            _IT_Pass $r "19b  Routing: PackageManager='tcpkg' → correct"
        } else {
            _IT_Fail $r "19b  Routing: tcpkg target Get-FltEffectivePackageManager" "Expected 'tcpkg', got '$(Get-FltEffectivePackageManager $t)'"
        }
    } catch { _IT_Fail $r '19b  Routing: tcpkg target' $_.Exception.Message }

    try {
        $t = [FleetTarget]::new('RouteTest-winget','10.0.0.2',22,'admin',$true)
        $t.PackageManager = 'winget'
        if ((Get-FltEffectivePackageManager $t) -eq 'winget') {
            _IT_Pass $r "19b  Routing: PackageManager='winget' → correct"
        } else {
            _IT_Fail $r "19b  Routing: winget target Get-FltEffectivePackageManager" "Expected 'winget'"
        }
    } catch { _IT_Fail $r '19b  Routing: winget target' $_.Exception.Message }

    try {
        $t = [FleetTarget]::new('RouteTest-default','10.0.0.3',22,'admin',$true)
        $t.PackageManager = ''
        $t.OS = 'windows'
        if ((Get-FltEffectivePackageManager $t) -eq 'tcpkg') {
            _IT_Pass $r "19b  Routing: PackageManager='' defaults to 'tcpkg'"
        } else {
            _IT_Fail $r "19b  Routing: default Windows target Get-FltEffectivePackageManager" "Expected 'tcpkg'"
        }
    } catch { _IT_Fail $r '19b  Routing: default Windows target' $_.Exception.Message }

    try {
        $t = [FleetTarget]::new('RouteTest-both','10.0.0.4',22,'admin',$true)
        $t.PackageManager = 'both'
        if ((Get-FltEffectivePackageManager $t) -eq 'both') {
            _IT_Pass $r "19b  Routing: PackageManager='both' → correct"
        } else {
            _IT_Fail $r "19b  Routing: 'both' target Get-FltEffectivePackageManager" "Expected 'both'"
        }
    } catch { _IT_Fail $r "19b  Routing: 'both' target" $_.Exception.Message }

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
            _IT_Pass $r '19c  _Get-WinGetCommand: correct format'
        } else {
            _IT_Fail $r '19c  _Get-WinGetCommand: command format' ($errors -join '; ')
        }
    } catch { _IT_Fail $r '19c  _Get-WinGetCommand' $_.Exception.Message }

    # 9g. Search-FltWinGetPackage — requires winget on operator machine
    if (Test-FltWinGetAvailable) {
        try {
            $res = Search-FltWinGetPackage -SearchTerm 'notepad'
            if ($res.Ok -and $res.Items.Count -gt 0) {
                _IT_Pass $r "19d  Search-FltWinGetPackage: found $($res.Items.Count) result(s) for 'notepad'"
                # Verify shape matches tcpkg equivalent
                $first = $res.Items[0]
                $hasName    = $null -ne $first.Name
                $hasVersion = $null -ne $first.PSObject.Properties['Version']
                $hasSource  = $null -ne $first.PSObject.Properties['Source']
                if ($hasName -and $hasVersion -and $hasSource) {
                    _IT_Pass $r '19d  Search-FltWinGetPackage: result shape'
                } else {
                    _IT_Fail $r '19d  Search-FltWinGetPackage: result shape' "Name=$hasName Version=$hasVersion Source=$hasSource"
                }
            } elseif ($res.Ok) {
                _IT_Warn $r "19d  Search-FltWinGetPackage: no results for 'notepad'" 'Check winget source configuration'
            } else {
                # Capture raw winget output for diagnosis
                $rawDiag = & winget search notepad --accept-source-agreements 2>&1
                $exitDiag = $LASTEXITCODE
                $preview  = ($rawDiag | Select-Object -First 3 | ForEach-Object { [string]$_ }) -join ' | '
                _IT_Fail $r "19d  Search-FltWinGetPackage: search succeeded" "exit=$exitDiag raw='$preview'"
            }
        } catch { _IT_Fail $r '19d  Search-FltWinGetPackage' $_.Exception.Message }

        # 9h. Get-FltWinGetVersions — search for a well-known package
        try {
            $versions = @(Get-FltWinGetVersions -PackageId '7zip.7zip')
            if ($versions.Count -gt 0) {
                _IT_Pass $r "19e  Get-FltWinGetVersions: $($versions.Count) version(s) of 7zip.7zip"
                if ($versions[0].PSObject.Properties['Version'] -and $versions[0].PSObject.Properties['Source']) {
                    _IT_Pass $r '19e  Get-FltWinGetVersions: result shape'
                } else {
                    _IT_Fail $r '19e  Get-FltWinGetVersions: result shape' 'Missing Version or Source property'
                }
            } else {
                _IT_Warn $r '19e  Get-FltWinGetVersions: versions found' 'No versions for 7zip.7zip — check winget source configuration'
            }
        } catch { _IT_Fail $r '19e  Get-FltWinGetVersions' $_.Exception.Message }
    } else {
        _IT_Warn $r '19d  Search-FltWinGetPackage'    'winget not on operator machine — skipped'
        _IT_Warn $r '19e  Get-FltWinGetVersions'      'winget not on operator machine — skipped'
    }

    # 9i. Get-FltWinGetInstalledIndex — requires winget on operator machine
    if (Test-FltWinGetAvailable) {
        try {
            $idx = Get-FltWinGetInstalledIndex
            if ($idx -is [hashtable]) {
                _IT_Pass $r "19f  Get-FltWinGetInstalledIndex: returns hashtable ($($idx.Count) packages)"
                # Keys must be lowercase package ids
                $hasUpperCase = $idx.Keys | Where-Object { $_ -cne $_.ToLower() }
                if (-not $hasUpperCase) {
                    _IT_Pass $r '19f  Get-FltWinGetInstalledIndex: all keys are lowercase'
                } else {
                    _IT_Fail $r '19f  Get-FltWinGetInstalledIndex: keys lowercase' "Found mixed-case keys: $($hasUpperCase -join ', ')"
                }
            } else {
                _IT_Fail $r '19f  Get-FltWinGetInstalledIndex: returns hashtable' "Got: $($idx.GetType().Name)"
            }
        } catch { _IT_Fail $r '19f  Get-FltWinGetInstalledIndex' $_.Exception.Message }
    } else {
        _IT_Warn $r '19f  Get-FltWinGetInstalledIndex' 'winget not on operator machine — skipped'
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
            _IT_Pass $r '19g  Routing: winget target with IA=False routes to push'
        } else {
            _IT_Fail $r '19g  Routing: winget target with IA=False routes to push' "goesWinGet=$goesWinGet goesPush=$goesPush"
        }
    } catch { _IT_Fail $r '19g  Routing: IA=False winget target' $_.Exception.Message }

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
        if (-not $searchResult.Ok)                                          { _IT_Fail $r '19g  _Parse-WinGetTable search: parse succeeded' 'Ok=false' }
        elseif ($searchResult.Items.Count -ne 3)                            { _IT_Fail $r '19h  _Parse-WinGetTable search: item count' "Expected 3 got $($searchResult.Items.Count)" }
        elseif ($searchResult.Items[0].Name -ne 'Notepad++.Notepad++')     { _IT_Fail $r '19h  _Parse-WinGetTable search: Id extracted as Name' "Got '$($searchResult.Items[0].Name)'" }
        elseif ($searchResult.Items[0].Title -ne 'Notepad++')              { _IT_Fail $r '19h  _Parse-WinGetTable search: display name in Title' "Got '$($searchResult.Items[0].Title)'" }
        elseif ($searchResult.Items[0].Version -ne '8.9.6.4')              { _IT_Fail $r '19h  _Parse-WinGetTable search: version' "Got '$($searchResult.Items[0].Version)'" }
        else { _IT_Pass $r '19h  _Parse-WinGetTable search format' }

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
        if (-not $listResult.Ok)                                             { _IT_Fail $r '19i  _Parse-WinGetTable list: parse succeeded' 'Ok=false' }
        elseif ($listResult.Items.Count -ne 6)                              { _IT_Fail $r '19i  _Parse-WinGetTable list: item count' "Expected 6 got $($listResult.Items.Count)" }
        else {
            $xmlNotepad = $listResult.Items | Where-Object { $_.Name -eq 'Microsoft.XMLNotepad' } | Select-Object -First 1
            $openSsh    = $listResult.Items | Where-Object { $_.Name -eq 'Microsoft.OpenSSH.Preview' } | Select-Object -First 1
            $runtime    = $listResult.Items | Where-Object { $_.Name -eq 'Microsoft.WindowsAppRuntime.1.8' } | Select-Object -First 1

            if (-not $xmlNotepad)                           { _IT_Fail $r '19i  _Parse-WinGetTable list: XmlNotepad found'    "Id not found in results: $($listResult.Items.Name -join ', ')" }
            elseif ($xmlNotepad.Title -ne 'XmlNotepad')    { _IT_Fail $r '19i  _Parse-WinGetTable list: XmlNotepad title'    "Got '$($xmlNotepad.Title)'" }
            elseif ($xmlNotepad.Version -ne '2.9.0.22')    { _IT_Fail $r '19i  _Parse-WinGetTable list: XmlNotepad version'  "Got '$($xmlNotepad.Version)'" }
            elseif (-not $openSsh)                          { _IT_Fail $r '19i  _Parse-WinGetTable list: OpenSSH found'       'Id not found' }
            elseif ($openSsh.Version -ne '9.5.0.0')        { _IT_Fail $r '19i  _Parse-WinGetTable list: OpenSSH version'     "Got '$($openSsh.Version)'" }
            elseif (-not $runtime)                          { _IT_Fail $r '19i  _Parse-WinGetTable list: WindowsAppRuntime found' 'Id not found' }
            elseif ($runtime.Version -ne '1.8.0')          { _IT_Fail $r '19i  _Parse-WinGetTable list: WindowsAppRuntime version' "Got '$($runtime.Version)'" }
            else { _IT_Pass $r '19j  _Parse-WinGetTable list format: all packages correctly parsed' }
        }
    } catch { _IT_Fail $r '19k  _Parse-WinGetTable' $_.Exception.Message }

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
        _IT_Fail $r '20a  Posh-SSH available' 'Run: Install-Module Posh-SSH -Scope CurrentUser'
        _IT_Skip $r '20b  Credentials provided'                     'Skipped — Posh-SSH not available'
        _IT_Skip $r '20c  SSH session for pre-check'                 'Skipped — Posh-SSH not available'
        _IT_Skip $r '20d  winget installed on target'                'Skipped — Posh-SSH not available'
        _IT_Skip $r '20e  winget sources configured on target'       'Skipped — Posh-SSH not available'
        _IT_Skip $r '20f  winget sources refreshed'                  'Skipped — Posh-SSH not available'
        _IT_Skip $r '20g  Invoke-FltWinGetBatch (already installed)' 'Skipped — Posh-SSH not available'
        _IT_Skip $r '20h  Verify install via SSH'                    'Skipped — Posh-SSH not available'
        _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — Posh-SSH not available'
        _IT_Skip $r '20c  SSH session for pre-check'                 'Skipped — no credentials provided'
        _IT_Skip $r '20d  winget installed on target'                'Skipped — no credentials provided'
        _IT_Skip $r '20e  winget sources configured on target'       'Skipped — no credentials provided'
        _IT_Skip $r '20f  winget sources refreshed'                  'Skipped — no credentials provided'
        _IT_Skip $r '20g  Invoke-FltWinGetBatch (already installed)' 'Skipped — no credentials provided'
        _IT_Skip $r '20h  Verify install via SSH'                    'Skipped — no credentials provided'
        _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — no credentials provided'
        return $r
    }
    if (-not $Credential -and [string]::IsNullOrWhiteSpace($KeyFile)) {
        _IT_Fail $r '20b  Credentials provided' 'Select credentials before running this suite'
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
            _IT_Fail $r '20c  SSH session for pre-check' 'New-SSHSession returned null'
            _IT_Skip $r '20d  winget installed on target'                'Skipped — SSH session failed'
            _IT_Skip $r '20e  winget sources configured on target'       'Skipped — SSH session failed'
            _IT_Skip $r '20f  winget sources refreshed'                  'Skipped — SSH session failed'
            _IT_Skip $r '20g  Invoke-FltWinGetBatch (already installed)' 'Skipped — SSH session failed'
            _IT_Skip $r '20h  Verify install via SSH'                    'Skipped — SSH session failed'
            _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — SSH session failed'
            return $r
        }

        # Pre-check A: winget installed and callable
        $verResult = Invoke-SSHCommand -SessionId $session.SessionId `
                         -Command 'winget --version' -TimeOut 30
        $verOut    = ($verResult.Output -join '').Trim()
        if ($verResult.ExitStatus -eq 0 -and $verOut -match 'v\d') {
            _IT_Pass $r "20d  winget installed on target: $verOut"
        } else {
            _IT_Fail $r '20d  winget installed on target' `
                "exit=$($verResult.ExitStatus) output='$verOut' — use Setup > select target > 4. Prepare target to install WinGet"
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
            _IT_Skip $r '20e  winget sources configured on target'       'Skipped — winget not installed on target'
            _IT_Skip $r '20f  winget sources refreshed'                  'Skipped — winget not installed on target'
            _IT_Skip $r '20g  Invoke-FltWinGetBatch (already installed)' 'Skipped — winget not installed on target'
            _IT_Skip $r '20h  Verify install via SSH'                    'Skipped — winget not installed on target'
            _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — winget not installed on target'
            return $r
        }

        # Pre-check B: winget sources configured
        $srcResult = Invoke-SSHCommand -SessionId $session.SessionId `
                         -Command 'winget source list' -TimeOut 30
        $srcOut    = ($srcResult.Output -join ' ')
        if ($srcResult.ExitStatus -eq 0 -and $srcOut -match 'https://') {
            $srcCount = @($srcResult.Output | Where-Object { $_ -match 'https://' }).Count
            _IT_Pass $r "20e  winget sources configured on target ($srcCount source(s))"
        } else {
            _IT_Fail $r '20e  winget sources configured on target' `
                "exit=$($srcResult.ExitStatus) — run 'winget source reset --force' on target"
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
            _IT_Skip $r '20f  winget sources refreshed'                  'Skipped — winget sources not configured'
            _IT_Skip $r '20g  Invoke-FltWinGetBatch (already installed)' 'Skipped — winget sources not configured'
            _IT_Skip $r '20h  Verify install via SSH'                    'Skipped — winget sources not configured'
            _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — winget sources not configured'
            return $r
        }

        # Pre-check C: refresh sources so install doesn't use stale cache
        $updateResult = Invoke-SSHCommand -SessionId $session.SessionId `
                            -Command 'winget source update --disable-interactivity' -TimeOut 60
        if ($updateResult.ExitStatus -eq 0) {
            _IT_Pass $r '20f  winget sources refreshed'
        } else {
            _IT_Warn $r '20f  winget sources refreshed' `
                "exit=$($updateResult.ExitStatus) — install may use cached source data"
        }

        # Pre-check D: check if test package already installed
        $checkCmd = "winget list --id $testPkg --accept-source-agreements --disable-interactivity 2>&1"
        $check    = Invoke-SSHCommand -SessionId $session.SessionId -Command $checkCmd -TimeOut 60
        $checkOut = ($check.Output -join ' ')
        $alreadyInstalled = $checkOut -match [regex]::Escape($testPkg)
        Remove-SSHSession -SessionId $session.SessionId | Out-Null

        if ($alreadyInstalled) {
            _IT_Pass $r "20g  $testPkg pre-check: already installed on target"
        } else {
            _IT_Pass $r "20g  $testPkg pre-check: not installed on target — will install and remove"
        }
    } catch {
        _IT_Fail $r "20c  Pre-check SSH: $($Target.Name)" $_.Exception.Message
        _IT_Skip $r '20d  winget installed on target'                'Skipped — SSH pre-check threw exception'
        _IT_Skip $r '20e  winget sources configured on target'       'Skipped — SSH pre-check threw exception'
        _IT_Skip $r '20f  winget sources refreshed'                  'Skipped — SSH pre-check threw exception'
        _IT_Skip $r '20g  Invoke-FltWinGetBatch (already installed)' 'Skipped — SSH pre-check threw exception'
        _IT_Skip $r '20h  Verify install via SSH'                    'Skipped — SSH pre-check threw exception'
        _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — SSH pre-check threw exception'
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
                _IT_Pass $r "20g  Install when already installed → Skipped (Already installed)"
            } elseif ($res) {
                _IT_Fail $r "20g  Install when already installed → Skipped" "Got Status='$($res.Status)' Note='$($res.Note)'"
            } else {
                _IT_Fail $r "20h  Install result returned" "No result for $($Target.Name)"
            }
        } catch {
            _IT_Fail $r '20g  Invoke-FltWinGetBatch (already installed)' $_.Exception.Message
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
                _IT_Pass $r "20h  Install ${testPkg}: OK ($([Math]::Round($instRes.DurationSec,1))s)"
            } else {
                $status = if ($instRes) { $instRes.Status } else { 'no result' }
                _IT_Fail $r "20h  Install $testPkg" "Status='$status'"
                _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — install failed'
                return $r   # skip uninstall if install failed
            }
        } catch {
            _IT_Fail $r "20h  Invoke-FltWinGetBatch install" $_.Exception.Message
            _IT_Skip $r '20i  Verify removal via SSH'                    'Skipped — install threw exception'
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
                _IT_Pass $r "20h  Verify installed: $testPkg found in remote winget list"
            } else {
                _IT_Fail $r "20h  Verify installed: $testPkg in winget list" "Not found — output: $($verOut[0..120] -join '')"
            }
        } catch {
            _IT_Fail $r '20h  Verify install via SSH' $_.Exception.Message
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
                _IT_Pass $r "20i  Uninstall ${testPkg}: OK ($([Math]::Round($uninstRes.DurationSec,1))s)"
            } else {
                $status = if ($uninstRes) { $uninstRes.Status } else { 'no result' }
                _IT_Fail $r "20i  Uninstall $testPkg" "Status='$status' — manual cleanup may be needed"
            }
        } catch {
            _IT_Fail $r "20i  Invoke-FltWinGetBatch uninstall" $_.Exception.Message
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
                _IT_Pass $r "20i  Verify removed: $testPkg no longer in remote winget list"
            } else {
                _IT_Fail $r "20i  Verify removed: $testPkg still in winget list" 'Manual uninstall may be needed'
            }
        } catch {
            _IT_Fail $r '20i  Verify removal via SSH' $_.Exception.Message
        }
    }

    return $r
}

# ── Suite 11 — Ansible availability ───────────────────────────────────────────

# Tests Ansible availability checks in AnsibleRepository.ps1.
# All checks WARN and skip gracefully if Ansible is not installed —
# these are operator-machine checks with no SSH or target required.