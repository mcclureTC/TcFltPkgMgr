# TcFltPkgMgr — WinGet, Ansible & Container Integration Plan

A step-by-step implementation checklist. Each section is a logical unit of work
that can be completed and tested independently before moving to the next.

> **Scale note:** The fleet is expected to grow to ~100 total remote targets,
> consisting of a mix of physical PCs, virtual machines, and Docker containers.
> Several design decisions below are informed by this scale requirement.

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
- [ ] `ansible.forks` — deferred to Phase 5 (Ansible executor)

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
- [ ] Validate `DockerHost` references an existing target — deferred to Phase 7
      (containers not yet implemented)

---

## Phase 2 — Fleet dashboard updates

### 2.1 — `Show-FleetDashboard` (`ui/DashboardAnsi.ps1`)

> Pagination, sort/filter, `-`/`+` nav, and `EffectiveAddress()` are already
> implemented (Phases 0.1, 0.3). Remaining items are cosmetic column additions
> that are low value until Linux/container targets actually exist in the fleet.
> **Defer all of 2.1 to Phase 9** — do alongside the full type/OS Add Target flow
> so columns are visible with real data immediately.

- [ ] Add `OS` column (`Win`/`Lnx`) and `Type` column (`Phys`/`VM`/`Cntr`) —
      defer to Phase 9 (after Add Target supports OS/Type selection)
- [ ] Color rows by type: Linux = Cyan, Container = Magenta — defer to Phase 9
- [ ] Show `---` in Internet column for Linux/container targets — defer to Phase 9
- [ ] Container address column shows `<DockerHost>/<ContainerName>` — already
      implemented via `EffectiveAddress()` in `FleetTarget` class ✅

### 2.2 — `Show-SetupDashboard` (`ui/DashboardAnsi.ps1`)

> Defer to Phase 9 alongside 2.1. Setup pagination deferred to Phase 12 (low priority).

- [ ] Add `OS` and `Type` columns to targets view — defer to Phase 9
- [ ] Pagination — low priority; Setup rarely exceeds 20 targets (revisit Phase 12)

### 2.3 — `Show-FleetBatchDashboard` (`ui/DashboardAnsi.ps1`)

> Pagination deferred to Phase 7.0. Mode/Summary row updates depend on
> having multiple executors — defer to Phase 10 (after all executors exist).

- [ ] Pagination with auto-scroll to first non-OK row — deferred to Phase 7.0 ✓
- [ ] `Type` column in batch rows — defer to Phase 9 (alongside 2.1)
- [ ] Multi-executor `Mode` row and per-executor summary counts —
      defer to Phase 10 (after WinGet, Ansible, Docker executors exist)

---

## Phase 3 — WinGet executor (Windows targets, general packages)

### 3.1 — WinGet executor (`execution/WinGetExecutor.ps1`) — new file

- [ ] Create `Invoke-FltWinGetBatch` mirroring `Invoke-FltSshBatch`
- [ ] Command format:
      `winget install --id <package> --silent --accept-package-agreements --accept-source-agreements`
- [ ] Map verbs: `install` → `winget install`, `upgrade` → `winget upgrade`,
      `uninstall` → `winget uninstall`
- [ ] WinGet exit codes: `0` = OK, `-1978335212` = not found,
      `-1978335189` = already installed — map to human-readable notes
- [ ] No feed check phase for WinGet
- [ ] `Write-FltBatchEntry` with `PackageManager = 'winget'`

### 3.2 — WinGet package search (`data/WinGetRepository.ps1`) — new file

- [ ] `Search-FltWinGetPackage` — runs `winget search <term>` locally,
      parses tabular output into `[pscustomobject]` rows
- [ ] `Get-FltWinGetVersions` — runs `winget show --id <id> --versions`
- [ ] Both return the same shape as tcpkg equivalents

### 3.3 — Route WinGet targets in `Invoke-FleetAction` (`execution/FleetExecutor.ps1`)

- [ ] Split SSH bucket by `EffectivePackageManager()`:
      `tcpkg` → `Invoke-FltSshBatch`, `winget` → `Invoke-FltWinGetBatch`
- [ ] Results merge into `$allResults`
- [ ] No change to push bucket

---

## Phase 4 — WinGet UI

### 4.1 — Fleet menu (`ui/menus/FleetMenu.ps1`)

> Current layout (1-8): Install, Upgrade, Uninstall, Status, Outdated,
> Profiles, UI Config, Setup. Each new executor phase shifts Setup by 1.
> Final layout after Phases 4+6+8: Install, Upgrade, Uninstall, Status,
> Outdated, WinGet, Linux Admin, Containers, Profiles, UI Config, Setup.
> UI Config stays adjacent to Setup (operator muscle memory).

- [ ] Add `6. WinGet`; Profiles→7, UI Config→8, Setup→9
- [ ] Update dashboard footer hint (may need second footer line at 119 cols)

### 4.2 — WinGet menu (`ui/menus/WinGetMenu.ps1`) — new file

- [ ] `Invoke-WinGetInstallMenu` — search → pick (base-1) → version (base-1)
      → target selection (base-11 on dashboard, Windows only) → batch
- [ ] `Invoke-WinGetUpgradeMenu`
- [ ] `Invoke-WinGetUninstallMenu`
- [ ] `Invoke-WinGetStatusMenu`
- [ ] Filter target list to `OS -eq 'windows'` throughout

### 4.3 — Setup: target OS/PackageManager prompts (`ui/menus/TargetMenu.ps1`)

> These prompts are a subset of Phase 9.1 (full type/OS/container flow).
> Implementing 4.3 now means 9.1 won't need to redo this work.
> **Implement alongside Phase 9.1** — do both together rather than
> adding Windows-only prompts now and re-editing for containers later.
> Marked as dependency: Phase 9.1 satisfies 4.3.

- [ ] OS and PackageManager prompts — implement in Phase 9.1 (full flow)
- [ ] Show `OS`, `Type`, `PackageManager` in Setup dashboard — implement in Phase 9

---

## Phase 5 — Ansible prerequisites

### 5.1 — Ansible availability check (`data/AnsibleRepository.ps1`) — new file

- [ ] `Test-FltAnsibleAvailable` — checks for `ansible-playbook` on PATH or
      via WSL
- [ ] `Get-FltAnsibleVersion`
- [ ] `Get-FltAnsibleMode` — returns `'native'` or `'wsl'`
- [ ] `Test-FltAnsibleCollection` — checks `community.docker` is installed
      (`ansible-galaxy collection list community.docker`)

### 5.2 — Ansible inventory builder (`execution/AnsibleExecutor.ps1`) — new file

- [ ] `New-FltAnsibleInventory` — writes temp INI inventory from
      `[FleetTarget[]]`:
      ```ini
      [linux]
      DCC-Linux-1 ansible_host=192.168.8.110 ansible_user=admin ansible_port=22

      [containers]
      web-1 ansible_host=192.168.8.50 ansible_user=admin ansible_port=22
            ansible_connection=community.docker.docker_api
            ansible_docker_host=tcp://192.168.8.50:2375
      ```
- [ ] Clean up temp files after each run

### 5.3 — Ansible playbook builder (`execution/AnsibleExecutor.ps1`)

- [ ] `_Get-PackagePlaybook` — `ansible.builtin.package` (distro-agnostic)
- [ ] `_Get-UserPlaybook` — `ansible.builtin.user`
- [ ] `_Get-ServicePlaybook` — `ansible.builtin.systemd`
- [ ] `_Get-FilePlaybook` — `ansible.builtin.copy`
- [ ] `_Get-DockerPlaybook` — `community.docker.docker_container` for
      container lifecycle (pull, start, stop, restart, recreate, remove)

### 5.4 — Ansible executor (`execution/AnsibleExecutor.ps1`)

- [ ] `Invoke-FltAnsibleBatch` — writes inventory + playbook, runs
      `ansible-playbook -i <inv> <playbook> -o json --forks <n>`, parses
      JSON output into `BatchResult[]`, calls `$OnProgress`, cleans up
- [ ] Exit code mapping: `0` = OK, `2` = host failures, `4` = unreachable,
      `8` = parse error
- [ ] Note column shows failing Ansible task name from JSON output
- [ ] `Write-FltBatchEntry` with `PackageManager = 'ansible'`
- [ ] Add `ansible.forks` to `settings.default.json` (default 10 — Ansible's
      own parallelism). Pass as `--forks <n>` to `ansible-playbook`.
      *(Deferred from Phase 0.2 — not needed until Ansible executor exists)*

### 5.5 — Route Ansible targets in `Invoke-FleetAction` (`execution/FleetExecutor.ps1`)

- [ ] Add `ansibleTargets` bucket — `OS -eq 'linux'` AND
      `TargetType -ne 'container'`
- [ ] No feed check for Ansible targets
- [ ] No push bucket for Linux
- [ ] Merge results into `$allResults`

### 5.6 — Ansible Vault integration (`execution/AnsibleExecutor.ps1`)

Ansible Vault encrypts secrets (SSH sudo passwords, API keys, service account
credentials) stored alongside playbooks using AES-256. The vault password is
the only secret needed to decrypt — encrypted files can be safely committed to
the repo.

**Two-tier credential model:**
- Tier 1: TcFltPkgMgr credential store protects the Ansible Vault password
          (DPAPI on Windows, random-key AES-256 on Linux)
- Tier 2: Ansible Vault protects playbook secrets using that vault password
The operator enters the vault password once; the tool manages it from there.

- [ ] Add `_Get-VaultPasswordFile` helper — retrieves vault password from
      `Get-FltStoredPassword -CredentialName 'ansible_vault'` and writes it
      to a temp file passed as `--vault-password-file` to `ansible-playbook`
- [ ] `Invoke-FltAnsibleBatch` passes `--vault-password-file` when a vault
      password is stored; omits the flag if none is configured (playbooks
      without encrypted vars work without a vault password)
- [ ] Add `Invoke-FltVaultSetup` in the Linux Admin menu — prompts for vault
      password and saves it via `Set-FltStoredPassword -CredentialName 'ansible_vault'`
- [ ] Add `ansible/` folder at project root for vault-encrypted variable files:
      ```
      ansible/
      ├── group_vars/
      │   └── all.yml.vault   # encrypted: SSH passwords, sudo credentials
      └── host_vars/
          └── <hostname>.yml.vault   # per-host secret overrides
      ```
- [ ] Vault files are safe to commit encrypted — add to `.gitignore` only if
      secrets should not be in the repo at all
- [ ] Document vault password rotation in README:
      `ansible-vault rekey ansible/group_vars/all.yml.vault`
      then update via TcFltPkgMgr Setup > Linux Admin

---

## Phase 6 — Ansible UI

### 6.1 — Fleet menu (`ui/menus/FleetMenu.ps1`)

> Depends on Phase 4.1 already having added WinGet at 6.
> After this phase: WinGet=6, Linux Admin=7, Profiles=8, UI Config=9, Setup=10.

- [ ] Add `7. Linux Admin`; Profiles→8, UI Config→9, Setup→10
- [ ] Update dashboard footer hint

### 6.2 — Linux Admin menu (`ui/menus/LinuxMenu.ps1`) — new file

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

- [ ] `Invoke-LinuxAdminMenu` — filters to `OS -eq 'linux'` AND
      `TargetType -ne 'container'`; shows message if none configured
- [ ] Dashboard paginated if >20 Linux targets

### 6.3 — Package sub-menu (choices 1/2/3)

- [ ] `Invoke-LinuxInstallMenu` — name prompt → target selection → batch
- [ ] `Invoke-LinuxUpgradeMenu`
- [ ] `Invoke-LinuxRemoveMenu`
- [ ] All route through `_Invoke-AnsibleBatchAction`

### 6.4 — User management sub-menu (choice 4)

```
  1. Add user
  2. Remove user
  3. Add to group
  4. Set password
  0. Back
```

- [ ] Each option prompts for fields then calls `Invoke-FltAnsibleBatch`
      with the `user` playbook template

### 6.5 — Service management sub-menu (choice 5)

```
  1. Start service
  2. Stop service
  3. Restart service
  4. Enable on boot
  5. Disable on boot
  0. Back
```

- [ ] Prompts for service name; runs `systemd` playbook template

### 6.6 — Run playbook (choice 6)

- [ ] Prompt for `.yml` file path; validate exists; run via
      `ansible-playbook` against selected targets; show batch dashboard

---

## Phase 7 — Docker container support

### 7.0 — Batch dashboard pagination
> *(Deferred from Phase 0.1 — needed at container scale with 100+ targets)*

- [ ] `Show-FleetBatchDashboard` paginates when targets exceed page size
- [ ] Auto-scroll to first non-`OK` row on each repaint
- [ ] Page navigation uses `-` / `+` (numpad) consistent with fleet dashboard
- [ ] Summary row always visible regardless of current page

### 7.1 — Container executor (`execution/ContainerExecutor.ps1`) — new file

Containers are reached via a two-hop model: SSH to the Docker host, then
`docker exec` into the container. This avoids requiring SSH inside containers.

- [ ] `Invoke-FltDockerExecBatch` — parallel SSH to each container's
      `DockerHost`, wraps every command as
      `docker exec -i <ContainerName> <command>`
- [ ] `Invoke-FltDockerLifecycleBatch` — runs `docker` commands directly on
      the host (not inside the container):
      `docker pull`, `docker stop`, `docker start`, `docker restart`,
      `docker rm`, `docker run`
- [ ] For package operations inside containers: command becomes
      `docker exec -i <ContainerName> apt-get install -y <package>` (or
      `apk`, `yum` etc. based on `PackageManager`)
- [ ] `BatchResult.Note` for containers includes the container name
- [ ] `Write-FltBatchEntry` with `PackageManager = 'docker-exec'` or
      `'docker-lifecycle'`

### 7.2 — Route container targets in `Invoke-FleetAction` (`execution/FleetExecutor.ps1`)

- [ ] Add `containerTargets` bucket — `TargetType -eq 'container'`
- [ ] Package install/upgrade/remove → `Invoke-FltDockerExecBatch`
- [ ] No feed check for containers
- [ ] No push bucket for containers
- [ ] Merge results into `$allResults`

### 7.3 — Docker connection check

- [ ] `Test-FltDockerHostReachable` — SSH to the Docker host and run
      `docker info` to verify the Docker daemon is running and accessible
- [ ] Called during the reachability background check for container targets
      (replaces TCP port check which would check the host not the container)
- [ ] Reachable result: `'online'` if `docker info` exits 0,
      `'offline'` if SSH fails, `'docker-down'` if Docker daemon not running

### 7.4 — Add container target flow (`ui/menus/TargetMenu.ps1`)

- [ ] In Add Target, if `TargetType = 'container'`:
      - Prompt `Docker host (target name):` — must match an existing target
      - Prompt `Container name:`
      - Skip `Address`, `Port`, `User` (inherited from Docker host)
      - Skip Internet Access
      - Prompt `Package manager: 1. apt  2. yum  3. apk  (default 1):`
- [ ] Validate Docker host target exists and is reachable
- [ ] Display in dashboard as `<host>/<container>` in address column

---

## Phase 8 — Container Admin UI

### 8.1 — Fleet menu (`ui/menus/FleetMenu.ps1`)

> Depends on Phase 6.1. After this phase:
> WinGet=6, Linux Admin=7, Containers=8, Profiles=9, UI Config=10, Setup=11.

- [ ] Add `8. Containers`; Profiles→9, UI Config→10, Setup→11
- [ ] Final menu layout:
      ```
       1. Install (tcpkg)    5. Outdated Check    9. Profiles
       2. Upgrade            6. WinGet           10. UI Config
       3. Uninstall          7. Linux Admin      11. Setup
       4. Package Status     8. Containers        0. Exit
      ```
- [ ] Footer will need two lines at 119 col width — already supported

### 8.2 — Container Admin menu (`ui/menus/ContainerMenu.ps1`) — new file

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

### 8.3 — Package operations (choices 1/2)

- [ ] `Invoke-ContainerInstallMenu` — package name → target selection →
      `Invoke-FltDockerExecBatch` with `apt-get install -y <package>`
- [ ] `Invoke-ContainerRemoveMenu` — same with `apt-get remove -y`
- [ ] Target selection filtered to containers only; base-11 on dashboard

### 8.4 — Image management (choice 3)

- [ ] `Invoke-ContainerPullMenu` — prompts for image name/tag → runs
      `docker pull <image>` on the Docker host (not inside container) →
      batch dashboard showing per-host results

### 8.5 — Lifecycle operations (choices 4-7)

- [ ] Start, Stop, Restart — single prompt for target selection, then
      `docker start/stop/restart <ContainerName>` on the host
- [ ] Recreate — stop + remove + run with stored `docker run` parameters.
      For now: prompt for the full `docker run` command to re-use.
      Future: store run parameters in `targets.local.json`.

### 8.6 — Logs (choice 8)

- [ ] `Invoke-ContainerLogsMenu` — single target selection (one container at
      a time), then SSH to host and run `docker logs --tail 50 <container>`;
      display in scrollable output below the dashboard

### 8.7 — Health check (choice 9)

- [ ] `Invoke-ContainerHealthMenu` — batch SSH to all Docker hosts, runs
      `docker inspect --format='{{.State.Health.Status}}' <container>` for
      each container; shows results in dashboard (healthy / unhealthy /
      starting / none)

---

## Phase 9 — Setup menu updates

### 9.1 — Add target: full type/OS flow (`ui/menus/TargetMenu.ps1`)

> Also satisfies Phase 4.3 (Windows OS/PackageManager prompts) and
> Phase 7.4 (container target Add flow). Implement all together here.
> Currently `Invoke-TargetMenu` only asks Name/Host/Port/User/Password/
> InternetAccess — all OS/Type/PackageManager fields default to 'windows'/
> 'physical'/'' and are not editable via the menu yet.

- [ ] `TargetType: 1. Physical  2. VM  3. Container  (default 1):`
- [ ] `OS: 1. Windows  2. Linux  (default 1):` (skip for containers)
- [ ] If Windows: `Package manager: 1. tcpkg  2. WinGet  3. Both`
- [ ] If Linux/VM: skip Internet Access prompt
- [ ] If Container: prompt Docker host (must match existing target name) and
      container name; skip Address/Port/User (inherited from Docker host)
- [ ] Edit flow: show current OS/Type/PackageManager, allow changes
- [ ] Add `OS`, `Type`, `PackageManager` columns to Setup dashboard
      (also satisfies Phase 2.1, 2.2 for Setup view)

### 9.2 — Prerequisites check (`ui/menus/TargetMenu.ps1`)

> The built-in diagnostics (Setup > 10) already cover tcpkg, Posh-SSH, and
> core subsystems. This phase adds a user-facing prerequisites check that is
> lighter than full diagnostics — focused on external tool availability only.
> Rename current `10. Diagnostics` → keep as-is; add new prerequisites check
> as a separate Setup menu item or integrate into diagnostics Phase 2.

- [ ] Check external tools: `winget`, `ansible-playbook`, `python3`, `docker`
- [ ] Check Ansible collection: `community.docker`
- [ ] Green/amber/red per item; offer to fix where possible:
      `Install-Module Posh-SSH`, `ansible-galaxy collection install community.docker`
- [ ] Integrate into existing Diagnostics screen as a new section, not a
      separate menu item (avoids Setup menu number inflation)
      - community.docker: `ansible-galaxy collection install community.docker`

### 9.3 — Settings for new executors (`config/settings.default.json`)

> `docker` (throttleLimit=20, logTailLines=50) and `ui` (dashboardPageSize=20,
> reachCacheSecs=60) sections already exist. Remaining: `winget` and `ansible`.

- [x] `docker.throttleLimit: 20` — already in `settings.default.json`
- [x] `docker.logTailLines: 50` — already in `settings.default.json`
- [x] `ui.dashboardPageSize: 20` — already in `settings.default.json`
- [x] `ui.reachCacheSecs: 60` — already in `settings.default.json`
- [ ] Add `winget` section (add when Phase 3 executor is implemented):
      `executablePath`, `remoteWinGetPath`
- [ ] Add `ansible` section (add when Phase 5 executor is implemented):
      `executablePath`, `useWsl`, `wslDistro`, `tempDir`, `forks: 10`
- [ ] `settings.default.jsonc` — add when the above sections are added

---

## Phase 10 — Command log updates

### 10.1 — `Write-FltBatchEntry` (`execution/CommandLog.ps1`)

> Depends on Phases 3, 5, 7 (WinGet, Ansible, Docker executors) being built
> first so the new PackageManager values are actually emitted.
> Implement incrementally: add `PackageManager` when Phase 3 lands,
> add `TargetType` when Phase 7 lands.

- [ ] Add `PackageManager` field — implement when Phase 3 (WinGet) is done
- [ ] Add `TargetType` field per result row — implement when Phase 7 (Docker) is done

### 10.2 — Log viewer

- [ ] Add `PackageManager` and `TargetType` columns to log output
- [ ] Add filter options for both in Setup > Log viewer

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
| `data/WinGetRepository.ps1` | phase 3 | WinGet package search and version listing |
| `data/AnsibleRepository.ps1` | phase 5 | Ansible availability and collection checks |
| `execution/WinGetExecutor.ps1` | phase 3 | SSH batch executor using winget |
| `execution/AnsibleExecutor.ps1` | phase 5 | Inventory/playbook builder and Ansible runner |
| `execution/ContainerExecutor.ps1` | phase 7 | Docker exec and lifecycle batch executor |
| `ui/menus/WinGetMenu.ps1` | phase 4 | WinGet install / upgrade / uninstall / status |
| `ui/menus/LinuxMenu.ps1` | phase 6 | Linux Admin: packages, users, services, playbooks |
| `ui/menus/ContainerMenu.ps1` | phase 8 | Container Admin: packages, lifecycle, logs, health |

## Modified files summary

| File | Status | What changes |
|------|--------|-------------|
| `classes/Models.ps1` | ✅ done | `FleetTarget` extended with OS/Type/PackageManager/Docker fields |
| `data/TargetRepository.ps1` | ✅ done | JSON store; migration; CSV; Add/Edit/Remove |
| `data/CredentialRepository.ps1` | ✅ done | Refactored into adapter + Windows/file backends |
| `execution/FleetExecutor.ps1` | partial | tcpkg + push buckets done; WinGet/Ansible/Docker pending |
| `execution/CommandLog.ps1` | pending | `PackageManager` and `TargetType` fields (phases 3/7) |
| `ui/DashboardAnsi.ps1` | partial | Pagination/sort/filter done; OS/Type columns pending (phase 9) |
| `ui/menus/FleetMenu.ps1` | partial | Current: 1-8; WinGet/Linux/Containers to add (phases 4/6/8) |
| `ui/menus/TargetMenu.ps1` | partial | Add/Edit/Remove done; OS/Type prompts pending (phase 9.1) |
| `config/settings.default.json` | partial | docker/ui done; winget/ansible sections pending (phases 3/5) |
| `config/settings.default.jsonc` | pending | Add when winget/ansible sections added |
| `TcFltPkgMgr.ps1` | partial | OS detection done; Linux config paths pending (phase 12.1) |

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