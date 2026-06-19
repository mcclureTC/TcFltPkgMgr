# TcFltPkgMgr — Test Procedure

**Location:** Setup → 10 → Test Runner  
**Input scheme:** `1` all diagnostics · `9` all integration · `11`–`99` specific suite · `101+` toggle targets · `00` clear results · `0` back  
**Result history:** saved to `config/test-results.json` between sessions

---

## Diagnostic Tests

Run from the test runner with `1`. No network, SSH, or tcpkg calls. All 29 tests run offline against the local tool state.

### Section D1 — Display adapter (Phase 0-A.1)

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 1 | Display adapter delegates correctly | The display adapter wiring from `Show-FleetDashboard` → `$Script:FltDisplay_ShowFleetDashboard` → `_Ansi_ShowFleetDashboard` works end-to-end | Calls `Get-FltSafeWidth` which traverses the full adapter chain. Checks return value is a positive integer. |
| 2 | All `_Ansi_` backend functions defined at script scope | All 10 ANSI backend functions are dot-sourced at script scope, not trapped in a function scope where they would be invisible after the function returns | Checks that each of the 10 `_Ansi_*` functions is retrievable by `Get-Command` |

### Section D2 — Credential adapter (Phase 0-A.2)

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 3 | Credential round-trip OK | The full Set → Get → Remove cycle using the active backend (DPAPI on Windows, AES-256 file on Linux) | Stores a random password under a random key, reads it back, verifies the value matches, removes it, verifies it is gone. Uses a real random key to avoid collision with real credentials. |
| 4 | Resolve-FltPassword returns stored credential without prompting | `Resolve-FltPassword -Silent` retrieves a stored credential without showing a console prompt | Stores a credential, calls `Resolve-FltPassword` with `-Silent`, checks the returned value matches without any interactive prompt. |
| 5 | Config directory is writable | The `config/` directory accepts file writes | Creates a temp file, writes to it, deletes it. Failures here cause silent credential save failures. |

### Section D3 — Platform and feature gating (Phase 0-A.3)

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 6 | OS detected | `$Script:FltOS` is set to a known value at startup | Checks the value is one of `windows`, `linux`, `macos` and not empty or `unknown` |
| 7 | Feature gating correct for OS | `Test-FltFeatureAvailable` returns correct values per platform | Checks that `posh-ssh` returns `$true` on all platforms, unknown features default to `$true`, and `tcpkg-local` is `$true` on Windows and `$false` on Linux/macOS |

### Section D4 — Core subsystems

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 8 | `ConvertFrom-FltTcpkgJson`: parses JSON correctly | JSON array parsing from tcpkg output | Passes a known JSON string, checks the parsed object has correct field values |
| 9 | `ConvertFrom-FltTcpkgJson`: filters tcpkg version banner | The version banner tcpkg always writes to stderr (as `ErrorRecord`) is stripped before JSON parsing | Passes a mixed array of `ErrorRecord` + JSON string, verifies only JSON is parsed |
| 10 | Config values loaded | Critical config values are loaded from `settings.default.json` with correct defaults | Reads `ssh.timeoutSeconds`, `ssh.throttleLimit`, `tcpkg.remoteTcpkgPath`, and a non-existent key — verifies each matches expected type and sentinel |
| 11 | Feed list loaded | `$Script:FltFeeds` is populated with at least one feed on startup | Checks the count is greater than zero. WARN (not FAIL) if empty, since the tool still works without feeds for SSH-only installs. |
| 12 | Log directory writable | The `logs/` directory accepts file writes | Creates and deletes a temp file in the log directory |
| 13 | `Invoke-FltWithStdin`: exit codes correct | The process-spawning function used for all tcpkg password-piping operations correctly captures exit codes | Spawns `pwsh -Command 'exit 0'` and `pwsh -Command 'exit 1'`, verifies exit codes 0 and 1 are returned respectively |
| 14 | `FleetTarget`: fields and mutation correct | `FleetTarget` constructor sets all fields correctly and fields are mutable | Constructs a `FleetTarget`, checks all five constructor fields, then mutates `Reachable` and checks the new value |
| 15 | `_Save-UiCfgValue` round-trip | `_Save-UiCfgValue` updates `$Script:FltCfg` in memory immediately | Sets `dashboardPageSize` to 99, reads it back with `Get-FltCfgValue`, verifies the value is 99. Restores original value. |
| 16 | `_Save-UiCfgValue` wrote to `settings.local.json` | `_Save-UiCfgValue` persists the change to disk | Reads `settings.local.json` after the write and checks the value matches |
| 17 | Pagination math correct | Page slicing logic produces correct target slices | Creates 7 fake targets, slices them with page size 3, checks page 0 (items 1-3), page 1 (items 4-6), page 2 (item 7), and total page count |
| 18 | Throttle limits in safe range | `ssh.throttleLimit` and `docker.throttleLimit` are within 1-50 | Reads both values from config and checks bounds. Values above 50 risk TCP connection pool exhaustion. |
| 19 | `Start-FltReachJob` creates parallel background job | `Start-FltReachJob -IgnoreCache` creates a `ThreadJob` that can be stopped | Creates a job targeting `127.0.0.1`, verifies job ID is positive, stops and removes it immediately |
| 20 | Reachability cache: offline targets always rechecked | An online target within cache window is skipped; an offline target is always rechecked | Creates one online/cached target and one offline target, calls `Start-FltReachJob` without `-IgnoreCache`, verifies a job is created (offline target causes recheck) |
| 21 | Posh-SSH module available | Posh-SSH is installed and importable | Calls `Ensure-FltPoshSsh` which installs/imports the module. FAIL with install instructions if missing. |
| 22 | All 39 required functions loaded | All public functions in the module loaded successfully | Checks each of 39 named functions is accessible via `Get-Command` |

### Section D5 — Target store and sort/filter (Phase 0.3)

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 23 | `New-FltSortFilterState` returns correct default shape | Sort/filter state hashtable has correct keys and defaults | Checks all four keys exist (`SortColumn`, `SortDesc`, `FilterColumn`, `FilterValue`) and defaults are `''`, `$false`, `''`, `''` |
| 24 | `Invoke-FltSort`: ascending and descending by Name correct | Sort produces correct order in both directions | Sorts `['Zebra','Alpha','Mango']` ascending and descending, checks first and last elements |
| 25 | `Invoke-FltFilter`: filters to matching items only | Filter returns only items where the column contains the value | Filters three items by `Reachable='online'`, checks exactly one item returned |
| 26 | `Get-FltSortHeader`: correct indicators for active/inactive/asc/desc | Column headers show `▲`/`▼` when the column is the active sort, plain text otherwise | Checks `'Target ▲'` for ascending, `'Target ▼'` for descending, `'Address'` (plain) for an inactive column |
| 27 | `Get-FltTargetStorePath`: path in config dir | Returns the correct path for `targets.local.json` | Verifies the path starts with `$Script:FltConfigDir` and ends with `targets.local.json` |
| 28 | `FleetTarget` serialization round-trip | `_Target-ToHashtable` → `_Target-FromHashtable` preserves all fields including Phase 1 extensions | Creates a target with `OS='linux'`, `TargetType='vm'`, `PackageManager='apt'`, serializes and deserializes, checks all six fields |
| 29 | Target JSON store round-trip | Save and reload via JSON produces correct `FleetTarget` objects | Writes two targets to a temp file, reads them back via `ConvertFrom-Json` + `_Target-FromHashtable`, checks names and `InternetAccess` values |

### Section D6 — Reachability (Phase 0.4)

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 30 | `Start-FltReachJob` creates parallel background job | `Start-FltReachJob -IgnoreCache` returns a valid job — same as D4 test 19, but tracked separately | Duplicate of D4-19 tracked under Phase 0.4 section |
| 31 | Reachability cache: offline targets always rechecked | Duplicate of D4-20 tracked under Phase 0.4 section | Duplicate of D4-20 |

### Section D7 — Required functions loaded

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 32 | All 39 required functions loaded | All named public functions in the module are accessible | Duplicate of D4-22 tracked as a standalone check |

---

## Integration Tests

Run from the test runner with `9` (all) or `11`–`99` (individual suite). Suites marked **[needs target]** require at least one target toggled on with `101+`. All suites are safe to run multiple times — they restore any state they change.

---

### Suite 11 — File I/O

**Infrastructure required:** None  
**Per target:** No (runs once)

Tests that require no network or tcpkg. Exercises the local file system, config system, and sort/filter logic.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 1a | CSV export: correct target count | `Export-FleetTargetsCsv` writes the correct number of rows | Exports to a temp CSV, checks the returned count matches `$Script:FleetTargets.Count` |
| 1b | CSV round-trip: temp-remove target | `Save-FltTargets` writes JSON without the removed target | Removes first target from JSON, reloads, checks target is absent |
| 1c | CSV round-trip: target restored | `Save-FltTargets` restores target to JSON | Adds target back, reloads, checks target is present again. Reloads `$Script:FleetTargets`. |
| 1d | Sort persists across reload | Sort order written to `targets.local.json` survives a reload | Sorts targets by Name ascending, saves, reloads via `Get-FleetTargets`, compares name order |
| 1e | Filter by Name returns correct result | `Invoke-FltFilter` returns items that match the filter value | Filters by first target's name, checks at least one result returned and the target is in results |
| 1f | Filter by non-existent value returns empty set | `Invoke-FltFilter` returns empty when nothing matches | Filters by `'ZZZNOMATCH999'`, checks count is zero |
| 1g | `_Save-UiCfgValue` page size persists | UI Config changes survive to `settings.local.json` | Sets page size to 17, reads back via `Get-FltCfgValue`, checks value, reads `settings.local.json` directly. Restores original. |
| 1h | `Merge-Hashtable` deep merge correct | Deep merge: base values kept for missing override keys, override values win for present keys | Merges two nested hashtables with overlapping and distinct keys, checks five specific values |
| 1i | `ConvertTo-Hashtable` nested object and array | `PSCustomObject` graph from `ConvertFrom-Json` converts to nested hashtable | Converts a JSON string with nested object and array, checks types and values |
| 1j | `Read-FltJsonConfig` default+local merge | Settings.local.json overrides settings.default.json at the key level | Creates two temp JSON files, merges them, checks three keys: overridden, kept, and local-only |
| 1k | `Get-FltFilterStatus` active filter string | Returns correct status string when filter is active | Sets `FilterColumn='Reachable'`, `FilterValue='online'`, calls with totals 7→4, checks result contains column name, value, and both counts |
| 1l | `Get-FltFilterStatus` empty when no filter | Returns empty string when no filter is set | Calls with empty state, checks result is null or empty |
| 1m | Profile save/load round-trip | `Save-FltProfiles` and `Read-FltProfiles` correctly persist and reload fleet profiles | Creates a test profile with two target names and one package, saves alongside existing profiles, reloads, verifies the profile exists with correct counts. Restores originals. |

---

### Suite 12 — Pagination and target selection

**Infrastructure required:** None  
**Per target:** No (runs once)

Tests that page slicing is correct and target selection respects sort/filter order.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 2a | Page 0 slice correct | `Select-Object -Skip 0 -First $PageSize` returns the correct number of targets | Checks count equals `Min(pageSize, n)` |
| 2b | Target 11 maps to first target | Global target number 11 always means index 0 in the display list | Checks `$Script:FleetTargets[11 - 11].Name` equals the first target's name |
| 2c | Sort changes target 11 | After sorting descending, target 11 maps to a different target | Sorts by Name descending, checks first target name changed (if targets have distinct names) |
| 2d | Total pages calculation | `Math.Ceiling(n / pageSize)` produces the correct page count | Checks total pages matches expected value |

---

### Suite 13 — SSH connectivity `[needs target]`

**Infrastructure required:** Online target, SSH credentials  
**Per target:** Yes (runs against each selected target)

Tests that Posh-SSH can establish a session and run commands on a real target.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 3a | TCP port reachable | Target's SSH port accepts a TCP connection within 3 seconds | Opens a `TcpClient` to the target's configured address and port |
| 3b | SSH session opens | Posh-SSH can authenticate and open a session | Calls `New-SSHSession` with the provided credential, checks session ID is returned |
| 3c | SSH command executes correctly | An SSH command runs and returns output | Runs `echo IT_SSH_OK`, checks output equals `IT_SSH_OK` and exit status is 0 |
| 3d | Remote tcpkg found at configured path | The `tcpkg.remoteTcpkgPath` setting points to tcpkg on the target | Runs `if exist "<path>" echo FOUND` on the target, checks output contains FOUND. WARN if missing (path may differ). |

---

### Suite 14 — Read-only mode

**Infrastructure required:** None  
**Per target:** No (runs once)

Tests that read-only mode blocks tcpkg execution without crashing the tool.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 4a | `Invoke-FltTcpkg` blocked in read-only | `Invoke-FltTcpkg` returns null and exit code 0 (simulated) when `$Script:FltReadOnly = $true` | Sets `FltReadOnly = $true`, calls `Invoke-FltTcpkg`, checks raw output is null and `FltLastExit` is 0. Restores flag. |
| 4b | Batch status shows `[read-only]` prefix | Batch operations produce a `[read-only] would SSH` status string | Checks that the status string contains `read-only`. No actual SSH call is made. |
| 4c | Credential store writable in read-only | Credentials are exempt from read-only mode — the operator must still be able to store credentials | Stores, retrieves, and removes a test credential while `FltReadOnly = $true`, checks the value round-trips correctly |

---

### Suite 15 — Log system

**Infrastructure required:** None  
**Per target:** No (runs once)

Tests that the NDJSON log is written, readable, and maintained correctly.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 5a | Log directory exists | `$Script:FltLogDir` path exists on disk | Calls `Test-Path $Script:FltLogDir` |
| 5b | Log entry written and retrieved | `Start-FltCommandEntry` + `Complete-FltCommandEntry` write an entry that `Get-FltCommandHistory` can find | Creates a unique command string, writes it, reads command history filtered by that string, checks it is found |
| 5c | Today's log file exists | A log file for today's date exists after writing | Calls `Get-FltLogPath` and checks file exists |
| 5d | Log retention preserves current log | `Invoke-FltLogRetention` does not delete today's log file | Runs retention, checks today's log still exists |
| 5e | `Write-FltFleetQueryEntry` writes fleet_query event | Fleet package query results are written to the log as `fleet_query` events | Creates a `FleetPackageSummary`, calls `Write-FltFleetQueryEntry`, reads raw log and checks for `fleet_query` + package name |
| 5f | `Show-FltCommandLog` renders without error | The log viewer renders to console without throwing | Calls `Show-FltCommandLog -LastDays 1`, pipes to `Out-Null`, checks no exception |

---

### Suite 16 — Reachability cache

**Infrastructure required:** None (optional: online target for live check)  
**Per target:** Yes (live check runs per selected target; local logic runs once per target call but tests the same values)

Tests that the reachability cache correctly skips online targets and rechecks offline/expired ones.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 6a | Reachability cache initialized empty | A fresh `@{}` cache has zero entries | Checks `$Script:FltReachCache.Count -eq 0` after reset |
| 6b | Cached online target skipped within window | `Start-FltReachJob` returns null when a target is cached online within `reachCacheSecs` | Adds target to cache with `UtcNow` timestamp, calls `Start-FltReachJob` without `-IgnoreCache`, checks job is null |
| 6c | Expired cache entry triggers recheck | `Start-FltReachJob` creates a job when the cache entry is older than `reachCacheSecs` | Sets cache timestamp to `UtcNow - (reachCacheSecs + 5)`, calls `Start-FltReachJob`, checks job is not null |
| 6d | Live cache populated after check _(optional)_ | `Receive-FltReachJob` updates `$Script:FltReachCache` for online targets | Creates a real job against the selected target, waits for completion, calls `Receive-FltReachJob`, checks cache contains target name. WARN (not FAIL) if target is offline. |

---

### Suite 17 — tcpkg local

**Infrastructure required:** tcpkg installed locally (as command or at configured path)  
**Per target:** Yes (verify and internet access tests run per selected target)

Tests local tcpkg integration: executable discovery, config export, and target management.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 7a | tcpkg executable found | `Get-FltTcpkgExe` returns a path where tcpkg is callable | Checks `Test-Path` for absolute paths, falls back to `Get-Command` for PATH-resolved names. WARN (not FAIL) if not found. |
| 7b | `Export-FltConfig` archive created | `Export-FltConfig` creates a ZIP archive of `feeds.local.json`, `settings.local.json`, and `profiles.json` | Creates a temp ZIP path, calls `Export-FltConfig -DestinationPath`, checks file exists and has non-zero size. Removes temp file. |
| 7c | `Test-FleetTargetVerify` _(per target)_ | `tcpkg remote verify` exits 0 for a registered target | Calls `Test-FleetTargetVerify -Name $target.Name`, checks exit code. WARN (not FAIL) if target is not registered. |
| 7d | `Set-FleetTargetInternetAccess` toggle _(per target)_ | Toggling Internet Access updates both tcpkg config and `targets.local.json` | Reads current `InternetAccess`, sets it to opposite value, reloads target from JSON, checks new value matches, restores original. |

| 7k | `BatchResult.PackageManager` field | `BatchResult` class has `PackageManager` field and it is assignable | Creates `[BatchResult]::new()`, checks `PSObject.Properties['PackageManager']` exists, assigns `'tcpkg'`, reads back and verifies |

---

### Suite 18 — Package queries

**Infrastructure required:** tcpkg installed locally with at least one feed configured; online target for remote index  
**Per target:** Yes (installed index query runs per selected target)

Tests local package search and remote package status queries. All are read-only — no installs.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 8a | `Get-FltPackageList` returns results | `tcpkg list twincat.standard` returns at least one package | Calls `Get-FltPackageList -ListArgs @('list','twincat.standard')`, checks `$res.Ok` and `$res.Items.Count -gt 0`. WARN if no results (feed may be missing). |
| 8b | `Get-FltPackageVersions` returns versions | `tcpkg list -a twincat.standard.xae` returns at least one version | Calls `Get-FltPackageVersions -PackageName 'twincat.standard.xae'`, checks count. WARN if none found. |
| 8c | `Get-FltInstalledIndex` builds correct index _(per target)_ | `tcpkg list -i -r <name>` returns installed packages as a hashtable | Calls `Get-FltInstalledIndex -RemoteName $target.Name`, checks return is a hashtable |
| 8d | `Get-FltPackageStatus` returns valid status _(per target)_ | Comparing installed index against a known package name returns a valid status string | Calls `Get-FltPackageStatus -PackageName 'twincat.standard.xae' -InstalledIndex $idx`, checks result is one of `not-installed`, `up-to-date`, `upgradable`, `newer-than-feed` |

---

### Suite 19 — WinGet executor

**Infrastructure required:** `winget` installed on operator machine (for search/version tests); online target with `winget` for live tests  
**Per target:** No (routing logic and search are local; live install is suite 20)  
**Check count:** 15 (9a–9k; 9g/9h/9i WARN if winget not on operator machine)

Tests WinGet availability, executor routing logic, local package search, and version listing.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 9a | `Test-FltWinGetAvailable` reports correctly | Returns `$true` when winget is on PATH, `$false` when not | Compares `Test-FltWinGetAvailable` result against `Get-Command winget`. WARN (not FAIL) if not found — search tests are skipped. |
| 9b | Routing: tcpkg target | `Get-FltEffectivePackageManager` returns `'tcpkg'` for a target with `PackageManager='tcpkg'` | Creates synthetic `FleetTarget`, calls `Get-FltEffectivePackageManager`, checks result |
| 9c | Routing: winget target | `Get-FltEffectivePackageManager` returns `'winget'` for a target with `PackageManager='winget'` | Creates synthetic `FleetTarget`, calls function, checks result |
| 9d | Routing: blank defaults to tcpkg on Windows | `Get-FltEffectivePackageManager` defaults to `'tcpkg'` when `PackageManager=''` and `OS='windows'` | Creates synthetic target with empty PackageManager, checks result |
| 9e | Routing: both target | `Get-FltEffectivePackageManager` returns `'both'` for a target with `PackageManager='both'` | Creates synthetic target, checks result |
| 9f | `_Get-WinGetCommand` command format | `winget install/upgrade/uninstall` commands include correct verb, package id, and `--silent --disable-interactivity` flags | Calls `_Get-WinGetCommand` for each verb with a known package id, checks all three output strings |
| 9g | `Search-FltWinGetPackage` returns results _(requires winget)_ | Searching for `'notepad'` returns at least one result with correct shape | Calls `Search-FltWinGetPackage -SearchTerm 'notepad'`, checks count and that result has `Name`, `Version`, `Source` properties. WARN if no results. |
| 9h | `Get-FltWinGetVersions` returns versions _(requires winget)_ | `winget show --id 7zip.7zip --versions` returns a list | Calls `Get-FltWinGetVersions -PackageId '7zip.7zip'`, checks count and shape. WARN if package not in configured sources. |
| 9i | `Get-FltWinGetInstalledIndex` returns hashtable _(requires winget)_ | `winget list` is parsed into a name→version hashtable with lowercase keys | Calls `Get-FltWinGetInstalledIndex`, checks return is a hashtable and all keys are lowercase (consistent with `Get-FltInstalledIndex` contract). WARN if winget not on machine. |
| 9j | WinGet target with `IA=False` routes to push bucket | `FleetExecutor` sends `InternetAccess=False` targets to the push bucket regardless of `PackageManager` | Creates synthetic `FleetTarget` with `PackageManager='winget'` and `InternetAccess=$false`, simulates `FleetExecutor` bucket logic, checks `goesPush=true` and `goesWinGet=false` |
| 9k | `_Parse-WinGetTable` — search format (multi-group separator) | Position-based parsing correctly extracts Id/Title/Version when separator is `--- --- ---` | Fixture: 3-row `winget search` output. Verifies `Notepad++.Notepad++` in `Name`, `Notepad++` in `Title`, `8.9.6.4` in `Version`. Column positions taken from header word starts (not dash group positions — these are off by 1-2 chars). |
| 9k | `_Parse-WinGetTable` — list format (solid separator) | Multi-space split correctly extracts Id/Title/Version when separator is `------...` | Fixture: 6-row `winget list` output including ARP, msstore, and runtime entries. Verifies `XmlNotepad` (id=`Microsoft.XMLNotepad`, ver=`2.9.0.22`), `OpenSSH` (ver=`9.5.0.0`), `WindowsAppRuntime.1.8` (ver=`1.8.0`). ARP entries present in fixture but not asserted — filtered by UI layer. |

---

### Suite 20 — WinGet live install `[needs target]`

**Infrastructure required:** Online Windows target with SSH, stored or entered credentials, internet access on target  
**Per target:** Yes (runs against each selected target)

Tests a real install, verify, and uninstall cycle using `7zip.7zip` via `Invoke-FltWinGetBatch`. All checks are fully reversible — the target is left in the same state it started.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| Pre-A | winget installed on target | `winget --version` exits 0 and returns a version string | SSH → `winget --version`. FAIL with `Setup > Prepare target` instruction if not found. |
| Pre-B | winget sources configured | `winget source list` returns at least one HTTPS source | SSH → `winget source list`, checks for `https://`. FAIL with reset instruction if empty. |
| Pre-C | winget sources refreshed | `winget source update` exits 0 | SSH → `winget source update --disable-interactivity`. WARN (not FAIL) if fails — stale cache is recoverable. |
| Pre-D | 7zip.7zip pre-check | Determines whether test package is already installed | SSH → `winget list --id 7zip.7zip`. Sets `$alreadyInstalled` flag. |
| If already installed: | | | |
| Alt-B | Install when already installed → Skipped | `Invoke-FltWinGetBatch` returns `Status='Skipped'` and `Note` contains `'Already installed'` when package is already present | Calls `Invoke-FltWinGetBatch -Action install -PackageSpec 7zip.7zip`, checks status and note |
| If not installed: | | | |
| 10b | Install `7zip.7zip` | `Invoke-FltWinGetBatch` returns `Status='OK'` | Calls batch executor, checks status and duration |
| 10c | Verify installed | `winget list --id 7zip.7zip` finds the package after install | SSH → `winget list --id 7zip.7zip`, checks output contains package id |
| 10d | Uninstall `7zip.7zip` | `Invoke-FltWinGetBatch -Action uninstall` returns `Status='OK'` | Calls batch executor, checks status |
| 10e | Verify removed | `winget list --id 7zip.7zip` does not find the package after uninstall | SSH → `winget list --id 7zip.7zip`, checks output does NOT contain package id |

---

### Suite 21 — Ansible availability

**Infrastructure required:** Docker Desktop on operator machine (for 11f/11g checks — both WARN gracefully if Docker not present)  
**Per target:** No

Tests the `AnsibleRepository.ps1` functions. All checks pass gracefully when Ansible is not installed — they verify the functions return correct empty/false values, not that Ansible is present.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 11a | `Get-FltAnsibleMode` returns valid value | Returns `'native'`, `'wsl'`, or `''` — never anything else | Calls `Get-FltAnsibleMode`, checks result is one of the three valid values |
| 11b | `Test-FltAnsibleAvailable` consistent with mode | `$true` iff mode is not `''` | Calls both functions, checks `Available == (mode -ne '')` |
| 11c | `Get-FltAnsibleVersion` correct per mode | Returns `''` when unavailable, non-empty string when available | Checks version matches mode state. WARN if version empty when mode found. |
| 11d | `Get-FltAnsibleStatus` correct shape | Returns object with `Available`, `Mode`, `Version`, `HasCommunityDocker` | Creates object, checks all four properties exist via `PSObject.Properties` |
| 11e | `Test-FltAnsibleCollection` returns bool | Returns `$false` when unavailable; `$true` if `community.docker` installed | Checks return type is `[bool]`. WARN if collection missing (install instructions shown). |
| 11f | `Test-FltAnsibleDockerContainer` — container exists | Returns `$true` if `tcflt-ansible` container has been built | Calls `docker inspect tcflt-ansible`. WARN with build instructions if not found. |
| 11g | `Test-FltAnsibleDockerContainerRunning` — container running | Returns `$true` if container is currently running | Calls `docker inspect --format {{.State.Running}}`. WARN with start instructions if stopped; WARN with build instructions if not built. |

---

### Suite 22 — Docker operator

**Infrastructure required:** Docker Desktop installed on operator machine (checks WARN gracefully if not)

Tests `DockerRepository.ps1` — Docker Desktop availability and status on the operator machine. Independent of Ansible.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 12a | docker CLI available | `docker` command is on PATH | `Get-Command docker`. WARN with install instructions if missing. Remaining checks skipped. |
| 12b | `Get-FltDockerStatus` valid value | Returns one of `running`, `starting`, `stopped`, `not-installed` | Calls function, checks result is in valid set |
| 12c | `Get-FltDockerDesktopPath` finds installation | Docker Desktop executable found at known path or via registry | Checks known paths and `HKCU:\Software\...\App Paths`. WARN if not found. |
| 12d | `Test-FltDockerAvailable` consistent with status | `$true` iff status is `running` | Calls both functions, checks consistency |
| 12e | Docker daemon running | Status is `running` | WARN with appropriate message for each non-running state; PASS when running |

---

### Suite 22 — Docker operator

**Infrastructure required:** Docker Desktop installed on operator machine (checks WARN gracefully if absent)

Tests `DockerRepository.ps1` functions for Docker Desktop management on the operator machine.

| # | Test name | What is tested | How verified |
|---|-----------|----------------|--------------|
| 12a | docker CLI available | `docker` command is on PATH | `Get-Command docker`. WARN with install URL if absent. Remaining checks skip if CLI missing. |
| 12b | `Get-FltDockerStatus` valid value | Returns one of `running`, `starting`, `stopped`, `not-installed` | Calls function, checks against known valid values |
| 12c | `Get-FltDockerDesktopPath` finds installation | Returns path to `Docker Desktop.exe` | Checks known install paths and HKCU App Paths registry. WARN if not found. |
| 12d | `Test-FltDockerAvailable` consistent with status | `$true` iff status is `running` | Calls both functions, verifies consistency |
| 12e | Docker daemon running | Daemon is ready for commands | PASS if running; WARN with appropriate message for `starting`, `stopped`, `not-installed` |

---

## Adding New Tests

When implementing a new phase, add tests in the appropriate location:

- **Pure logic, no infrastructure** → add to `Diagnostics.ps1` as a new `_Diag_Section`
- **File I/O or config, no network** → add to `Invoke-IT_FileIO` (Suite 11)
- **Requires SSH to a target** → add to `Invoke-IT_SSH` (Suite 13) or a new suite
- **Requires tcpkg locally** → add to `Invoke-IT_TcpkgLocal` (Suite 17)
- **Requires tcpkg + online target** → add to `Invoke-IT_PackageQueries` (Suite 18)
- **New executor (WinGet, Ansible, Docker)** → add as Suite 19, 20, 21 respectively

Update `Get-IT_Suites` in `IntegrationTests.ps1` and the dispatch switch in `TestRunner.ps1` when adding a new suite. Document it here.

### Planned future suites

| Suite | When | What it will test |
|-------|------|-------------------|
| 21 — Ansible executor | Phase 5 | `ansible-playbook` found, inventory generation, playbook execution, exit code mapping |
| 22 — Docker exec batch | Phase 7 | Docker CLI found, `docker exec` command executes inside container, container reachability check |