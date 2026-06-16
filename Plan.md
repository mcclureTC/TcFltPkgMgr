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
- [ ] `Show-SetupDashboard` pagination — deferred (Setup rarely exceeds 20 targets)
- [ ] `Show-FleetBatchDashboard` pagination — deferred to Phase 7 (container scale)

### 0.2 — Executor throttle tuning

`ForEach-Object -Parallel` with `-ThrottleLimit 10` (current default) means
100 targets complete in ~10 rounds. This is fine for SSH (round-trip ~5s =
~50s total), but Ansible with `--forks` handles its own parallelism internally.

- [ ] Raise default `ssh.throttleLimit` to `25` in `settings.default.json`.
      This brings 100-target SSH batches from ~50s to ~20s wall-clock.
- [ ] Document in `settings.default.jsonc` that values above 50 risk exhausting
      the operator machine's TCP connection pool.
- [ ] Add `ansible.forks` to `settings.default.json` (default 10 — Ansible's
      own default). This is passed as `--forks <n>` to `ansible-playbook`.
- [ ] Add `docker.throttleLimit` to `settings.default.json` (default 20).
      Docker exec over SSH is lighter than tcpkg installs.

### 0.3 — Target store: move from tcpkg to local JSON

With 100 targets, `tcpkg remote list --as-json` on every menu open becomes
slow (~0.6s × every navigation). More importantly, Docker containers cannot
be registered in tcpkg at all (no `tcpkg remote add` equivalent).

- [ ] Create `config/targets.local.json` as the primary target store.
      Schema mirrors the existing `FleetTarget` fields plus the new meta
      fields from Phase 1. Gitignored.
- [ ] `Get-FleetTargets` reads from `targets.local.json` first; falls back
      to `tcpkg remote list` if the file does not exist (backward compat).
- [ ] `Add-FleetTarget`, `Edit-FleetTarget`, `Remove-FleetTarget` write to
      `targets.local.json`. For Windows targets with `PackageManager = 'tcpkg'`
      or `'both'`, also call `tcpkg remote add/edit/remove` to keep tcpkg's
      own store in sync (needed for `tcpkg -r` push operations).
- [ ] `Import-FleetTargetsCsv` writes to `targets.local.json` directly.
      No longer iterates `tcpkg remote add` for every row — only calls tcpkg
      for Windows/tcpkg targets.
- [ ] This is the only store for Linux targets and container targets.
      tcpkg never hears about them.
- [ ] Add a migration function `Invoke-FltTargetStoreMigration` that, on first
      run with the new code, reads existing targets from tcpkg and writes them
      to `targets.local.json` automatically.

### 0.4 — Reachability check at scale

The current background reachability job checks all targets sequentially in a
`Start-Job` scriptblock. At 100 targets this takes 100 × 2s timeout = up to
200s in the worst case.

- [ ] Rewrite the reachability check to use `ForEach-Object -Parallel` with
      `-ThrottleLimit 50` inside the job. All 100 targets checked in ~2s
      regardless of fleet size.
- [ ] Only check reachability for the current dashboard page on initial load;
      check remaining pages in subsequent background passes.
- [ ] Add reachability result caching — don't re-check a target that came back
      `online` within the last 60 seconds (configurable via
      `ui.reachCacheSecs`).

---

## Phase 1 — Target model extensions

### 1.1 — Extend `FleetTarget` class (`classes/Models.ps1`)

- [ ] Add `[string] $OS` — values: `'windows'` | `'linux'`
- [ ] Add `[string] $TargetType` — values: `'physical'` | `'vm'` |
      `'container'`
- [ ] Add `[string] $PackageManager` — values: `'tcpkg'` | `'winget'` |
      `'apt'` | `'yum'` | `'dnf'` | `'apk'` | `''` (auto)
- [ ] Add `[string] $DockerHost` — name of the `FleetTarget` that is the
      Docker host; populated only when `TargetType = 'container'`
- [ ] Add `[string] $ContainerName` — Docker container name or ID; populated
      only when `TargetType = 'container'`
- [ ] Update both constructors to default `OS = 'windows'`,
      `TargetType = 'physical'`, `PackageManager = ''`,
      `DockerHost = ''`, `ContainerName = ''`
- [ ] Add helper method `EffectivePackageManager()` — returns
      `$this.PackageManager` if set, otherwise `'tcpkg'` for windows and
      `'apt'` for linux/container
- [ ] Add `OsDisplay()` — `'Win'` / `'Lnx'`
- [ ] Add `TypeDisplay()` — `'Phys'` / `'VM'` / `'Cntr'`
- [ ] Add `IsContainer()` — returns `$this.TargetType -eq 'container'`
- [ ] Add `EffectiveAddress()` — for containers returns
      `"$($this.DockerHost)/$($this.ContainerName)"`; for others returns
      `$this.Address`

### 1.2 — Target store (`data/TargetRepository.ps1`)

- [ ] Implement `Get-FleetTargets` reading from `targets.local.json`
      (see Phase 0.3)
- [ ] Implement `Save-FltTargets` writing the full target list to
      `targets.local.json`
- [ ] Implement `Invoke-FltTargetStoreMigration` (see Phase 0.3)
- [ ] Remove dependency on `Get-FltTargetMeta` / `Set-FltTargetMeta` sidecar
      (no longer needed — all fields live in `targets.local.json`)

### 1.3 — Update CSV import/export (`data/TargetRepository.ps1`)

- [ ] Add `OS`, `TargetType`, `PackageManager`, `DockerHost`, `ContainerName`
      columns to `Export-FleetTargetsCsv`
- [ ] Read new columns in `Import-FleetTargetsCsv`; default missing columns
      to `'windows'`, `'physical'`, `''`, `''`, `''` for backward compat
- [ ] Container rows in CSV: `Address` column holds the Docker host's address;
      `DockerHost` holds the Docker host target name; `ContainerName` holds
      the container name

### 1.4 — Update `Add-FleetTarget` and `Edit-FleetTarget`

- [ ] Accept `-OS`, `-TargetType`, `-PackageManager`, `-DockerHost`,
      `-ContainerName` parameters
- [ ] For Linux and container targets: skip `--internet-access` flag and skip
      `tcpkg remote add` entirely — write directly to `targets.local.json`
- [ ] For Windows tcpkg/both targets: call `tcpkg remote add/edit` as before,
      then write to `targets.local.json`
- [ ] Validate that `DockerHost` references an existing target name when
      `TargetType = 'container'`

---

## Phase 2 — Fleet dashboard updates

### 2.1 — `Show-FleetDashboard` (`ui/Dashboard.ps1`)

- [ ] Add `Type` column (`Phys` / `VM` / `Cntr`) after the `#` column
- [ ] Add `OS` column (`Win` / `Lnx`) after `Type`
- [ ] For container targets: show `<DockerHost>/<ContainerName>` in the
      address column instead of an IP
- [ ] Color rows by type: Windows = default, Linux = Cyan, Container = Magenta
- [ ] Hide `Internet` column for Linux and container targets — show `---`
- [ ] Implement pagination (see Phase 0.1)
- [ ] Dashboard footer shows page navigation when fleet exceeds page size

### 2.2 — `Show-SetupDashboard` (`ui/Dashboard.ps1`)

- [ ] Add `Type` and `OS` columns to targets view
- [ ] Implement pagination

### 2.3 — `Show-FleetBatchDashboard` (`ui/Dashboard.ps1`)

- [ ] Add `Type` column to batch rows
- [ ] Implement pagination with auto-scroll to first non-OK row
- [ ] Update `Mode` row: `Parallel SSH (tcpkg)` | `WinGet SSH` |
      `Ansible` | `Docker exec` | `Mixed`
- [ ] Summary row counts by executor:
      `tcpkg: 3 OK  |  WinGet: 2 OK  |  Ansible: 5 OK  |  Docker: 90 OK`

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

- [ ] Add `6. WinGet` (renumber Profiles → 7, Setup → 8)
- [ ] Update dashboard footer hint

### 4.2 — WinGet menu (`ui/menus/WinGetMenu.ps1`) — new file

- [ ] `Invoke-WinGetInstallMenu` — search → pick (base-1) → version (base-1)
      → target selection (base-11 on dashboard, Windows only) → batch
- [ ] `Invoke-WinGetUpgradeMenu`
- [ ] `Invoke-WinGetUninstallMenu`
- [ ] `Invoke-WinGetStatusMenu`
- [ ] Filter target list to `OS -eq 'windows'` throughout

### 4.3 — Setup: target OS/PackageManager prompts (`ui/menus/TargetMenu.ps1`)

- [ ] Add `OS: 1. Windows  2. Linux  (default 1):` prompt in Add/Edit
- [ ] If Windows: `Package manager: 1. tcpkg  2. WinGet  3. Both  (default 1):`
- [ ] If Linux: skip Internet Access prompt
- [ ] Show `OS`, `Type`, `PackageManager` in setup dashboard

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

- [ ] Add `7. Linux Admin` (Profiles → 8, Setup → 9)

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

- [ ] Add `8. Containers` (Setup → 9, now at 9)
- [ ] Final menu layout:
      ```
       1. Fleet Install (tcpkg)    5. Outdated Check
       2. Fleet Upgrade            6. WinGet
       3. Fleet Uninstall          7. Linux Admin
       4. Package Status           8. Containers
                                   9. Setup
                                   0. Exit
      ```

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

- [ ] `TargetType: 1. Physical  2. VM  3. Container  (default 1):`
- [ ] `OS: 1. Windows  2. Linux  (default 1):` (skip for containers —
      inferred from Docker host or set explicitly)
- [ ] If Windows: `Package manager: 1. tcpkg  2. WinGet  3. Both`
- [ ] If Linux/VM: skip Internet Access
- [ ] If Container: prompt for Docker host and container name (see Phase 7.4)

### 9.2 — Prerequisites check (`ui/menus/TargetMenu.ps1`)

- [ ] Add `10. Check prerequisites` to Setup menu
- [ ] Checks:
      - `tcpkg` — version and path
      - `Posh-SSH` — installed and version
      - `winget` — available and version
      - `ansible-playbook` — available (native or WSL) and version
      - Python 3 — required by Ansible control node
      - `community.docker` Ansible collection — installed
      - Docker CLI (`docker`) — available locally (for log/inspect operations)
- [ ] Green/red per item in result row
- [ ] Offer to fix where possible:
      - Posh-SSH: `Install-Module Posh-SSH -Scope CurrentUser`
      - community.docker: `ansible-galaxy collection install community.docker`

### 9.3 — Settings for new executors (`config/settings.default.json`)

- [ ] Add:
      ```json
      "winget": {
        "executablePath": "winget",
        "remoteWinGetPath": "C:\\Users\\Administrator\\AppData\\Local\\Microsoft\\WindowsApps\\winget.exe"
      },
      "ansible": {
        "executablePath": "ansible-playbook",
        "useWsl": false,
        "wslDistro": "",
        "tempDir": "",
        "forks": 10
      },
      "docker": {
        "throttleLimit": 20,
        "logTailLines": 50
      },
      "ui": {
        "dashboardPageSize": 20,
        "reachCacheSecs": 60
      }
      ```
- [ ] Add corresponding entries to `settings.default.jsonc` with comments

---

## Phase 10 — Command log updates

### 10.1 — `Write-FltBatchEntry` (`execution/CommandLog.ps1`)

- [ ] Add `PackageManager` field — `'tcpkg'` / `'winget'` / `'ansible'` /
      `'docker-exec'` / `'docker-lifecycle'`
- [ ] Add `TargetType` field per result row — `'physical'` / `'vm'` /
      `'container'`

### 10.2 — Log viewer

- [ ] Add `PackageManager` and `TargetType` columns to log output
- [ ] Add filter options for both in Setup > Log viewer

---

## Phase 11 — Testing checklist

### Scale
- [ ] Load 100 targets from `targets.local.json` — startup time < 2s
- [ ] Dashboard pagination renders correctly at 20, 50, 100 targets
- [ ] Page navigation (P/N) works without losing target numbering
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

| File | Purpose |
|------|---------|
| `config/targets.local.json` | Primary target store — all target types (gitignored) |
| `data/WinGetRepository.ps1` | WinGet package search and version listing |
| `data/AnsibleRepository.ps1` | Ansible availability and collection checks |
| `execution/WinGetExecutor.ps1` | SSH batch executor using winget |
| `execution/AnsibleExecutor.ps1` | Inventory/playbook builder and Ansible runner |
| `execution/ContainerExecutor.ps1` | Docker exec and lifecycle batch executor |
| `ui/menus/WinGetMenu.ps1` | WinGet install / upgrade / uninstall / status |
| `ui/menus/LinuxMenu.ps1` | Linux Admin: packages, users, services, playbooks |
| `ui/menus/ContainerMenu.ps1` | Container Admin: packages, lifecycle, logs, health |

## Modified files summary

| File | What changes |
|------|-------------|
| `classes/Models.ps1` | `FleetTarget` gets `OS`, `TargetType`, `PackageManager`, `DockerHost`, `ContainerName` |
| `data/TargetRepository.ps1` | New JSON target store; migration; CSV columns; Add/Edit |
| `data/CredentialRepository.ps1` | Refactored into adapter + Windows backend |
| `execution/FleetExecutor.ps1` | Four buckets (tcpkg, WinGet, Ansible, Docker); throttle tuning |
| `execution/CommandLog.ps1` | `PackageManager` and `TargetType` in batch log |
| `ui/Dashboard.ps1` | Renamed to `DashboardAnsi.ps1`; wired through adapter |
| `ui/menus/FleetMenu.ps1` | New items 6-8 (WinGet, Linux Admin, Containers); renumber to 9; feature gating |
| `ui/menus/TargetMenu.ps1` | Full type/OS/container prompts; prerequisites check |
| `config/settings.default.json` | `winget`, `ansible`, `docker`, `ui`, `displayBackend` sections |
| `config/settings.default.jsonc` | Same with comments |
| `TcFltPkgMgr.ps1` | OS detection; backend init order; Linux config paths |

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