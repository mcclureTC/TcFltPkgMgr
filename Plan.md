# TcFltPkgMgr — WinGet, Ansible & Container Integration Plan

A step-by-step implementation checklist. Each section is a logical unit of work
that can be completed and tested independently before moving to the next.

> **Scale note:** The fleet is expected to grow to ~100 total remote targets,
> consisting of Windows PCs, Beckhoff IPCs (Windows and RT Linux), VMware Debian
> VMs, and Docker containers. A Beckhoff IPC running Windows is managed
> identically to a Windows PC (tcpkg/WinGet via SSH) - no distinct code path.
> Several design decisions below are informed by this scale requirement.

---

## Seven-step development process

Every phase follows these steps in order before being marked complete:

| Step | Action |
|------|--------|
| 1 | **Code** — implement the feature or change |
| 2 | **Write or update tests** — add diagnostics and/or integration tests; explicitly decide whether new tests are needed (the answer may be "none required") |
| 3 | **Run all tests** — confirm all diagnostics and integration tests pass |
| 4 | **Security and license check** — scan changed files for Windows-only APIs, hardcoded secrets, and new dependencies |
| 5 | **Update `.gitignore`** — add any new files that must not be committed |
| 6 | **Update `README.md`** — document new behaviour, commands, or configuration |
| 7 | **Update `Plan.md`** — mark completed items, record deferred items with their target phase |

Step 2 is an explicit gate — it forces the question "what should be tested here?" before running anything. The answer may legitimately be "nothing new" (e.g. pure rendering changes already covered by existing tests), but it must be a conscious decision, not an omission.

---

## Conventions carried forward from existing code

- All numbered list items use base-11 when coexisting with single-digit menu
  choices on a dashboard screen; base-1 for standalone pick-lists with no
  dashboard (feed picker, version picker, package results).
- Every screen that shows fleet data uses the ANSI dashboard pattern
  (`Paint-FltTitleBar`, `Paint-FltRow`, `Clear-Host` once at top).
- Action menus are a footer below the data, separated by a `'-' * $sw` rule.
- Results and the last command appear in a result row above the prompt.
- `$Script:FltLastCmd` and `$Script:FltLastExit` are set by every executor.
- Batch operations always go through `Show-FleetBatchDashboard` and
  `Update-FltBatchRow`; results are written to the NDJSON log via
  `Write-FltBatchEntry`.
- No bare `if` as cmdlet argument — always `$(if ...)`.
- No `$var:` in double-quoted strings — always `${var}:`.
- `$Matches` is not thread-safe in `-Parallel` — use `-split` instead of
  `-match` inside parallel blocks.
- PS class methods cannot declare return types.
- PS class methods without declared return types output to the pipeline
- **`pwsh -NonInteractive | Out-String` pattern:** When `Invoke-SSHCommand` runs any
  tool that detects TTY mode (winget, ansible, docker, pip, etc.), always wrap:
  `pwsh -NoProfile -NonInteractive -Command "tool args | Out-String -Width 300"`
  This suppresses progress animation and CLIXML serialization, giving clean plain text.
- **`$Matches` is not thread-safe** — in parallel/thread-job blocks always use
  `-split` or named capture groups stored in local variables instead of `$Matches` — do NOT
  assign them to variables (`$x = $t.Method()` returns `$null`). Either use the
  output directly in a pipeline/expression, or inline the logic in the caller.
- `Set-StrictMode -Off` is set globally.

---

## Phase 0-A — Display abstraction (do before everything else)

The dashboard must be treated as a replaceable component from this point
forward. All menus and executors must talk to a stable **display adapter**
interface, not directly to `Dashboard.ps1`. This is a small refactor now that
prevents a large migration later when moving to Spectre.Console or a C# UI.

### 0-A.1 — Rename and split `ui/Dashboard.ps1` ✅

- [x] Rename `ui/Dashboard.ps1` → `ui/DashboardAnsi.ps1`
- [x] Create `ui/DisplayAdapter.ps1` — stable interface, explicit named parameter forwarding
- [x] Create `ui/DisplayBackends.ps1` — wires `$Script:FltDisplay_*` variables at startup;
      Spectre.Console branch stubbed with full implementation guide in comments
- [x] Update `TcFltPkgMgr.ps1` — dot-source backends at script scope, call `Set-FltDisplayBackend`
- [x] Add `"displayBackend": "ansi"` to `settings.default.json`
- [x] All 26 diagnostics pass including display adapter wiring and `_Ansi_` function presence
- [x] Non-blocking key polling loop added to fleet home for live reachability updates
- [x] Built-in diagnostics moved to `diagnostics/Diagnostics.ps1` (new top-level folder)

### 0-A.2 — Credential backend abstraction ✅

- [x] Create `data/CredentialAdapter.ps1` — `Get/Set/Remove-FltStoredPassword` delegates
- [x] Create `data/CredentialBackendWindows.ps1` — DPAPI `ProtectedData` implementation
      (replaced unreliable Win32 P/Invoke; stores in `credentials.win.json`)
- [x] Create `data/CredentialBackendFile.ps1` — AES-256/PBKDF2 encrypted file for Linux
      (stores in `credentials.local.enc` + `credentials.salt`)
- [x] Create `data/CredentialBackends.ps1` — auto-selects `windows` on Windows, `file` on Linux
- [x] `CredentialRepository.ps1` slimmed to `Resolve-FltPassword` only
- [x] Add `"security": { "credentialBackend": "" }` to `settings.default.json`
- [x] Credential round-trip test passes in diagnostics (26/26)

### 0-A.3 — Cross-platform compatibility audit ✅

- [x] Scanned all `.ps1` files for Windows-specific APIs — none found outside
      designated backend files (`CredentialBackendWindows.ps1`)
- [x] No hardcoded secrets, Windows registry access, or WPF APIs in cross-platform files
- [x] Windows path in `settings.default.json` and `FleetExecutor.ps1` is for the
      remote target machine — intentional and commented
- [x] `cmd.exe` reference in `Diagnostics.ps1` is guarded with `pwsh` first-preference
- [x] Added `$Script:FltOS` detection at startup in `TcFltPkgMgr.ps1`
- [x] Added `$Script:FltFeatures` map for platform-specific feature gating
- [x] Added `Test-FltFeatureAvailable` to `data/ConfigRepository.ps1`
- [x] Added `-Silent` switch to `Resolve-FltPassword` for non-interactive contexts
- [x] All 16 diagnostics checks pass including OS detection and feature gating
- [ ] Menu options that call Windows-only features show `[Windows only]` label
      on Linux — deferred to Phase 12 (Linux operator support)

---

## Phase 0 — Scale preparation

These changes are needed before Phase 1 because 100 targets fundamentally
changes how the dashboard, executor, and target store work. Do this first so
every subsequent phase builds on a scalable foundation.

### 0.1 — Dashboard pagination ✅

- [x] `Show-FleetDashboard` paginates using `$Page` parameter and
      `Get-FltCfgValue 'ui' 'dashboardPageSize'`
- [x] `-` / `+` numpad keys navigate pages (numpad-first design)
- [x] Target numbers are global — `11` always means the first target
      regardless of which page is displayed
- [x] Footer shows `Page 1 of 3   [+] Next   (showing 11-13 of 17)`
      only when fleet exceeds page size
- [x] `$Script:FltDashPage` tracks current page in `Invoke-FleetMenu`
- [x] Page resets to 0 on every `Invoke-FltReloadTargets` call
- [x] `ui.dashboardPageSize` added to `settings.default.json` (default 20)
- [x] Added `ui/menus/UiConfigMenu.ps1` — runtime UI settings accessible
      via Fleet home > 7. UI Config; changes persist to `settings.local.json`
- [x] `_Save-UiCfgValue` round-trip and pagination math tested in diagnostics
- [ ] `Show-SetupDashboard` pagination — low priority; Setup rarely exceeds 20 targets. Revisit in Phase 12 if needed.
- [ ] `Show-FleetBatchDashboard` pagination — deferred to Phase 7 (container scale)

### 0.2 — Executor throttle tuning ✅

- [x] Raised `ssh.throttleLimit` from 10 → 25 in `settings.default.json`
- [x] Added TCP pool warning comment to `SshExecutor.ps1` (values >50 risk exhaustion)
- [x] Added `docker.throttleLimit: 20` to `settings.default.json` (Phase 7 ready)
- [x] `Start-FltReachJob` rewritten from sequential `foreach` to
      `ForEach-Object -Parallel` — 100 targets now check in ~2s not ~200s
- [x] Feed check parallel block uses `$using:throttle` not hardcoded 10
- [x] Throttle bounds test added to diagnostics (catches values outside 1-50)
- [x] `Start-FltReachJob` callability tested in diagnostics
- [x] `ansible.forks` — completed in Phase 5.0

### 0.3 — Target store: move from tcpkg to local JSON ✅

- [x] `config/targets.local.json` — primary target store, all target types (gitignored)
- [x] `Get-FleetTargets` reads from JSON; falls back to `tcpkg remote list` on
      first run and migrates automatically via `Invoke-FltTargetStoreMigration`
- [x] `Add/Edit/Remove-FleetTarget` write to JSON first; also sync tcpkg for
      Windows/tcpkg targets (needed for push-from-local)
- [x] `Import/Export-FleetTargetsCsv` includes new OS/TargetType/PackageManager columns
- [x] Linux and container targets stored in JSON only — tcpkg never involved
- [x] `FleetTarget` class extended with `OS`, `TargetType`, `PackageManager`,
      `DockerHost`, `ContainerName` fields and helper methods
- [x] Add/Edit/Remove accessible from both Fleet (11+) and Setup (11+) with
      consistent `— enter action for Config:` prompt
- [x] Sort and filter added to Fleet and Setup dashboards (`*` / `/` keys)
- [x] Sort order persisted to `targets.local.json` immediately on change
- [x] Sort/filter state shared across Fleet and Setup (Option C — always in sync)
- [x] Filter shows active state in nav row: `[Filter: col='val']  N→M targets`
- [x] Sort/filter tested in diagnostics (7 new tests, 28/28 passing)
- [x] `$using:ctx` context object pattern used in `ForEach-Object -Parallel`
      to avoid scope issues in `Get-FltRemoteFeedStatus`
- [x] Setup dashboard: 11+ target selection for Verify/Edit/Remove (consistent with Fleet)
- [x] Action prompt reads `— enter action for Config:` to clarify config vs live operations
- [x] Feed picker (`_Pick-Feed-Live`) now reads live tcpkg source list instead of
      static `$Script:FltFeeds` — shows all configured feeds including user-added ones

### 0.4 — Reachability check at scale ✅

- [x] `Start-FltReachJob` already uses `ForEach-Object -Parallel` via `Start-ThreadJob`
      (implemented in Phase 0.2) — all 100 targets checked in ~2s
- [x] Page-first reachability: current page targets checked with `-IgnoreCache` immediately;
      remaining pages queued as a second background job
- [x] Result caching via `$Script:FltReachCache` — online targets skip recheck within
      `ui.reachCacheSecs` (default 60); offline targets always recheck
- [x] `Receive-FltReachJob` — applies job results and updates cache atomically
- [x] `ui.reachCacheSecs: 60` added to `settings.default.json`
- [x] Cache and page-first behavior tested in diagnostics (29/29 passing)

---

## Phase 1 — Target model extensions

### 1.1 — Extend `FleetTarget` class (`classes/Models.ps1`) ✅
> Implemented as part of Phase 0.3

- [x] `[string] $OS` — `'windows'` | `'linux'` | `'macos'`
- [x] `[string] $TargetType` — `'physical'` | `'vm'` | `'container'`
- [x] `[string] $PackageManager` — `'tcpkg'` | `'winget'` | `'apt'` etc. | `''` (auto)
- [x] `[string] $DockerHost` — Docker host target name (containers only)
- [x] `[string] $ContainerName` — Docker container name or ID (containers only)
- [x] Both constructors default `OS='windows'` `TargetType='physical'` `PackageManager=''`
- [x] `EffectivePackageManager()` — resolves `''` to OS default
- [x] `OsDisplay()` / `TypeDisplay()` / `IsContainer()` / `EffectiveAddress()`
- [x] All methods use implicit output (no `return`) — PS7 class requirement

### 1.2 — Target store (`data/TargetRepository.ps1`) ✅
> Implemented as part of Phase 0.3

- [x] `Get-FleetTargets` reads from `targets.local.json` with tcpkg fallback
- [x] `Save-FltTargets` writes full list; called after sort changes to persist order
- [x] `Invoke-FltTargetStoreMigration` runs once on first launch
- [x] No sidecar file needed — all fields in `targets.local.json`

### 1.3 — Update CSV import/export (`data/TargetRepository.ps1`) ✅
> Implemented as part of Phase 0.3

- [x] `Export-FleetTargetsCsv` includes OS, TargetType, PackageManager, DockerHost, ContainerName
- [x] `Import-FleetTargetsCsv` reads new columns; defaults for backward compat
- [x] Add-FleetTarget falls back to `tcpkg remote edit` if target already exists in tcpkg

### 1.4 — Update `Add-FleetTarget` and `Edit-FleetTarget` ✅
> Implemented as part of Phase 0.3

- [x] Accept `-OS`, `-TargetType`, `-PackageManager`, `-DockerHost`, `-ContainerName`
- [x] Linux/container targets skip `tcpkg remote add` — JSON store only
- [x] Windows/tcpkg targets sync to tcpkg after JSON write
- [x] `Add-FleetTarget` upserts — updates if already in JSON, adds if new
- [x] Validate `DockerHost` references an existing target — deferred to Phase 7
      (containers not yet implemented) — completed in Phase 7.4

---

## Phase 2 — Fleet dashboard updates

### 2.1 — `Show-FleetDashboard` (`ui/DashboardAnsi.ps1`) ✅

- [x] `OS` column (`Win`/`Lnx`/`Mac`) and `Type` column (`Phys`/`VM`/`Cntr`) added
- [x] Row colours: Linux/macOS = Cyan, Container = Magenta, Windows = reachability-based
- [x] `Internet` column shows `---` for Linux, macOS, and container targets
- [x] Container address column uses `EffectiveAddress()` → `<DockerHost>/<ContainerName>`
- [x] OS and Type added as sortable/filterable columns in sort picker
- [x] All 29 diagnostics and 44 integration tests pass

### 2.2 — `Show-SetupDashboard` (`ui/DashboardAnsi.ps1`) ✅

- [x] `OS` and `Type` columns added to targets view — same pattern as Fleet dashboard (2.1)
- [x] Row colours: Linux/macOS = Cyan, Container = Magenta, Windows = default
- [x] `Internet` column shows `---` for Linux, macOS, and container targets
- [x] `EffectiveAddress()` used for container address column
- [x] OS and Type added to Setup sort picker columns
- [ ] Pagination — low priority; Setup rarely exceeds 20 targets (revisit Phase 12)

### 2.3 — `Show-FleetBatchDashboard` (`ui/DashboardAnsi.ps1`)

> Pagination deferred to Phase 7.0. Mode/Summary row updates depend on
> having multiple executors — defer to Phase 10 (after all executors exist).

- [x] Pagination with auto-scroll to first non-OK row — done in Phase 7.0
- [x] `Type` column in batch rows — done in Phase 8.0
- [ ] Multi-executor `Mode` row and per-executor summary counts —
      defer to Phase 10 (after WinGet, Ansible, Docker executors exist)

---

## Phase 3 — WinGet executor (Windows targets, general packages) ✅

### 3.1 — WinGet executor (`execution/WinGetExecutor.ps1`) ✅

- [x] `Invoke-FltWinGetBatch` — mirrors `Invoke-FltSshBatch`; same parallel pattern,
      ConcurrentDictionary status tracking, OnProgress callback, jitter, hosts.json retry
- [x] Command format: `winget install/upgrade/uninstall --id <package> --silent
      --accept-package-agreements --accept-source-agreements`
- [x] Exit codes: `0`=OK, `-1978335212`=not found, `-1978335189`=already installed,
      `-1978335188`=no upgrade available — all mapped to human-readable status/note
- [x] No feed check phase — WinGet fetches from its own configured sources
- [x] `PackageManager = 'winget'` set on all batch results

### 3.2 — WinGet package search (`data/WinGetRepository.ps1`) ✅

- [x] `Test-FltWinGetAvailable` — checks for winget on operator PATH
- [x] `Search-FltWinGetPackage` — parses winget tabular output (column-position based);
      returns same `@{ Ok; Items; Columns }` shape as `Get-FltPackageList`
- [x] `Get-FltWinGetVersions` — `winget show --id <id> --versions`; same shape as
      `Get-FltPackageVersions`
- [x] `Get-FltWinGetInstalledIndex` — `winget list`; same shape as `Get-FltInstalledIndex`

### 3.3 — Route WinGet targets in `Invoke-FleetAction` (`execution/FleetExecutor.ps1`) ✅

- [x] SSH bucket split into `$tcpkgSshTargets` and `$wingetSshTargets` by
      `EffectivePackageManager()` — `'tcpkg'`/`'both'` → tcpkg, `'winget'`/`'both'` → WinGet
- [x] `'both'` targets appear in both SSH buckets
- [x] Push bucket unchanged — always tcpkg
- [x] Read-only mode produces `[read-only] would SSH (tcpkg/winget)` per bucket

### 3.4 — Lessons learned

- PS7 class methods without declared return types must not be assigned to variables
  (`$x = $t.Method()` returns `$null`). Inline the logic in the caller instead.
  Added to conventions in this plan.

---

## Phase 3.5 — Install WinGet on target via SSH ✅

> Inserted before Phase 4 (WinGet UI) because the menu is only useful once
> targets actually have winget. SSH runs as the authenticating user on these
> targets, so `Add-AppxPackage` works directly without WinRM or DISM.

### 3.5.1 — `Install-FltWinGetOnTarget` (`data/WinGetRepository.ps1`)

- [x] Check winget already installed — skip with success if present
- [x] Resolve latest `Microsoft.DesktopAppInstaller` msixbundle URL from
      GitHub releases API (`api.github.com/repos/microsoft/winget-cli/releases/latest`)
- [x] Download msixbundle + required dependencies to remote temp dir via SSH:
      - `Microsoft.UI.Xaml` (vclibs dependency)
      - `Microsoft.VCLibs.x64.14.00.Desktop.appx`
      - `Microsoft.DesktopAppInstaller_*.msixbundle`
- [x] `Add-AppxPackage` each dependency then the bundle via SSH PowerShell
- [x] Verify `winget --version` exits 0 after install
- [ ] Clean up temp files on success or failure

### 3.5.2 — Setup menu item (`ui/menus/TargetMenu.ps1`)

- [x] Added as sub-option 4 within target action menu (11+ select → 4. Prepare target) to Setup menu (above Diagnostics)
      Renumber: Diagnostics → 12, Log → 13
- [x] Prepare target flow in `TargetMenu.ps1` — runs pre-checks then install sequence
      per selected target; shows progress inline
- [ ] On success: update `targets.local.json` — deferred (not needed for basic operation) to record winget is available

### 3.5.3 — Suite 20 pre-check recovery (`diagnostics/IntegrationTests.ps1`) ✅

- [x] Pre-check A failure message references Setup > select target > 4. Prepare target

### 3.5.4 — Lessons learned

- `Add-AppxPackage` for framework packages requires an interactive desktop session token.
  SSH sessions cannot provide this even as Administrator — access denied (0x80070005).
- Solution: schedule a logon-triggered task (`/sc onlogon /ru Administrator`) that
  runs during autologin, which has the full interactive desktop token.
- `-ErrorAction SilentlyContinue` on `Add-AppxPackage` is dangerous — it silently
  masks failures and reports false success. Always use `-ErrorAction Stop` + try/catch.
- `0x80073D06` (higher version already installed) is a success condition, not a failure.
- `certutil -decode` is the reliable way to write large scripts to a remote target —
  avoids the 8191-char Windows command line limit that breaks long `EncodedCommand` strings.
- `EncodedCommand` strings must stay under ~4000 chars (8191 limit / 2 for UTF-16 encoding).

### 3.5.5 — Test results

- Suite 19 (WinGet executor): 15/15 ✅ — added 9i, 9j (Phase 3 review), 9k (Phase 4 parser fixtures)
- Suite 20 (WinGet live install): 8/8 ✅ — tested on DCC-4, fully automated

---

## Phase 4 — WinGet UI ✅

### 4.1 — Fleet menu (`ui/menus/FleetMenu.ps1`) ✅

> Redesigned as two-level hierarchy: top level selects package manager,
> sub-menus provide identical install/upgrade/uninstall/status flows.
> Both sub-menus follow the same UX: search → pick → version → targets → batch.

- [x] Top level: `1. tcpkg  2. WinGet  3. Profiles  4. UI Config  5. Setup`
- [x] `Invoke-TcpkgMenu` sub-menu wraps existing install/upgrade/uninstall/status/outdated flows
- [x] `Invoke-WinGetMenu` sub-menu with same structure, routes to WinGet flows
- [x] Dashboard footer updated (72 chars, fits comfortably at 119 cols)

### 4.2 — WinGet menu (`ui/menus/WinGetMenu.ps1`) ✅

- [x] `Invoke-WinGetInstallMenu` — search → filter msstore → pick → version → targets → batch
- [x] `Invoke-WinGetUpgradeMenu` — search → filter msstore → pick → targets → batch
- [x] `Invoke-WinGetUninstallMenu` — select target → SSH `winget list` via `pwsh -NonInteractive | Out-String` → filter unmanageable entries → pick → all targets → batch
- [x] `Invoke-WinGetStatusMenu` — parallel SSH query per target
- [x] Target filter: all Windows targets by default; winget/both targets preferred
- [x] `_Parse-WinGetTable`: dual-mode (adjacent header+sep search OR hardcoded fallback), multi-space split for list output
- [x] Key lesson: Posh-SSH `Invoke-SSHCommand` allocates PTY → winget shows progress animation → wrapping in `pwsh -NonInteractive | Out-String` suppresses it and provides clean parseable output

### 4.3 — Setup: target OS/PackageManager prompts (`ui/menus/TargetMenu.ps1`)

> These prompts are a subset of Phase 9.1 (full type/OS/container flow).
> Implementing 4.3 now means 9.1 won't need to redo this work.
> **Implement alongside Phase 9.1** — do both together rather than
> adding Windows-only prompts now and re-editing for containers later.
> Marked as dependency: Phase 9.1 satisfies 4.3.

- [ ] OS and PackageManager prompts — implement in Phase 9.1 (full flow)
- [ ] Show `OS`, `Type`, `PackageManager` in Setup dashboard — implement in Phase 9

---

### 4.4 — Phase 4 bug fixes and improvements ✅

**Bug: `Invoke-WinGetStatusMenu` SSH credentials not passed** ✅
- [x] `Get-FleetSshCredential` called before launching thread jobs
- [x] Credential passed via `-ArgumentList` to each job
- [x] `$Matches[0]` replaced with `-split` for thread safety (convention reminder)
- [x] Uses `pwsh -NonInteractive | Out-String` pattern (suppresses PTY animation)

**Missing: `winget` section in `settings.default.json`** ✅
- [x] Added `winget: { remoteWinGetPath: "winget", timeoutSeconds: 300 }`

**Missing: `PackageManager` field in `Write-FltBatchEntry`** ✅
- [x] `packageManager` field added — derived from first result with it set, defaults to `'tcpkg'`
- [x] All existing batch log entries now include `packageManager`

**Lesson applied: `pwsh -NonInteractive | Out-String` pattern** ✅
- Documented and applied to Status menu SSH queries
- Added to conventions for all future phases using SSH + interactive tools

---

## Phase 5 — Ansible prerequisites

### 5.0 — Pre-work ✅

**Fix: `SshExecutor` does not set `PackageManager` on `BatchResult` objects** ✅
- [x] `PackageManager` added as first-class field on `BatchResult` class (`classes/Models.ps1`)
- [x] `SshExecutor` sets `PackageManager = 'tcpkg'` on pscustomobject and carries it
      through to typed `BatchResult`
- [x] `WinGetExecutor` now also carries `PackageManager = 'winget'` through to typed `BatchResult`
      (was set on pscustomobject but lost during typed conversion)
- [x] `Write-FltBatchEntry` reads `PackageManager` directly from `$Results[0]`
- [x] Suite 17 check 7k: `BatchResult.PackageManager` field verified (7/7 ✅)

**Add `ansible` section to `settings.default.json`** ✅
- [x] `ansible: { executablePath, dockerContainer, useWsl, wslDistro, tempDir, forks: 10 }` added

### 5.1 — Ansible availability check (`data/AnsibleRepository.ps1`) ✅

**Architecture decision:** Ansible runs in a Docker container on the operator Windows machine
(container name: `tcflt-ansible`, built from `docker/Dockerfile.ansible`).
This avoids WSL and gives a consistent Linux Ansible environment on Windows.
Mode priority: `native` → `wsl` → `docker` → `''`

- [x] `Get-FltAnsibleMode` — returns `'native'`, `'wsl'`, `'docker'`, or `''`
- [x] `Test-FltAnsibleAvailable` — returns `$true` when mode is not `''`
- [x] `Get-FltAnsibleVersion` — returns version string or `''`
- [x] `Test-FltAnsibleCollection` — checks `community.docker` via `ansible-galaxy`
- [x] `Get-FltAnsibleStatus` — convenience wrapper: `{Available, Mode, Version, HasCommunityDocker}`
- [x] `Test-FltAnsibleDockerContainer` / `Test-FltAnsibleDockerContainerRunning` — container state
- [x] `_Get-FltAnsibleCmd` / `_Get-FltAnsibleGalaxyCmd` — mode-aware command builders
- [x] `ansible.dockerContainer` added to `settings.default.json` (default: `tcflt-ansible`)
- [x] Suite 21 (Ansible availability): 7/7 ✅ — passes gracefully when Ansible not installed
- [x] Target numbering moved to 101+ (was 21+) to avoid conflict with suite 21

### 5.1.5 — Ansible operator Dockerfile (`docker/Dockerfile.ansible`) ✅

- [x] `docker/Dockerfile.ansible` — builds `tcflt-ansible` container image
      Based on `python:3.12-slim`; installs ansible, ansible-runner, paramiko,
      openssh-client, sshpass; installs `community.docker`, `community.general`,
      `ansible.posix` collections; mounts `/ansible` volume for inventory/playbooks
- [x] Build: `docker build -f docker/Dockerfile.ansible -t tcflt-ansible .`
- [x] Run: `docker run -d --name tcflt-ansible --restart unless-stopped -v \${PWD}/ansible:/ansible tcflt-ansible`
- [x] Suite 21 checks 11f/11g now 7/7 ✅ — container built and running — instructions shown inline

### 5.1.6 — Docker operator repository (`data/DockerRepository.ps1`) ✅

> Docker separated from Ansible — Docker Desktop is needed for Windows containers
> too, independent of Ansible. `DockerRepository.ps1` handles operator-machine
> Docker state; remote Docker management is `DockerExecutor.ps1` (Phase 7).

- [x] `Get-FltDockerDesktopPath` — finds Docker Desktop exe via known paths + HKCU registry
- [x] `Test-FltDockerAvailable` — checks daemon is running and responsive (`docker info`)
- [x] `Test-FltDockerDesktopRunning` — checks if Docker Desktop process is running
- [x] `Get-FltDockerStatus` — returns `'running'` | `'starting'` | `'stopped'` | `'not-installed'`
- [x] `Start-FltDockerDesktop` — launches Docker Desktop, optionally waits for daemon ready
- [x] `Ensure-FltDockerRunning` — idempotent: no-op if running, waits if starting, launches if stopped
- [x] Suite 22 (Docker operator): 5 checks — `12a`-`12e` all pass/warn gracefully per state
- [x] Suite 21 docker checks (11f/11g) updated to use `Get-FltDockerStatus` from DockerRepository

### 5.1.7 — Docker operator repository (`data/DockerRepository.ps1`) ✅

Separated from Ansible — Docker is used independently (Windows containers, remote
container management, Ansible operator container). Loaded before AnsibleRepository.

- [x] `Get-FltDockerDesktopPath` — finds Docker Desktop exe (known paths + HKCU registry)
- [x] `Test-FltDockerAvailable` — returns `$true` when daemon is responsive
- [x] `Test-FltDockerDesktopRunning` — returns `$true` when Docker Desktop process exists
- [x] `Get-FltDockerStatus` — returns `'running'` | `'starting'` | `'stopped'` | `'not-installed'`
- [x] `Start-FltDockerDesktop` — launches Docker Desktop, optionally waits for daemon
- [x] `Ensure-FltDockerRunning` — checks status, optionally prompts and starts
- [x] Suite 22 (Docker operator): 5/5, 1 WARN (Docker stopped) — tested and working

### 5.1.7 — Docker operator repository (`data/DockerRepository.ps1`) ✅

Separated from Ansible — Docker is used independently for Windows containers,
remote management, and hosting the Ansible operator container.

- [x] `Get-FltDockerDesktopPath` — known paths + HKCU App Paths registry
- [x] `Test-FltDockerAvailable` — daemon responsive via `docker info`
- [x] `Test-FltDockerDesktopRunning` — process running (even if daemon not yet ready)
- [x] `Get-FltDockerStatus` — `'running'` | `'starting'` | `'stopped'` | `'not-installed'`
- [x] `Start-FltDockerDesktop` — launches Desktop, optionally waits for daemon
- [x] `Ensure-FltDockerRunning` — checks status, prompts operator, starts if needed
- [x] Suite 22 (Docker operator): 5/5 ✅ (4 pass, 1 WARN — Docker Desktop stopped)
- [x] Suite 21 checks 11f/11g now use `Get-FltDockerStatus` for clearer daemon-vs-container messages

### 5.2 — Ansible inventory builder (`execution/AnsibleExecutor.ps1`) — new file ✅

- [x] `New-FltAnsibleInventory` — generates INI inventory from `[FleetTarget[]]`
      - Filters to `OS -eq 'linux'`; returns `Ok=$false` immediately if no Linux targets
      - Groups by TargetType: `[physical]`, `[vm]`, `[containers]`
      - SSH vars per entry: `ansible_host`, `ansible_user` (target User →
        `ssh.defaultUser` → `'ansible'`), `ansible_port`
      - Auth: SSH key only — passwords are never written to inventory;
        `ansible_ssh_private_key_file` added when `ssh.privateKeyPath` exists
        and points to a real file (path normalised to forward-slashes for POSIX);
        no auth var written otherwise — Ansible uses its own key discovery
      - Container entries include `ansible_connection=community.docker.docker_api`
        and `ansible_docker_host=tcp://<DockerHostAddr>:<docker.daemonPort>`;
        Docker host address resolved by name lookup in the passed target list
      - `[linux:children]` meta-group written when more than one type group exists
      - Parent directory created automatically when missing
      - Default path: `ansible/inventory/hosts.ini` (gitignored)
      - Returns `[pscustomobject]@{ Ok; Path; TargetCount; Message }`
- [x] `Remove-FltAnsibleInventory` — deletes hosts.ini after each run;
      silent no-op when file absent
- [x] Phase 5.3–5.6 function stubs present (`throw 'Not implemented — Phase X.X'`)
- [x] Suite 23 (Ansible inventory builder) added to `IntegrationTests.ps1` —
      13 checks (23a–23m), fully offline, no Ansible required:
      13a empty-fleet guard · 13b file created · 13c ansible_host/port ·
      13d hostname key · 13e TargetCount · 13f vm group · 13g linux:children ·
      13h container vars · 13i docker host resolution · 13j remove ·
      13k remove no-op · 13l auto-mkdir · 13m return shape
- [x] Suite 13 registered in `Get-IT_Suites` and both dispatch arms in `TestRunner.ps1`
- [x] Security: no hardcoded secrets; passwords never written to inventory;
      `ansible_ssh_private_key_file` only when key file present; inventory path gitignored
- [x] `.gitignore`: `ansible/inventory/` already covered — no new entries needed
- [x] `README.md`: Phase 5.2 section added (see below)

### 5.3 — Ansible playbook builder (`execution/AnsibleExecutor.ps1`) ✅

- [x] `_Write-AnsiblePlaybook` — private helper: creates `ansible/playbooks/` dir if
      missing, writes timestamped `.yml` file (UTF-8), returns `{ Ok; Path; Message }`
- [x] `_Get-PackagePlaybook` — `ansible.builtin.package` (distro-agnostic);
      `install`→`present`, `upgrade`→`latest`, `remove`→`absent`
- [x] `_Get-ServicePlaybook` — `ansible.builtin.systemd`;
      `start`→`started`, `stop`→`stopped`, `restart`→`restarted`,
      `enable`→`enabled:true` (no state), `disable`→`enabled:false` (no state)
- [x] `_Get-UserPlaybook` — `ansible.builtin.user`;
      `create`→`present` with optional groups/shell; `remove`→`absent` + `remove:true` + `force:true`
- [x] `_Get-FilePlaybook` — `ansible.builtin.copy` with owner, group, mode (default `0644`)
- [x] `_Get-DockerPlaybook` — `community.docker.docker_container` for
      container lifecycle (pull, start, stop, restart, recreate, remove);
      `recreate` adds `recreate:true`+`pull:true`; `restart` adds `force_kill:true`;
      default host group is `containers`
- [x] All playbooks: `become:true`, `gather_facts:false`, FQCN module names
- [x] Suite 24 (Ansible playbook builder) — 15 checks (24a–24o), fully offline;
      local `_Get-FltAnsiblePlaybookDir` override redirects writes to temp dir:
      14a–14d package builder · 14e–14g service builder · 14h–14j user builder ·
      14k file builder · 14l–14n container builder · 14o return shape
- [x] Security: no secrets in generated YAML; `ansible/playbooks/` gitignored
- [x] `.gitignore`: `ansible/playbooks/` already covered — no new entries needed
- [x] `README.md`: Phase 5.3 section added

### 5.4 — Ansible executor (`execution/AnsibleExecutor.ps1`) ✅

- [x] `Invoke-FltAnsibleBatch` — 7-step executor:
      read-only fast path → availability check → inventory → playbook →
      `ansible-playbook --one-line -o json --forks <n>` via `cmd /c` →
      `_Parse-AnsibleOutput` → `$OnProgress` callback → cleanup → `Write-FltBatchEntry`
- [x] `_Parse-AnsibleOutput` — parses `--one-line -o json` per-host lines:
      `SUCCESS`/`CHANGED`→`OK`, `FAILED!`→`Failed`, `UNREACHABLE!`→`Unreachable`;
      extracts `msg` and `task` from JSON payload into `Note`
- [x] Exit code mapping: `0`=OK, `2`=failures, `4`=unreachable, `6`=both, `8`=config error
- [x] `Write-FltBatchEntry` with `PackageManager = 'ansible'`
- [x] `ansible.forks` already in `settings.default.json` (default 10) — no change needed
- [x] Suite 25 (Ansible batch executor) — 13 checks (25a–25m), fully offline:
      15a–15d read-only mode · 15e–15f BatchResult shape ·
      15g–15k parser (SUCCESS/CHANGED/FAILED/UNREACHABLE/exit-8) ·
      15l mixed output · 15m OnProgress callback
- [x] Security: no secrets in playbook runs; temp files cleaned up after every run
- [x] `.gitignore`: all ansible/ paths already covered — no new entries needed
- [x] `README.md`: Phase 5.4 section added

### 5.5 — Route Ansible targets in `Invoke-FleetAction` (`execution/FleetExecutor.ps1`) ✅

- [x] `$ansibleTargets` bucket: `OS='linux'` AND `TargetType != 'container'`;
      separated first before Windows bucket logic runs
- [x] `$windowsTargets` — all non-Ansible targets; feeds existing tcpkg/winget/push
      routing unchanged
- [x] No feed check for Ansible targets
- [x] No push bucket for Linux
- [x] Ansible bucket execution: `Invoke-FltAnsibleBatch` with
      `_Get-PackagePlaybook` as `$PlaybookBuilder`
- [x] Read-only mode: `[read-only] would run ansible: <Action> <PackageSpec>`
- [x] Unrouted-targets catch: targets landing in no bucket receive
      `Status='Unsupported'`, `PackageManager='none'` — never silently dropped
- [x] Merge results into `$allResults`
- [x] Suite 26 (Fleet executor routing) — 10 checks (26a–26j), fully offline
      via read-only mode:
      16a–16b Linux physical/VM→Ansible · 16c container→Unsupported ·
      16d Windows not Ansible · 16e tcpkg · 16f WinGet · 16g push ·
      16h mixed fleet · 16i PackageManager field · 16j no silent drops
- [x] Security: no new secrets or credential handling
- [x] `.gitignore`: no new entries needed
- [x] `README.md`: Phase 5.5 section added

### 5.6 — Ansible Vault integration (`execution/AnsibleExecutor.ps1`) ✅

- [x] `_Get-VaultPasswordFile` — retrieves vault password from
      `Get-FltStoredPassword -CredentialName 'ansible_vault'`; writes it to a
      `*.tmp` file in the system temp directory; tightens permissions (Windows
      ACL / Linux `chmod 600`); returns `$null` when no password is stored
- [x] `Invoke-FltAnsibleBatch` — passes `--vault-password-file` when
      `_Get-VaultPasswordFile` returns a path; omits flag entirely when `$null`;
      deletes temp file in step 6 cleanup alongside inventory and playbook files
- [x] `Invoke-FltVaultSetup` — interactive setup: detects existing password,
      prompts with confirmation entry, saves via
      `Set-FltStoredPassword -CredentialName 'ansible_vault'`;
      returns `[pscustomobject]@{ Ok; Message }`
- [x] Vault files (`ansible/group_vars/`, `ansible/host_vars/`) are NOT
      gitignored — AES-256 encrypted files are safe to commit
- [x] `*.tmp` already in `.gitignore` — covers vault temp file; no new entries
- [x] Suite 27 (Ansible Vault helpers) — 8 checks (27a–27h), fully offline:
      17a null when no password · 17b temp file created · 17c content matches ·
      17d .tmp extension · 17e system temp location · 17f deletable ·
      17g fresh file on second call · 17h Invoke-FltVaultSetup defined
- [x] Security: vault password never written to playbook or inventory;
      temp file restricted to current user; deleted immediately after run
- [x] `README.md`: Phase 5.6 section added with vault setup and rotation docs

---

## Phase 6 — Ansible UI

### 6.1 — Fleet menu (`ui/menus/FleetMenu.ps1`) ✅

> Current menu (after Phase 4): `1. tcpkg  2. WinGet  3. Profiles  4. UI Config  5. Setup`
> After Phase 6: `1. tcpkg  2. WinGet  3. Linux Admin  4. Profiles  5. UI Config  6. Setup`

- [x] `3. Linux Admin` added; Profiles→4, UI Config→5, Setup→6
- [x] Dashboard footer updated — 89 chars, within 119 col limit
- [x] `FleetMenu.ps1` dispatch: `3`→`Invoke-LinuxAdminMenu`, `4`→`Invoke-ProfileMenu`,
      `5`→`Invoke-UiConfigMenu`, `6`→`Invoke-SetupMenu`; error hint updated to `1-6`
- [x] No tests required — pure UI wiring; `Invoke-LinuxAdminMenu` implemented in Phase 6.2
- [x] `README.md`: Phase 6.1 noted in menu structure section

### 6.2 — Linux Admin menu (`ui/menus/LinuxMenu.ps1`) — new file ✅ (implemented, untested pending Linux target)

```
 TcFlt Package Manager  |  Linux Admin                           [LIVE]
  #    Name           Address         Port   OS   Type   Status
  11.  DCC-Linux-1    192.168.8.110   22     Lnx  Phys   online
  12.  DCC-Linux-2    192.168.8.111   22     Lnx  VM     online
─────────────────────────────────────────────────────────────────────
  1. Install package   2. Upgrade package   3. Remove package
  4. Manage users      5. Manage services   6. Run playbook
  0. Back
─────────────────────────────────────────────────────────────────────
  Choice:
```

- [x] `Invoke-LinuxAdminMenu` — filters to `OS -eq 'linux'` AND
      `TargetType -ne 'container'`; shows message if none configured
- [x] Dashboard paginated if >20 Linux targets

### 6.3 — Package sub-menu (choices 1/2/3) ✅ (implemented, untested pending Linux target)

- [x] `Invoke-LinuxInstallMenu` — name prompt → target selection → batch
- [x] `Invoke-LinuxUpgradeMenu`
- [x] `Invoke-LinuxRemoveMenu`
- [x] All route through `_Invoke-AnsibleBatchAction`

### 6.4 — User management sub-menu (choice 4) ✅ (implemented, untested pending Linux target)

```
  1. Add user
  2. Remove user
  3. Add to group
  4. Set password
  0. Back
```

- [x] Each option prompts for fields then calls `Invoke-FltAnsibleBatch`
      with the `user` playbook template

### 6.5 — Service management sub-menu (choice 5) ✅ (implemented, untested pending Linux target)

```
  1. Start service
  2. Stop service
  3. Restart service
  4. Enable on boot
  5. Disable on boot
  0. Back
```

- [x] Prompts for service name; runs `systemd` playbook template

### 6.6 — Run playbook (choice 6) ✅ (implemented, untested pending Linux target)

- [x] Prompt for `.yml` file path; validate exists; run via
      `ansible-playbook` against selected targets; show batch dashboard

---


### 6.7 — Live testing (VMware Debian VM) (in progress)

> **Target:** VMware Debian 12 VM at 192.168.223.128, user Administrator.
> `tcflt-ansible` container on operator PC, key-based auth, NOPASSWD sudo.
>
> **Bugs found and fixed during live testing (2026-06-24):**
> - `--one-line -o json` flags invalid for `ansible-playbook` (ad-hoc only) — removed
> - PLAY RECAP parser rewritten to match `ansible-playbook` text output format
> - `$host` reserved PS7 variable used in parser — renamed to `$recapHost`
> - Target names with spaces (e.g. "Beckhoff RT Linux") break Ansible INI inventory
>   — names now sanitised to underscores for INI alias; IP used for PLAY RECAP matching
> - `[linux:children]` meta-group only written when 2+ groups existed
>   — now always written so `hosts: linux` resolves with a single VM target
> - `ansible_ssh_private_key_file` not written to inventory in Docker mode
>   — now always set to `/root/.ssh/id_ed25519` in Docker mode
> - `ansible_become=true` not in inventory — now always written for Linux targets
> - `Dockerfile.ansible` had no SSH keypair — `ssh-keygen` now runs at build time;
>   public key exported to `ansible/tcflt-ansible.pub` on container startup

- [x] Install a package on one Linux target via Linux Admin > Install package
- [x] Upgrade a package on one Linux target
- [x] Remove a package on one Linux target
- [x] Add a user (with groups) to one Linux target
- [x] Start/stop a service on one Linux target (`nginx` — `cron` not installed on this VM)
- [x] Run a custom playbook file against a Linux target
- [ ] Run install across 3+ Linux targets simultaneously (blocked — only 1 Linux target)

> **Bugs fixed in AnsibleExecutor.ps1 during live testing:**
> - `--one-line -o json` invalid for `ansible-playbook` — removed; PLAY RECAP
>   parser rewritten for text output format
> - `$host` PS7 reserved variable in parser — renamed `$recapHost`
> - Target names with spaces break Ansible INI — sanitised to underscores;
>   IP used for PLAY RECAP result matching
> - `[linux:children]` only written with 2+ groups — now always written
> - `ansible_ssh_private_key_file` missing in Docker mode — always set to
>   `/root/.ssh/id_ed25519`; `ansible_become=true` always written
> - Playbook closure scope bug in `Invoke-LinuxPlaybookMenu` — replaced with
>   `-PlaybookPath` parameter on `_Invoke-AnsibleBatchAction`
> - Cleanup deleted user-supplied playbooks — now only deletes files matching
>   generated timestamp pattern `<action>-<timestamp>.yml`
> - `Dockerfile.ansible` had no SSH keypair — `ssh-keygen` runs at build time
>
> **Integration test suite (Suite 37):** To be written once all items above are
> confirmed working. Suite 37 will be a live suite requiring SSH + Ansible.
> Suite numbers 31-36 are taken; next free number is 37.
> Note: original plan referenced "Suite 31 Linux Admin live" — that number is
> now used by Phase 8.0 pre-work.
>
> **Security:** No hardcoded secrets. `README.md` updated with Ansible prerequisites.

---

## Phase 7 — Docker container support

> **Note:** Phase 7 (Docker) is independent of Phases 5 and 6 (Ansible/Linux).
> It can be implemented in parallel or before Phases 5/6 if Docker support is
> higher priority. The only ordering constraint is Phase 8 must follow Phase 7.

### 7.0 — Batch dashboard pagination ✅
> *(Deferred from Phase 0.1 — needed at container scale with 100+ targets)*

- [x] `_Ansi_ShowFleetBatchDashboard` — calculates `$totalPages = ceil(n / pageSize)`;
      sets `$Script:FltBatchPage/PageSize/TotalPages/Targets`; height fixed to page size
- [x] `_Ansi_RepaintBatchDashboard` — new function; paints current page only;
      mode line shows `Page N/M  (- prev  + next)` when multi-page
- [x] `_Ansi_UpdateBatchRow` — page-aware: only paints target row if on current page;
      summary row always updated with all-target totals
- [x] Auto-scroll to first non-OK row on current page after each repaint
- [x] `Invoke-FltBatchPageNav` (private) — changes page and triggers repaint
- [x] `Move-FltBatchPage` (DisplayAdapter) — public wrapper; no-op when `TotalPages=1`
- [x] Four new script-scope vars initialised in `TcFltPkgMgr.ps1`:
      `FltBatchPage`, `FltBatchPageSize`, `FltBatchTotalPages`, `FltBatchTargets`
- [x] Suite 30 (Batch dashboard pagination) — 8 checks (30a–30h), fully offline:
      30a–30b page count · 30c–30d navigation · 30e–30f boundary clamp ·
      30g single-page no-op · 30h cross-page summary counts
- [x] Security: no new secrets or credential handling
- [x] `.gitignore`: no new entries needed
- [x] `README.md`: Phase 7.0 section added

### 7.1 — Container executor (`execution/ContainerExecutor.ps1`) — new file ✅

Containers are reached via a two-hop model: SSH to the Docker host, then
`docker exec` into the container. This avoids requiring SSH inside containers.

- [x] `Invoke-FltDockerExecBatch` — parallel SSH to each container's
      `DockerHost`, wraps every command as
      `docker exec -i <ContainerName> <command>`
- [x] `Invoke-FltDockerLifecycleBatch` — runs `docker` commands directly on
      the host (not inside the container):
      `docker pull`, `docker stop`, `docker start`, `docker restart`,
      `docker rm`, `docker run`
- [x] For package operations inside containers: command becomes
      `docker exec -i <ContainerName> apt-get install -y <package>` (or
      `apk`, `yum` etc. based on `PackageManager`)
- [x] `BatchResult.Note` for containers includes the container name
- [x] `Write-FltBatchEntry` with `PackageManager = 'docker-exec'` or
      `'docker-lifecycle'`

> **TwinCAT XAR containers:** Package management inside a TwinCAT XAR container
> uses `apt` pointed at `deb.beckhoff.com` (not tcpkg). The image is built on
> the Beckhoff RT Linux IPC using myBeckhoff credentials. Setting
> `PackageManager='apt'` on an XAR container target is correct.
> XAR containers are documented as requiring the Beckhoff RT Linux kernel.
> Whether they start on a standard Debian VM or Docker Desktop (WSL2) is
> untested - they may start but fail to achieve real-time performance, or
> fail at runtime when accessing RT hardware. Treat as unverified.

### 7.2 — Route container targets in `Invoke-FleetAction` (`execution/FleetExecutor.ps1`) ✅

- [x] `$containerTargets` bucket: `TargetType -eq 'container'`; separated before Windows buckets — `TargetType -eq 'container'`
- [x] Package install/upgrade/remove → `Invoke-FltDockerExecBatch`
- [x] No feed check, no push bucket for containers
- [x] Merge results into `$allResults`

### 7.3 — Docker connection check ✅

- [x] `Test-FltDockerHostReachable` — SSHes to Docker host, runs `docker info`
- [x] Returns `'online'` (exit 0), `'docker-down'` (daemon down), `'offline'` (SSH failed)
- [x] Suite 28 (Container executor) — 13 checks (28a–28m), fully offline:
      28a–28c pkg cmd mapping · 28d–28g exec read-only · 28h–28i lifecycle read-only ·
      28j–28k fleet routing · 28l result shape · 28m function existence
- [x] Security: no hardcoded secrets; SSH credentials passed through, never stored
- [x] `.gitignore`: no new entries needed
- [x] `README.md`: Phase 7 section added

### 7.4 — Add container target flow (`ui/menus/TargetMenu.ps1`) ✅

- [x] `Invoke-TargetMenu` (Add New Target) now prompts for target type:
      `1. Physical`, `2. VM`, `3. Docker container`
- [x] Container branch: prompts Docker host (validated against fleet) +
      container name + package manager (`apt`/`apk`/`yum`/`dnf`, default `apt`);
      skips Address/Port/User (inherited from host); skips Internet Access
- [x] Validation: Docker host must exist in fleet and must not itself be a container
- [x] `EffectiveAddress()` / `Get-FltEffectiveAddress` returns `<host>/<container>`
- [x] Physical/VM branch: sets `TargetType` after `Add-FleetTarget`
- [x] Standalone wrappers added to `classes/Models.ps1`:
      `Get-FltEffectiveAddress`, `Get-FltIsContainer`, `Get-FltTypeDisplay`, `Get-FltOsDisplay`
- [x] Suite 29 (Container target flow) — 8 checks (29a–29h), fully offline:
      29a–29b EffectiveAddress · 29c–29d IsContainer · 29e–29f DockerHostTarget ·
      29g fleet routing exclusion · 29h TypeDisplay
- [x] Security: no hardcoded secrets; host validation prevents orphan containers
- [x] `.gitignore`: no new entries needed
- [x] `README.md`: Phase 7.4 section added

---

## Phase 8 — Container Admin UI

### 8.0 — Pre-work before ContainerMenu

Three items are unblocked by Phase 7 and should be done before writing ContainerMenu.

**Lesson from Phase 6:** `$PlaybookBuilder` scriptblock closures capture variables
from outer scope by reference in PS7. In `_Invoke-AnsibleBatchAction`, `$pkg` must
be captured before passing to the scriptblock. Apply the same pattern in
`ContainerMenu.ps1` for all `$PlaybookBuilder` and `$DockerArgs` captures.


- [x] **`-`/`+` key wiring in batch menus** — `WinGetMenu`, `LinuxMenu`, and `ContainerMenu`
      need a non-blocking key poll loop during batch runs so `Move-FltBatchPage` is
      actually reachable. Currently `Invoke-FleetMenu` polls but batch menu callers do not.
      Add a lightweight polling helper to `_Invoke-AnsibleBatchAction` and the
      WinGet equivalent.
- [x] **`TargetType` in `CommandLog.ps1`** — Phase 7 is done; this item is now unblocked.
      Add `targetType` field to `Write-FltBatchEntry` output, derived from `$Results`.
- [x] **`Type` column in batch dashboard rows** — Phase 2.3 deferred item; add
      `TypeDisplay()` / `Get-FltTypeDisplay` to the `_Ansi_UpdateBatchRow` line format.
      Requires narrowing the target name column slightly (22 → 18 chars).

- [x] Stored `$Script:FltBatchAction/PackageSpec/Mode/TimeoutSecs` in
      `_Ansi_ShowFleetBatchDashboard`; `_Ansi_RepaintBatchDashboard` falls
      back to stored vars when called with empty args (fixes page nav repaint)
- [x] `Read-FltBatchNav` added to `DisplayAdapter.ps1` — post-batch
      `-`/`+` navigation loop before Enter; no-op on single-page results
- [x] `Read-FltBatchNav` wired into `WinGetMenu.ps1` and `LinuxMenu.ps1`
- [x] Suite 31 (Phase 8.0 pre-work) — 8 checks (31a–31h), fully offline:
      31a action vars · 31b repaint no-op · 31c–31d function existence ·
      31e–31f targetType field · 31g TypeDisplay · 31h header format
- [x] Security: no hardcoded secrets
- [x] `.gitignore`: no new entries needed
- [x] `README.md`: Phase 8.0 section added

### 8.1 — Fleet menu (`ui/menus/FleetMenu.ps1`) ✅

> Current menu: `1. tcpkg  2. WinGet  3. Linux Admin  4. Profiles  5. UI Config  6. Setup  0. Exit`
> After Phase 8: `1. tcpkg  2. WinGet  3. Linux Admin  4. Containers  5. Profiles  6. UI Config  7. Setup`

- [x] Add `4. Containers`; Profiles→5, UI Config→6, Setup→7
- [x] Final menu layout:
      ```
       1. tcpkg        3. Linux Admin   5. Profiles
       2. WinGet       4. Containers    6. UI Config    7. Setup    0. Exit
      ```
- [x] Footer fits single line at 119 cols

### 8.2 — Container Admin menu (`ui/menus/ContainerMenu.ps1`) — new file ✅

```
 TcFlt Package Manager  |  Containers                            [LIVE]
  #    Name          Host            Container     Status
  11.  web-1         docker-host-1   web_app       online
  12.  web-2         docker-host-1   web_app_2     online
  13.  db-1          docker-host-2   postgres      online
  ...  (up to 90+ container targets, paginated)
──────────────────────────────────────────────────────────────────────
  1. Install package   2. Remove package   3. Pull image
  4. Start            5. Stop             6. Restart
  7. Recreate         8. View logs        9. Health check
  0. Back
──────────────────────────────────────────────────────────────────────
  Choice:
```

- [ ] `Invoke-ContainerAdminMenu` — filters to `TargetType -eq 'container'`;
      paginates (likely needed immediately at this scale)
- [ ] Dashboard columns: `#`, `Name`, `Host` (DockerHost), `Container`
      (ContainerName), `Status`
- [ ] Status reflects Docker container state, not TCP reachability

### 8.3 — Package operations (choices 1/2) ✅

- [x] `Invoke-ContainerInstallMenu` — package name → target selection →
      `Invoke-FltDockerExecBatch` with `apt-get install -y <package>`
- [x] `Invoke-ContainerRemoveMenu` — same with `apt-get remove -y`
- [x] Target selection filtered to containers only; base-11 on dashboard

### 8.4 — Image management (choice 3) ✅

- [x] `Invoke-ContainerPullMenu` — prompts for image name/tag → runs
      `docker pull <image>` on the Docker host (not inside container) →
      batch dashboard showing per-host results

### 8.5 — Lifecycle operations (choices 4-7) ✅

- [x] Start, Stop, Restart — single prompt for target selection, then
      `docker start/stop/restart <ContainerName>` on the host
- [x] Recreate — stop + remove + run with stored `docker run` parameters.
      For now: prompt for the full `docker run` command to re-use.
      Future: store run parameters in `targets.local.json`.

### 8.6 — Logs (choice 8) ✅

- [x] `Invoke-ContainerLogsMenu` — single target selection (one container at
      a time), then SSH to host and run `docker logs --tail 50 <container>`;
      display in scrollable output below the dashboard

### 8.7 — Health check (choice 9) ✅

- [x] `Invoke-ContainerHealthMenu` — batch SSH to all Docker hosts, runs
      `docker inspect --format='{{.State.Health.Status}}' <container>` for
      each container; shows results in dashboard (healthy / unhealthy /
      starting / none)

- [x] Suite 32 (Container Admin menu) — 10 checks (32a–32j), fully offline:
      32a admin menu defined · 32b target filter · 32c–32d read-only ·
      32e fleet routing · 32f–32i function existence · 32j mixed fleet routing
- [x] `Read-FltBatchNav` wired into `ContainerMenu.ps1`
- [x] Closure variable capture applied: `$capturedPkg`, `$capturedArgs`,
      `$capturedAction` all captured before scriptblock use
- [x] Security: no hardcoded secrets; SSH credentials never stored
- [x] `.gitignore`: no new entries needed
- [x] `README.md`: Phase 8 Container Admin section added

### 8.8 — Compose infrastructure ✅

- [x] `FleetTarget` — 3 new fields: `ComposeFile`, `ComposeService`, `ComposeProject`
- [x] `settings.default.json` — new `compose` section: dir, network, subnet, gateway
- [x] `.gitignore` — `compose/*.yml`, `compose/*.yaml`, `compose/*.csv` gitignored;
      `compose/templates/` committed source
- [x] `docker/Dockerfile.debian-ssh` — debian:bookworm-slim + openssh-server + python3;
      root login enabled; ROOT_PASSWORD via --build-arg stored in credential store
- [x] Three templates in `compose/templates/` with `{{VARIABLE}}` substitution:
      `twincat-xar.yml.template` · `mosquitto.yml.template` · `debian-ssh.yml.template`
- [x] `data/ComposeRepository.ps1` — 13 functions covering template discovery,
      service parsing, single-file generation, CSV batch import/export,
      and docker compose execution (pull, up, stop)
- [x] Suite 33 (Compose repository) — 10 checks (33a–33j), fully offline:
      33a–33b template discovery · 33c service parsing · 33d–33f template generation ·
      33g–33h CSV batch import · 33i–33j network definition helper
- [x] Security: no hardcoded secrets
- [x] `README.md`: Phase 8.8 compose infrastructure section added

### 8.9 — Updated Add Target flow (compose-aware container branch) ✅

- [x] Container Add flow prompts: `1. From existing compose file`  `2. Create from template`  `3. Import from CSV`
- [x] Template path: pick template → prompt variables → generate `compose/<name>.yml` → pick services
- [x] Existing file path: browse `compose/` → pick `.yml` → pick service
- [x] CSV path: import CSV → generate compose file → register all services
- [x] After registration: pull images then `docker compose up -d`
- [x] `ComposeFile`, `ComposeService`, `ComposeProject` set on each registered target

- [x] Suite 34 (Container target registration) — 8 checks (34a–34h), fully offline:
      34a target added · 34b fields · 34c address inheritance · 34d compose fields ·
      34e duplicate guard · 34f __local__ host · 34g all path functions · 34h deploy function
- [x] `IntegrationTests.ps1` split into 5 files by subsystem:
- [x] `IT-Containers.ps1` (Suite 31, 32) — all suites now save/restore
      `$Script:FleetTargets` using `$savedFleetTargets`; Suite 34 also
      saves/restores `targets.local.json` to prevent synthetic test targets
      persisting to disk across sessions
- [x] `DisplayAdapter.ps1` (`Read-FltBatchNav`) — skips blocking input when
      `$Script:FltReadOnly` or `[Console]::IsInputRedirected` (prevents hangs)
- [x] `TestRunner.ps1` — auto-continues on all-pass; pauses only on failure/warning
      `IT-Infrastructure.ps1` (6 suites) · `IT-TcpkgWinGet.ps1` (4) ·
      `IT-Ansible.ps1` (7) · `IT-Containers.ps1` (7)
      `IntegrationTests.ps1` is now the thin header with helpers + dot-sources
- [x] Security: no hardcoded secrets
- [x] `README.md`: Phase 8.9 section added

### QOL improvements (alongside Phase 8.9) ✅

- [x] `TestRunner.ps1` — auto-continues between suites when all checks pass;
      pauses only on failure or warning; 400 ms sleep on all-pass so result is visible
- [x] `DisplayAdapter.ps1` (`Read-FltBatchNav`) — skips blocking input when
      `$Script:FltReadOnly` is true or `[Console]::IsInputRedirected` (prevents test hangs)
- [x] `IT-Containers.ps1` (Suite 34) — saves and restores `targets.local.json`
      so synthetic test targets are not persisted to disk
- [x] `IntegrationTests.ps1` split into 5 files by subsystem (see Phase 8.9 notes)

### 8.10 — Updated Container Admin menu (compose-aware) ✅

- [x] Pull (3) → `docker compose pull <service>` (when ComposeFile set)
- [x] Start/Stop/Restart (4/5/6) → `docker compose start/stop/restart <service>`
- [x] Recreate (7) → `docker compose up -d --force-recreate <service>`
- [x] New: Deploy (choice 10) → `docker compose up -d <service>` (first-time creation)
- [x] Fallback to direct docker CLI when `ComposeFile` is empty

- [x] `_Get-TargetComposeFile` — resolves ComposeFile to absolute path;
      returns `''` when not set or file missing from disk
- [x] `_Invoke-ComposeOrDockerAction` — groups compose targets by file,
      runs one `docker compose` call per file; falls back to docker CLI for non-compose targets
- [x] `Invoke-ContainerDeployMenu` (choice 10) — first-time creation;
      detects build: stanzas and offers --build; groups by compose file
- [x] Suite 35 (Phase 8.10 compose-aware lifecycle) — 8 checks (35a–35h), fully offline:
      35a–35b ComposeFile path resolution · 35c–35d action routing read-only ·
      35e–35g function existence · 35h admin menu dispatch
- [x] Security: no hardcoded secrets
- [x] `README.md`: Phase 8.10 section added

---

## Phase 9 — Setup menu updates

### 9.1 — Add target: OS/PackageManager prompts (physical and VM targets) ✅

> **Already completed in earlier phases:**
> - TargetType prompt (Physical/VM/Container) - done in Phase 7.4
> - Container branch (DockerHost, ContainerName, compose flow) - done in Phase 8.9
>
> **Active bug:** Adding a Debian VMware VM today silently sets OS='windows',
> routing it to tcpkg/WinGet buckets instead of Ansible. This must be fixed.

- [x] `OS: 1. Windows  2. Linux  (default = Windows):` prompt for Physical/VM
      targets after TargetType; skip for containers (always Linux)
- [x] If Windows: `Package manager: 1. tcpkg  2. WinGet  3. Both  (default 1):`
- [x] If Linux or VM: skip Internet Access prompt
- [x] Edit flow: show current OS/TargetType/PackageManager, allow changes
- [x] Add `OS`, `Type`, `PackageManager` columns to Setup dashboard
- [x] `IT-Infrastructure.ps1` Suite 36 (OS/PM prompts) — 8 checks (36a–36h),
      fully offline: OS field storage (36a–36b), PM field (36c), Ansible routing
      (36d–36e), Edit-FleetTarget params (36f), EffectivePackageManager (36g–36h)
- [x] `DashboardAnsi.ps1` — PM column added to Setup dashboard
- [x] Security: no hardcoded secrets
- [x] `README.md`: Phase 9.1 section added

### 9.x — System menu (Fleet → 8. System) ✅

New top-level fleet menu item alongside tcpkg, WinGet, Linux Admin, Containers.

- [x] `ui/menus/SystemMenu.ps1` — new file
- [x] `Invoke-FltStartupCheck` — Docker Desktop detection + 60s countdown retry
      (Escape/Q to skip); auto-start `tcflt-ansible`; SSH probe all Linux + Windows targets
- [x] `Invoke-FltHealthCheck` — read-only snapshot of same checks
- [x] `Invoke-SystemMenu` — submenu with choices 1 (startup) and 2 (health)
- [x] `FleetMenu.ps1` — choice 8 dispatches to `Invoke-SystemMenu`
- [x] `DashboardAnsi.ps1` — footer updated: `8. System` added
- [x] `TcFltPkgMgr.ps1` — `SystemMenu.ps1` added to module loader
- [x] Security: no hardcoded secrets
- [x] `README.md`: System menu section added

> **VMware VM disk encryption note:**
> If the VM was installed with full-disk encryption (LUKS), the startup check
> can power on the VM via `vmrun start` but SSH will not be available until
> the LUKS passphrase is entered at the console. There is no safe way to
> automate this without compromising the encryption.
>
> **Option B — Dropbear initramfs (future improvement):**
> Install `dropbear-initramfs` on the VM to enable a tiny SSH server that
> starts before LUKS decryption. The startup check could then:
> 1. SSH to the VM on port 22 (Dropbear)
> 2. Run `cryptroot-unlock` and pipe the passphrase (retrieved from the
>    TcFltPkgMgr Vault)
> 3. Wait for the VM to finish booting and SSH to become available
> This requires the LUKS passphrase to be stored in the Vault (Phase 5.6)
> and Dropbear configured with the `tcflt-ansible` public key.
> For now: reinstall VM without disk encryption (Option A).

### 9.2 — Prerequisites check (`diagnostics/Diagnostics.ps1`) ✅

> Integrated into the existing Diagnostics screen (Setup → 10. Tests → 1. All
> diagnostics) as a new **External tools** section. Total checks: 35 (was 29).

- [x] `docker` CLI available and daemon running
- [x] `tcflt-ansible` container running + `ansible-playbook` version check
- [x] Ansible collection `community.docker` installed in container
- [x] `winget` available (Windows only; WARN if missing)
- [x] `Posh-SSH` module version (moved from Core subsystems)
- [x] `vmrun.exe` available at VMware Workstation path (WARN if missing)
- [x] All checks WARN (not FAIL) for missing optional tools
- [x] `vmrun.exe` path built with `Join-Path` (avoid `\v` escape in double-quoted strings)
- [x] Security: no hardcoded secrets
- [x] Diagnostics count: 29 → 35 (6 new external tool checks)

### 9.3 — Settings for new executors (`config/settings.default.json`)

> `docker` (throttleLimit=20, logTailLines=50) and `ui` (dashboardPageSize=20,
> reachCacheSecs=60) sections already exist. Remaining: `winget` and `ansible`.

- [x] `docker.throttleLimit: 20` — already in `settings.default.json`
- [x] `docker.logTailLines: 50` — already in `settings.default.json`
- [x] `ui.dashboardPageSize: 20` — already in `settings.default.json`
- [x] `ui.reachCacheSecs: 60` — already in `settings.default.json`
- [x] `winget` section — implement in Phase 4.4 bug fixes (Phase 3 is done)
- [x] `ansible` section — done in Phase 5.0
- [ ] `settings.default.jsonc` — add when the above sections are added

---

## Phase 10 — Command log updates

### 10.1 — `Write-FltBatchEntry` (`execution/CommandLog.ps1`) ✅

> Depends on Phases 3, 5, 7 (WinGet, Ansible, Docker executors) being built
> first so the new PackageManager values are actually emitted.
> Implement incrementally: add `PackageManager` when Phase 3 lands,
> add `TargetType` when Phase 7 lands.

- [x] `PackageManager` field — implement in Phase 4.4 bug fixes (Phase 3 is done)
- [x] Add `TargetType` field per result row — completed in Phase 8.0

### 10.2 — Log viewer ✅

- [x] `PackageManager` and `TargetType` columns added to log table
- [x] PM filter matches both `packageManager` field (batch events) and
      command prefix (direct tcpkg/winget/ansible/docker entries)
- [x] `TargetType` filter matches batch result entries
- [x] Active filters shown above the table; entry count displayed
- [x] Setup → 8. Log prompts for PM and Type filters in addition to
      days/target/verb
- [x] Security: no hardcoded secrets
- [x] `README.md`: Phase 10.2 section added

---

## Phase 10.5 — Test runner and integration tests ✅

> Implemented ahead of Phase 11 to enable ongoing integration testing
> as each phase is completed. Replaces the single-button `Setup > 10. Diagnostics`
> launcher with a full test dashboard.

### 10.5.1 — Test infrastructure ✅

- [x] `diagnostics/IntegrationTests.ps1` — 6 integration test suites
- [x] `diagnostics/TestRunner.ps1` — unified test dashboard, numpad-only input
- [x] `Setup > 10` launches `Invoke-FltTestRunner`
- [x] `config/test-results.json` stores last-run history per suite (gitignored)
- [x] Multi-target selection via `101+` with range syntax (`21,23` / `21-24` / `21..24`)
- [x] Per-target suites (SSH, Reachability) loop over all selected targets
- [x] Singleton suites (File I/O, Pagination, Read-only, Log) run once regardless
- [x] `Get-FltTestResultsPath`, `Get-FltTestResults`, `Save-FltTestResult` helpers
- [x] All 28 reachability cache checks passed across 7 targets

### 10.5.2 — Integration test suites

| Suite | Id | Needs target | Tests |
|-------|----|--------------|-------|
| File I/O | I1 | No | CSV round-trip, sort persistence, filter correctness, UI Config persistence |
| Pagination | I2 | No | Page slicing, target numbering, sort-aware selection |
| SSH connectivity | I3 | Yes (SSH) | TCP check, session open, remote command, tcpkg path |
| Read-only mode | I4 | No | tcpkg blocked, batch status prefix, credentials exempt |
| Log system | I5 | No | Entry written, retrieved, retention preserves current log |
| Reachability cache | I6 | Optional | Cache skip, expiry, live population |

> **OsFilter support added (2026-06-25):**
> Suite metadata now includes `OsFilter = 'windows' | 'linux' | 'any'`.
> `_TR_RunIntSuite` filters targets to only those matching the suite OS before
> running. Suites 13, 17, 18, 19, 20 = `windows`; suites 21–27 = `linux`.
> When running all integration (option 9), Windows and Linux credentials are
> prompted separately so mixed fleets can run all suites in one pass.
> Tests 25i–25l updated to use PLAY RECAP output format (not JSON ad-hoc).
> Total checks: 225 (up from 205).

### 10.5.3 — Future integration suites (add as phases complete)

- [x] Phase 3: WinGet install via SSH (I7)
- [x] Phase 5: Ansible playbook execution (I8)
- [x] Phase 7: Docker exec batch (I9)
- [x] Phase 7: Docker container reachability check (I10)

---

## Phase 11 — Testing checklist

### Scale
- [ ] Load 100 targets from `targets.local.json` — startup time < 2s
- [ ] Dashboard pagination renders correctly at 20, 50, 100 targets
- [ ] Page navigation (`-`/`+` numpad) works without losing target numbering
- [ ] Reachability check completes for 100 targets in < 5s
- [ ] Batch dashboard with 100 targets paginates correctly

### WinGet
- [ ] Search, install, upgrade, uninstall on one Windows target
- [ ] Multi-target parallel WinGet install (10+ targets)
- [ ] Mixed batch: tcpkg + WinGet targets selected together
- [ ] Log entry correct with `PackageManager = 'winget'`

### Ansible / Linux
- [ ] Ansible available check — native and WSL mode
- [ ] Install, upgrade, remove package on one Linux target
- [ ] Install on 10+ Linux targets in parallel
- [ ] Add/remove user, manage group membership
- [ ] Start/stop/restart/enable/disable service
- [ ] Run custom playbook file
- [ ] Log entry correct with `PackageManager = 'ansible'`

### Docker containers
- [ ] Add container target referencing an existing Docker host target
- [ ] Reachability check (`docker info` + `docker inspect`) returns correct state
- [ ] Install package inside container via `docker exec apt-get`
- [ ] Pull new image on Docker host
- [ ] Stop/start/restart container
- [ ] Recreate container
- [ ] View last 50 log lines
- [ ] Health check across 10+ containers on 2+ hosts
- [ ] Batch operation across 50 containers — all complete, dashboard paginated

### TwinCAT XAR container kernel compatibility (unverified — needs testing)

> The Beckhoff documentation states XAR requires the Beckhoff RT Linux kernel,
> but whether the container image starts on other kernels is untested.
> Real-time performance will not be achievable without the RT kernel regardless.
> Run these tests in order — stop at first failure and record the error.

**Test 1 — VMware Debian VM (standard Linux kernel)**
- [ ] Install Docker Engine on the Debian VM
- [ ] Clone `https://github.com/Beckhoff/TC_XAR_Container_Sample` on the VM
- [ ] Add myBeckhoff credentials to `tc31-xar-base/apt-config/bhf.conf`
- [ ] Build: `docker build --secret id=apt,src=./apt-config/bhf.conf --network host -t tc31-xar-base .`
- [ ] Record: does the build succeed?
- [ ] If build OK: `docker run --privileged tc31-xar-base` — does it start?
- [ ] If started: record any error output, then test via TcFltPkgMgr deploy flow
- [ ] Record kernel version (`uname -r`) alongside result

**Test 2 — Windows PC with Docker Desktop (WSL2 kernel)**
- [ ] Prerequisite: Test 1 build succeeded (use same image or rebuild on Windows)
- [ ] On operator PC: `docker run --privileged tc31-xar-base`
- [ ] Record: does it start, and what errors appear?
- [ ] Check if `/dev/hugepages` is available in WSL2: `docker run --rm alpine ls /dev/hugepages`
- [ ] Record WSL2 kernel version (`wsl --status` or `uname -r` inside WSL2)

**Test 3 — Beckhoff RT Linux IPC (reference/expected-good)**
- [ ] Prerequisite: DCC-4 or DCC-5 converted to Beckhoff RT Linux
- [ ] Build and run using Beckhoff sample Makefile
- [ ] Confirm TwinCAT XAR appears as a target in TwinCAT XAE via ADS-over-MQTT
- [ ] Deploy and manage via TcFltPkgMgr (Add Target -> template -> twincat-xar)

**Expected outcomes to record for each test:**
- Build result (success / error message)
- Container start result (success / error message)
- Kernel version of the host
- Whether `/dev/hugepages` was accessible
- Whether TwinCAT XAR appeared in TwinCAT XAE

### Mixed fleet (full integration)
- [ ] Fleet with Windows/tcpkg, Windows/WinGet, Linux/Ansible, and
      container targets all selected in one batch
- [ ] Correct routing to all four executors simultaneously
- [ ] Batch dashboard shows all target types with correct notes and colors
- [ ] All result sets merged and logged correctly
- [ ] Summary row shows per-executor counts

---

## New files summary

| File | Status | Purpose |
|------|--------|---------|
| `config/targets.local.json` | ✅ exists | Primary target store — all target types (gitignored) |
| `ui/SortFilter.ps1` | ✅ exists | Sort/filter helpers and interactive pickers |
| `ui/menus/UiConfigMenu.ps1` | ✅ exists | Runtime UI settings (page size, display backend) |
| `diagnostics/Diagnostics.ps1` | ✅ exists | 29-check self-test suite (Setup > 10) |
| `data/WinGetRepository.ps1` | ✅ done | WinGet package search, version listing, remote install |
| `data/AnsibleRepository.ps1` | ✅ done | Ansible availability and collection checks |
| `execution/WinGetExecutor.ps1` | ✅ done | SSH batch executor using winget |
| `execution/AnsibleExecutor.ps1` | ✅ done | Inventory/playbook builder and Ansible runner |
| `execution/ContainerExecutor.ps1` | ✅ done | Docker exec and lifecycle batch executor |
| `ui/menus/WinGetMenu.ps1` | ✅ done | WinGet install / upgrade / uninstall / status |
| `ui/menus/LinuxMenu.ps1` | ✅ done | Linux Admin: packages, users, services, playbooks |
| `ui/menus/ContainerMenu.ps1` | ✅ done | Container Admin: packages, lifecycle, logs, health, deploy (Phase 8) |
| `data/ComposeRepository.ps1` | ✅ done | Compose template/CSV/generation/execution (Phase 8.8) |
| `docker/Dockerfile.debian-ssh` | ✅ done | Debian SSH container image with Python 3 (Phase 8.8) |
| `compose/templates/*.yml.template` | ✅ done | TwinCAT XAR, Mosquitto, Debian SSH templates (Phase 8.8) |
| `diagnostics/IT-Infrastructure.ps1` | ✅ done | Suites 11-16 split from IntegrationTests.ps1 |
| `diagnostics/IT-TcpkgWinGet.ps1` | ✅ done | Suites 17-20 split from IntegrationTests.ps1 |
| `diagnostics/IT-Ansible.ps1` | ✅ done | Suites 21-27 split from IntegrationTests.ps1 |
| `diagnostics/IT-Containers.ps1` | ✅ done | Suites 28-35 split from IntegrationTests.ps1 |

## Modified files summary

| File | Status | What changes |
|------|--------|-------------|
| `classes/Models.ps1` | ✅ done | `FleetTarget` extended with OS/Type/PackageManager/Docker fields |
| `data/TargetRepository.ps1` | ✅ done | JSON store; migration; CSV; Add/Edit/Remove |
| `data/CredentialRepository.ps1` | ✅ done | Refactored into adapter + Windows/file backends |
| `execution/FleetExecutor.ps1` | ✅ done | Five buckets: tcpkg + WinGet + push + Ansible + Docker/container |
| `execution/CommandLog.ps1` | partial | `PackageManager` and `TargetType` done; log viewer columns pending (10.2) |
| `ui/DashboardAnsi.ps1` | ✅ done | Pagination/sort/filter/batch-pagination/Type column all done |
| `ui/menus/FleetMenu.ps1` | ✅ done | 1-7: tcpkg, WinGet, Linux Admin, Containers, Profiles, UIConfig, Setup |
| `ui/menus/TargetMenu.ps1` | partial | Add/Edit/Remove done; container+compose done (7.4, 8.9); OS/PM prompt pending (9.1) |
| `config/settings.default.json` | ✅ done | docker, ui, winget, ansible, compose sections all present |
| `config/settings.default.jsonc` | pending | Add commented reference version alongside settings.default.json |
| `TcFltPkgMgr.ps1` | partial | OS detection done; Linux config paths pending (phase 12.1) |
| `ui/menus/ContainerMenu.ps1` | ✅ done | All 10 choices including compose-aware lifecycle and Deploy |
| `data/ComposeRepository.ps1` | ✅ done | 13 compose functions: templates, CSV import/export, docker compose exec |

---

## Lessons learned (Phases 3-8, apply to upcoming phases)

These patterns emerged during implementation and must be applied to all future phases.
They supplement the conventions at the top of this document.

**Test isolation:**
- Any suite that assigns `$Script:FleetTargets` must save as `$savedFleetTargets`
  and restore in cleanup. This applies even when the assignment is buried inside
  a helper function (e.g. `_Register-ContainerTarget` calls `Save-FltTargets`).
- Any suite that causes `Save-FltTargets` to run must also save/restore
  `targets.local.json` on disk. In-memory restore alone is insufficient.
- Any suite that modifies `$Script:FltBatch*` vars must save/restore each one.

**Blocking input in read-only/test mode:**
- Functions with `Read-Host` or `[Console]::ReadKey` in code paths reachable
  from tests must guard at the top with `if ($Script:FltReadOnly -or
  [Console]::IsInputRedirected) { return }`. Tests run with `FltReadOnly=$true`.

**PowerShell syntax traps:**
- `?.Trim()` null-conditional member access is unreliable in complex expressions.
  Assign the pipeline result to a variable first, then call `.Trim()` on it.
- `$list.Add([pscustomobject]@{...} | ForEach-Object {...})` fails.
  Build the object into a variable first, then call `.Add($var)`.
- Multi-line expressions ending with `)` inside `else {` blocks cause PS7 to
  close the block early. Break into separate statements.

**Docker Compose on Windows:**
- Use `cmd /c "docker compose ..."` not `& docker compose`. The latter fails
  when compose output contains CRLF or progress animations.
- Group targets by compose file before running; one `docker compose` call per
  file handles all its services atomically.
- Store `ComposeFile` as a relative path in `targets.local.json`; resolve to
  absolute via `$Script:FltScriptRoot` at runtime.

**Error surfacing:**
- `Invoke-FltComposeCommand` captures full docker output in `.Output`.
  Callers must explicitly display last 10-15 lines on failure.
  "Exit 1" alone tells the operator nothing.

**File output formats:**
- The `.template` extension causes the Claude outputs viewer to render blank.
  Present template files with `.yml` extension; instruct user to rename.

---

## Phase 12 — Linux operator support

Running the fleet manager itself on a Linux machine (the operator's workstation
or a CI/CD server). After Phase 0-A this requires only targeted work since the
abstraction layer handles most platform differences.

> **Prerequisites:** Phase 0-A must be complete — display adapter,
> credential backend abstraction, and cross-platform audit.

### 12.1 — Startup and config paths

- [ ] In `TcFltPkgMgr.ps1`, set config/log directories based on OS:
      ```powershell
      $Script:FltConfigDir = if ($IsWindows) {
          Join-Path $PSScriptRoot 'config'
      } else {
          # Prefer XDG_CONFIG_HOME if set, otherwise ~/.config
          $xdg = $env:XDG_CONFIG_HOME
          if ($xdg) { Join-Path $xdg 'tcfltpkgmgr' }
          else       { Join-Path $HOME '.config' 'tcfltpkgmgr' }
      }
      $Script:FltLogDir = if ($IsWindows) {
          Join-Path $PSScriptRoot 'logs'
      } else {
          Join-Path $HOME '.local' 'share' 'tcfltpkgmgr' 'logs'
      }
      ```
- [ ] Create config/log directories if they don't exist on first run
- [ ] `targets.local.json`, `target-meta.local.json`, `credentials.local.enc`
      all follow the same OS-based path logic

### 12.2 — Feature gating in menus

> **Note:** `Test-FltFeatureAvailable` and `$Script:FltFeatures` are already
> implemented (Phase 0-A.3). This phase wires them into the menu UI.
> The `[Windows only]` label was deferred from Phase 0-A.3.

- [ ] `Invoke-FleetInstallMenu` — check `Test-FltFeatureAvailable 'tcpkg-local'`
      before showing. On Linux, show:
      `[Windows only] tcpkg local operations require Windows.`
      `Remote tcpkg SSH installs still work — select targets to proceed.`
- [ ] `_Invoke-FleetBatchAction` — disable the push bucket on Linux
      (`Test-FltFeatureAvailable 'push-from-local'`); all targets route to SSH
- [ ] Sources / Feeds menu — on Linux, show read-only view of what feeds
      are configured in `feeds.local.json` with a note that adding/editing
      feeds requires running tcpkg on Windows. Disable choices 1 and 2.
- [ ] Setup > Add Target — on Linux, skip `tcpkg remote add` for all targets
      (write directly to `targets.local.json`); show advisory that tcpkg push
      operations won't be available for targets added this way

### 12.3 — Posh-SSH on Linux

- [ ] Verify Posh-SSH installs and works on Linux:
      `Install-Module Posh-SSH -Scope CurrentUser`
- [ ] Test `New-SSHSession`, `Invoke-SSHCommand`, `Remove-SSHSession` on Linux
      against both Windows and Linux remote targets
- [ ] Document any quirks in README (key file paths, known host handling)

### 12.4 — Ansible on Linux (native mode)

- [ ] On Linux, `Test-FltAnsibleAvailable` should find `ansible-playbook`
      natively (no WSL needed)
- [ ] `Get-FltAnsibleMode` returns `'native'` on Linux
- [ ] Test full Ansible batch flow from a Linux operator machine against
      Linux fleet targets

### 12.5 — Terminal compatibility

- [ ] Test ANSI dashboard in common Linux terminals:
      GNOME Terminal, Konsole, xterm, tmux, screen
- [ ] Test in SSH sessions (operator SSHing into a Linux jump host to run
      the tool) — cursor positioning must work in a nested SSH session
- [ ] Add `$env:TERM` detection: if `TERM` is `dumb` or unset, fall back
      to plain text output (no ANSI escape codes)
- [ ] Add `ui.forceAnsi` setting (bool) to override terminal detection

### 12.6 — Linux prerequisites check update

- [ ] Update `10. Check prerequisites` in Setup to show Linux-appropriate
      checks:
      - PS7 — version (always present if tool is running)
      - Posh-SSH — installed and version
      - Ansible — native, version
      - Python 3 — version (Ansible dependency)
      - community.docker collection
      - Docker CLI (for container operations)
      - SSH client (`ssh` binary) — for key-based auth testing
      - `ansible-playbook` in PATH
- [ ] Hide Windows-only checks (tcpkg, WinGet, Windows Credential Manager)

### 12.7 — Linux testing checklist

- [ ] Tool starts on Ubuntu 22.04 / Debian 12 with PS7
- [ ] Config and log dirs created in `~/.config/tcfltpkgmgr`
- [ ] Targets load from `targets.local.json`
- [ ] Fleet dashboard renders correctly in GNOME Terminal and tmux
- [ ] SSH to Windows target and run `tcpkg install` remotely — succeeds
- [ ] SSH to Linux target and run `apt-get install` via Ansible — succeeds
- [ ] Docker exec batch against containers — succeeds
- [ ] Credential backend (file-based) saves and retrieves SSH credentials
- [ ] Windows-only menu items show `[Windows only]` label and are non-functional
- [ ] Push-from-local correctly skipped (all targets use SSH bucket)

---

## Phase 13 — Dashboard evolution: decision point

> **This phase is a decision point, not an implementation checklist.**
> Revisit after Phase 11 testing is complete and the full fleet (100 targets,
> mixed OS/type) is in production use. The goal is to evaluate whether the
> ANSI dashboard is sufficient or whether a richer UI is warranted.

### Context

The display adapter introduced in Phase 0-A means the dashboard can be
replaced without touching any executor or menu code. The question is which
direction to go and when.

### Signals that suggest staying with ANSI

- The tool is used primarily over SSH by sysadmins comfortable with
  terminal interfaces
- Pagination (Phase 0.1) adequately handles 100+ targets
- The batch dashboard live-update experience is smooth enough
- No significant complaints about the display from operators

### Signals that suggest moving to Spectre.Console or C#

- Operators frequently miss updates in the batch dashboard because
  the terminal scrolls or cursor positioning glitches
- The pagination UX feels awkward — operators want to see all 100 targets
  at once and scroll naturally
- New dashboard screens (Linux Admin, Container Admin) are becoming
  hard to build and maintain with raw cursor math
- The operator team has Windows Terminal or a modern terminal as standard

---

### Scenario 1 — Spectre.Console as a PS7 display backend

Write `ui/DashboardSpectre.ps1` that loads `Spectre.Console.dll` via
`Add-Type` and implements the same `DisplayAdapter.ps1` interface using
Spectre's `Table`, `Live`, `Progress`, and `Markup` APIs.

**How it works:**
```powershell
# In DashboardSpectre.ps1
Add-Type -Path (Join-Path $PSScriptRoot '../lib/Spectre.Console.dll')

function _Spectre_ShowFleetDashboard {
    param([FleetTarget[]]$Targets, ...)
    $table = [Spectre.Console.Table]::new()
    $table.AddColumn('#') | Out-Null
    $table.AddColumn('Name') | Out-Null
    # ... populate rows
    [Spectre.Console.AnsiConsole]::Write($table)
}
```

**Switching:** Change `"displayBackend": "spectre"` in `settings.local.json`.
No other code changes. All executors and menus unchanged.

**Effort:** Medium. Spectre.Console is a C# library used from PS7 — possible
but not idiomatic. The live-update batch dashboard is the hardest part since
Spectre's `Live` display has threading requirements that conflict with
`ForEach-Object -Parallel`.

**Decision criteria:**
- [ ] Prototype the fleet dashboard table in Spectre.Console from PS7
- [ ] Prototype the batch live-update display
- [ ] Compare rendering quality and maintenance effort against ANSI
- [ ] Evaluate DLL distribution (ship `Spectre.Console.dll` in a `lib/`
      folder, or require `dotnet tool install`)

**Pros:** No new language; all PS7; swappable via config.
**Cons:** Using a C# library from PS7 is not idiomatic; live display
threading is complex; DLL must be distributed with the tool.

---

### Scenario 2 — C# console app with Spectre.Console (recommended path)

Write a standalone C# console app `TcFltDashboard` (Visual Studio project,
.NET 8, MIT-licensed Spectre.Console). PS7 launches it as a child process
and communicates via a named pipe or stdin/stdout JSON stream.

**Architecture:**
```
TcFltPkgMgr.ps1 (orchestration, executors, menus)
       │
       │  JSON events via named pipe
       │  { "event": "batch_update", "target": "DCC-1", "status": "OK", ... }
       ▼
TcFltDashboard.exe (C# Spectre.Console renderer)
  - Receives events, updates live table
  - Handles keyboard input (P/N pagination, target selection)
  - Sends user choices back to PS7 via pipe
  - Cross-platform: Windows .exe or Linux binary
```

**Effort:** Higher upfront, but the C# side is straightforward Spectre.Console
code. The pipe protocol is simple JSON. Once the protocol is defined, PS7
and C# evolve independently.

**Decision criteria:**
- [ ] Define the JSON event protocol (20-30 event types cover all screens)
- [ ] Build a proof-of-concept C# dashboard for the fleet home screen only
- [ ] Evaluate the latency of pipe communication for live batch updates
- [ ] Assess cross-platform build (publish as self-contained for Windows x64,
      Linux x64; optionally macOS)
- [ ] Confirm Visual Studio project structure fits the repo layout

**Pros:** Professional rendering; native Spectre.Console usage; cross-platform;
C# and PS7 evolve independently; operator gets mouse support and proper
scrolling; leverages existing VS Professional license.
**Cons:** Two languages in the project; pipe protocol adds complexity;
requires distributing a compiled binary.

---

### Scenario 3 — C# host calling PS7 via SDK (longest term)

Write a C# application that hosts PS7 as a library via the
`System.Management.Automation` NuGet package. The C# app provides the UI
(Spectre.Console or Avalonia for a windowed app); PS7 provides the executor
logic called as functions.

```csharp
using System.Management.Automation;
using System.Management.Automation.Runspaces;

// Load the TcFltPkgMgr PS7 modules
var iss = InitialSessionState.CreateDefault();
iss.ImportPSModule(new[] { "path/to/execution/FleetExecutor.ps1" });
var runspace = RunspaceFactory.CreateRunspace(iss);
runspace.Open();

// Call a PS7 function from C#
using var ps = PowerShell.Create();
ps.Runspace = runspace;
ps.AddCommand("Invoke-FltSshBatch")
  .AddParameter("Targets", targets)
  .AddParameter("RemoteCommand", remoteCmd);
var results = await ps.InvokeAsync();
```

**Effort:** Highest. This is essentially a full application rewrite of the UI
layer, keeping only the PS7 executor scripts. The PS7 scripts would need minor
refactoring to be importable as modules rather than a running script.

**Decision criteria:**
- [ ] Evaluate whether the windowed UI (Avalonia) is desirable vs terminal
- [ ] Assess the PS7 SDK embedding — does it handle parallel jobs correctly?
- [ ] Consider whether a web UI (ASP.NET + SignalR for live updates) is
      preferable to a desktop app for a fleet management tool
- [ ] Only pursue if Scenario 2 proves insufficient or if a GUI is explicitly
      requested by operators

**Pros:** Maximum UI flexibility; single-language C# codebase long-term;
PS7 executor logic reused without rewrite; windowed app possible.
**Cons:** Most work; PS7 SDK has quirks; parallel job behavior inside an
embedded runspace needs validation.

---

### Recommended sequence

```
Now        Phase 0-A    Display adapter in place — ANSI backend wired
                        Credential backend abstracted
                        Cross-platform audit done

Phases 1-11            Build WinGet, Ansible, Docker on the adapter

After Phase 11         ── DECISION POINT ──
                        Evaluate ANSI sufficiency at real 100-target scale

If ANSI sufficient     Stay with ANSI, maintain DashboardAnsi.ps1

If richer UI needed    Prototype Scenario 2 (C# + Spectre.Console pipe)
                        3-4 weeks: define protocol, build fleet home screen,
                        build batch dashboard, test cross-platform

If Scenario 2 works    Ship TcFltDashboard alongside TcFltPkgMgr.ps1
                        ANSI backend remains as fallback / SSH fallback

If windowed app        Prototype Scenario 3 (C# SDK host)
eventually desired     Only if Scenario 2 proves insufficient
```

---

## New files summary (updated)

| File | Purpose |
|------|---------|
| `ui/DisplayAdapter.ps1` | Stable display interface — all menus call this |
| `ui/DisplayBackends.ps1` | Loads and wires the active backend at startup |
| `ui/DashboardAnsi.ps1` | Existing ANSI implementation (renamed from Dashboard.ps1) |
| `ui/DashboardSpectre.ps1` | Future Spectre.Console backend (Scenario 1) |
| `data/CredentialAdapter.ps1` | Stable credential interface |
| `data/CredentialBackendWindows.ps1` | Windows Credential Manager implementation |
| `data/CredentialBackendFile.ps1` | Encrypted file implementation for Linux |
| `config/targets.local.json` | Primary target store — all target types (gitignored) |
| `data/WinGetRepository.ps1` | WinGet package search and version listing |
| `data/AnsibleRepository.ps1` | Ansible availability and collection checks |
| `execution/WinGetExecutor.ps1` | SSH batch executor using winget |
| `execution/AnsibleExecutor.ps1` | Inventory/playbook builder and Ansible runner |
| `execution/ContainerExecutor.ps1` | Docker exec and lifecycle batch executor |
| `ui/menus/WinGetMenu.ps1` | WinGet install / upgrade / uninstall / status |
| `ui/menus/LinuxMenu.ps1` | Linux Admin: packages, users, services, playbooks |
| `ui/menus/ContainerMenu.ps1` | Container Admin: packages, lifecycle, logs, health |

## Modified files summary (updated)

| File | What changes |
|------|-------------|
| `classes/Models.ps1` | `FleetTarget` gets `OS`, `TargetType`, `PackageManager`, `DockerHost`, `ContainerName` |
| `data/TargetRepository.ps1` | New JSON target store; migration; CSV columns; Add/Edit |
| `data/CredentialRepository.ps1` | Refactored — logic moves to `CredentialBackendWindows.ps1` |
| `execution/FleetExecutor.ps1` | Four buckets (tcpkg, WinGet, Ansible, Docker); throttle tuning |
| `execution/CommandLog.ps1` | `PackageManager` and `TargetType` in batch log |
| `ui/Dashboard.ps1` | Renamed to `DashboardAnsi.ps1`; wired through `DisplayAdapter.ps1` |
| `ui/menus/FleetMenu.ps1` | New items 6-8; renumber to 9; feature gating for OS |
| `ui/menus/TargetMenu.ps1` | Full type/OS/container prompts; prerequisites check |
| `config/settings.default.json` | `winget`, `ansible`, `docker`, `ui`, `displayBackend` sections |
| `config/settings.default.jsonc` | Same with comments |
| `TcFltPkgMgr.ps1` | OS detection; backend init; Linux config paths; module load order |
| `README.md` | Linux operator instructions; prerequisites; cross-platform notes |