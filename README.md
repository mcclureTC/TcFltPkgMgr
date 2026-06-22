# TcFltPkgMgr

A fleet management wrapper around `tcpkg` (TwinCAT Package Manager) that simplifies installing, upgrading, and uninstalling packages across multiple remote TwinCAT PCs simultaneously.

> **Status:** Under active development. Many features are still being tested. Use with care in production environments.

---

## Requirements

- PowerShell 7 (PS7) — required for parallel SSH execution
- [Posh-SSH](https://github.com/darkoperator/Posh-SSH) PowerShell module (`Install-Module Posh-SSH`)
- TwinCAT Package Manager (`tcpkg`) installed on the local machine
- `tcpkg` installed on each remote target at `C:\ProgramData\Beckhoff\TcPkg\TcPkg.exe` (configurable)
- SSH enabled on each remote target
- Administrator privileges on the local machine

---

## Launching the Program

```powershell
.\TcFltPkgMgr.ps1 -AsAdmin -Live
```

| Switch | Description |
|--------|-------------|
| `-AsAdmin` | Re-launches the script with administrator privileges (required for tcpkg to write its config) |
| `-Live` | Turns off Read-Only mode so commands actually execute. Without this, commands are shown but not run. |

You can also toggle Read-Only mode from inside the program via **Setup > 9. Read-only mode**.

---

## First-Time Setup

### 1. Generate local config files

From the main menu, go to **7. Setup**, then select **5. Generate local config files**.

This creates two files in the `config/` folder that you can edit without affecting the defaults:

- `feeds.local.json` — add custom or authenticated Beckhoff feeds
- `settings.local.json` — override SSH timeouts, logging, tcpkg paths, and UI behaviour

These files are gitignored and will not be overwritten by updates.

### 2. Configure your package feeds

Go to **Setup > 4. Manage feeds / sources**.

The dashboard shows all feeds currently configured in tcpkg on the local machine. To add a Beckhoff preset feed (Stable, Outdated, Testing, Preview):

1. Choose **1. Add Beckhoff preset**
2. Select the feed from the numbered list
3. Enter your Beckhoff account username
4. `tcpkg` will prompt for your password and the feed disclaimer — respond directly in the console

> Feed credentials are stored encrypted by tcpkg; they are never written to disk in plain text by this tool.

To toggle a feed on or off, enter its row number (11, 12, etc.) at the **Choice:** prompt.

### 3. Add remote targets

Go to **Setup > 1. Add remote target**.

For each remote TwinCAT PC you want to manage, you will be prompted for:

| Field | Description |
|-------|-------------|
| Name | A friendly label (e.g. `PC-1`) |
| Address | IP address or hostname |
| Port | SSH port (default: 22) |
| User | SSH username |
| Password | SSH password (stored by tcpkg, not this tool) |
| Internet Access | Whether the remote machine can reach Beckhoff's feed servers directly |

**Internet Access** is the key routing decision:

- **Yes** — the remote machine downloads packages from its own configured feeds via SSH. Faster and more scalable.
- **No** — the local machine resolves packages and pushes them to the remote via `tcpkg -r`. Use this for air-gapped machines or machines missing a required feed.

> If a machine has Internet Access = Yes but is missing the required feed, TcFltPkgMgr will automatically switch it to push-from-local for that operation and restore it afterwards.

### 4. Import targets from CSV (optional)

If you have many targets, you can define them in a CSV file and import them via **Setup > 2. Import targets from CSV**.

The CSV must have these columns:

```
Name,Address,Port,User,InternetAccess,Password
PC-1,192.168.100.101,22,Administrator,True,
PC-2,192.168.100.102,22,Administrator,True,
```

Passwords are not stored in the CSV (the column should be empty). You will be prompted for a shared SSH password during import. You can also export your current targets to a CSV via **Setup > 3. Export targets to CSV**.

---

## Installing a Package

From the main menu, select **1. Fleet Install**.

1. Enter a partial package name to search (e.g. `opc`)
2. Select the feed to search, or choose **All feeds**
3. Pick a package from the results list
4. Pick a version, or choose **Latest**
5. The fleet dashboard appears — select which targets to install on (by number, comma-separated, or range e.g. `11-15`)
6. Enter SSH credentials if prompted
7. Confirm and watch the batch dashboard as installs run in parallel

Targets with Internet Access = Yes install via parallel SSH. Targets missing the required feed automatically switch to push-from-local and are restored after the operation.

Use `-` and `+` on the numeric keypad to page through the target list when the fleet exceeds the page size (default 20, configurable via **7. UI Config**).

Both the Fleet and Setup dashboards show `OS` (`Win`/`Lnx`/`Mac`) and `Type` (`Phys`/`VM`/`Cntr`) columns for every target. Row colours indicate target type: Linux/macOS rows appear in cyan, container rows in magenta, and Windows rows use green/red/grey for online/offline/checking. The `Internet` column shows `---` for Linux and container targets — they manage their own internet access and do not use the push-from-local path.

Press `*` to sort by any column — Name, Address, Port, Internet Access, or Status. The sort order is saved to `targets.local.json` immediately so it persists across restarts. Press `*` again on the same column to toggle ascending/descending.

Press `/` to filter the target list by any column value. Active filters show in the dashboard: `[Filter: Reachable = 'online']  7 → 4 targets`. Press `/` then `0` to clear. Sort and filter state is shared between Fleet and Setup — both screens always show targets in the same order.

---

## Other Operations

| Menu | Description |
|------|-------------|
| **2. Fleet Upgrade** | Upgrade a package across selected targets |
| **3. Fleet Uninstall** | Uninstall a package across selected targets |
| **4. Package Status** | Check installed version of a package across all targets at once |
| **5. Outdated Check** | List all packages with newer versions available across the fleet |
| **7. UI Config** | Page size, display backend, and other display preferences |
| **8. Setup** | Add/remove targets, manage feeds, import/export config, view command log |

---

## Credential Storage

Passwords (SSH credentials, feed passwords) are stored encrypted on disk — never in plain text and never committed to the repository.

| Platform | Backend | Store location |
|----------|---------|---------------|
| Windows | Windows DPAPI (`ProtectedData`) | `config/credentials.win.json` |
| Linux / macOS | AES-256, random machine key | `config/credentials.local.enc` |

On Windows, credentials can only be decrypted by the same user account that saved them. On Linux, a cryptographically random 256-bit key is generated on first use and stored in `config/credentials.key`. Security is provided by filesystem permissions on the config directory — restrict with `chmod 700 ~/.config/tcfltpkgmgr` on Linux.

When Ansible support is added (Phase 5), Ansible Vault passwords will also be stored here, providing a two-tier model: the TcFltPkgMgr credential store protects the vault password, and Ansible Vault protects playbook secrets.

All credential files are listed in `.gitignore` and will never be committed.

---

## Cross-platform Support

TcFltPkgMgr runs on Windows, Linux, and macOS. The operator machine (where the tool runs) can be any platform — it manages remote Windows TwinCAT targets via SSH regardless of local OS.

| Feature | Windows operator | Linux / macOS operator |
|---------|-----------------|----------------------|
| Fleet dashboard | ✅ | ✅ |
| SSH installs on remote targets | ✅ | ✅ |
| Ansible (Linux targets) | ✅ | ✅ |
| Docker container management | ✅ | ✅ |
| tcpkg push-from-local | ✅ | ❌ requires local tcpkg |
| Feed management (add/remove) | ✅ | ❌ requires local tcpkg |
| Credential storage | DPAPI encrypted file | AES-256 encrypted file |

On Linux, menu options that require a local tcpkg installation are shown with a `[Windows only]` label. All SSH-based operations (remote installs, Ansible, Docker exec) work identically on all platforms.

The tool detects the operating system at startup and gates features accordingly via `Test-FltFeatureAvailable`.

**Reachability caching:** The fleet dashboard checks TCP port 22 on each target to determine online/offline status. Targets confirmed online are cached for 60 seconds (configurable via `ui.reachCacheSecs`) so navigating between menus doesn't re-check targets unnecessarily. Offline targets are always re-checked. The current page of targets is checked first on startup, with remaining pages queued as a background job.

---

## Built-in Tests

Run **Setup → 10** to open the test runner dashboard, which shows all diagnostic and integration test suites with last-run results and timestamps.

```
  #     Suite                                 Tests  Last run          Result
  ── Diagnostics ───────────────────────────────────────────────────────
  1     All diagnostic tests                  29     2026-06-16        29/29 ✓
  ── Integration ───────────────────────────────────────────────────────
  11    File I/O                              ?      never             —
  12    Pagination and target selection       ?      never             —
  13    SSH connectivity  [needs target]      ?      never             —
  14    Read-only mode                        ?      never             —
  15    Log system                            ?      never             —
  16    Reachability cache                    ?      never             —
  ── Targets for integration tests (21+ to toggle) ─────────────────────
  21  ● PC-1   192.168.8.101
  22    PC-2   192.168.8.102
```

**Input (numpad-only):** `1` all diagnostics · `9` all integration · `11`–`16` specific suite · `21+` toggle targets (supports `21,23` or `21-24` or `21..24`) · `0` back.

**Diagnostics** (29 checks) run offline — no network, SSH, or tcpkg calls. They verify adapter wiring, credential round-trips, config loading, sort/filter logic, and target store serialization.

**Integration suites** test real infrastructure: file I/O, pagination, SSH connectivity, read-only mode, log system, and reachability cache. Suite 13 (SSH) requires at least one target toggled on with `21+`. Results are saved to `config/test-results.json` and shown as last-run history on the dashboard.

---

All `tcpkg` commands run by this tool are logged to `logs/commands.ndjson` (newline-delimited JSON). Each entry includes timestamp, session ID, target, command, exit code, and duration.

Batch operations (install/upgrade/uninstall) are logged as a single `batch` event with per-target results.

To view recent log entries from inside the tool: **Setup > 8. View command log**.

---

## WinGet integration

Targets with `PackageManager = winget` (set via **Setup > Add/Edit target**) use `winget` instead of `tcpkg` for install, upgrade, and uninstall operations. The operator machine does not need winget installed — winget runs on the remote target via SSH.

**Routing:** `FleetExecutor` splits targets into three buckets per operation:

| Bucket | Condition | Executor |
|--------|-----------|----------|
| tcpkg SSH | Internet Access = Yes, PackageManager = tcpkg or both | `Invoke-FltSshBatch` |
| WinGet SSH | Internet Access = Yes, PackageManager = winget or both | `Invoke-FltWinGetBatch` |
| Push | Internet Access = No | tcpkg local push |

Setting `PackageManager = both` routes a target into both SSH buckets — useful for targets that have both TwinCAT and general Windows packages.

**Operator machine winget** (optional): install winget locally to enable package search and version browsing via `Search-FltWinGetPackage`. Without it, install by id still works by typing the package id directly.

**Exit codes:** WinGet's numeric exit codes are mapped to readable status: `0` = OK, `-1978335212` = not found, `-1978335189` = already installed, `-1978335188` = no upgrade available.

**Package manager routing function:** `Get-FltEffectivePackageManager` resolves a target's package manager, defaulting to `tcpkg` for Windows targets with no explicit setting.

---

## Configuration

### `settings.default.json` sections

| Section | Key settings |
|---------|-------------|
| `ssh` | `timeoutSeconds` (1800), `throttleLimit` (25), `jitterMaxMs`, `retryCount` |
| `winget` | `remoteWinGetPath` ("winget"), `timeoutSeconds` (300) |
| `ansible` | `executablePath` ("ansible-playbook"), `useWsl` (false), `wslDistro`, `tempDir`, `forks` (10) |
| `tcpkg` | `executablePath`, `remoteTcpkgPath` |
| `docker` | `throttleLimit` (20), `logTailLines` (50) |
| `ui` | `dashboardPageSize` (20), `reachCacheSecs` (60), `displayBackend` |
| `log` | `retentionDays` (30), `captureFleet` |

Override any setting in `config/settings.local.json` (gitignored).

---

## WinGet package management

From the Fleet home screen press **2. WinGet** to access the WinGet sub-menu:

- **1. Install** — search winget, pick package and version, select targets, install in parallel via SSH
- **2. Upgrade** — search, pick, select targets, upgrade in parallel
- **3. Uninstall** — select a reference target, query what's installed via `winget list`, pick a package, select all targets to uninstall from
- **4. Status** — show installed/not-installed for a given package id across all winget targets

Microsoft Store apps (`msstore` source) are automatically excluded from Install and Upgrade — they require an interactive Microsoft account session and cannot be installed via SSH.

---

## Docker prerequisites

Docker Desktop must be installed on the operator machine for:
- Managing containers on remote Linux targets (DCC-4, DCC-5) via SSH
- Running the Ansible operator container (`tcflt-ansible`)
- Managing Windows containers (future)

Install Docker Desktop from https://www.docker.com/products/docker-desktop/

TcFltPkgMgr detects Docker status automatically:

| Status | Meaning |
|--------|---------|
| `running` | Docker daemon is ready — all Docker operations available |
| `starting` | Docker Desktop is open but daemon still initialising |
| `stopped` | Docker Desktop installed but not running — TcFltPkgMgr can start it |
| `not-installed` | Docker Desktop not found |

Run **Suite 22** in the test runner to check Docker status. TcFltPkgMgr will offer to start Docker Desktop from Setup when needed (Phase 7).

---

## Docker Desktop (operator machine)

Docker Desktop must be installed and running on the operator machine for:
- The Ansible operator container (`tcflt-ansible`)
- Managing Docker containers on remote targets (Phase 7)
- Windows containers (future)

TcFltPkgMgr can start Docker Desktop automatically if it is installed but not running — this is available from **Setup → Prepare** (Phase 7 UI).

| Status | Meaning |
|--------|---------|
| `running` | Daemon ready — all Docker operations available |
| `starting` | Docker Desktop launched, daemon still initialising |
| `stopped` | Docker Desktop installed but not running — TcFltPkgMgr can start it |
| `not-installed` | Docker Desktop not found — install from https://www.docker.com/products/docker-desktop/ |

Run **Setup → 10. Diagnostics → Suite 22** to check Docker status.

---

## Docker Desktop (operator machine)

TcFltPkgMgr uses Docker on the operator machine for two purposes:
- **Ansible operator container** (`tcflt-ansible`) — provides Ansible without WSL
- **Windows containers** — managing Windows container workloads (Phase 7)

Docker Desktop is detected automatically. Status is shown in **Setup → Diagnostics → Suite 22**.

| Status | Meaning |
|--------|---------|
| `running` | Daemon ready — all Docker features available |
| `starting` | Docker Desktop launched, daemon initialising |
| `stopped` | Docker Desktop installed but not running — TcFltPkgMgr can start it from Setup |
| `not-installed` | Docker Desktop not installed |

TcFltPkgMgr can launch Docker Desktop automatically when needed (via `Start-FltDockerDesktop`). Docker Desktop is detected at its standard path (`C:\Program Files\Docker\Docker\Docker Desktop.exe`) or via the Windows App Paths registry key.

---

## Ansible prerequisites

Ansible runs in a Docker container on the operator Windows machine — no WSL or separate Linux machine needed. The container (`tcflt-ansible`) is built from `docker/Dockerfile.ansible` included in this project.

### Quick start

```powershell
# 1. Build the Ansible operator container (once)
docker build -f docker/Dockerfile.ansible -t tcflt-ansible .

# 2. Start the container (persists across reboots)
docker run -d --name tcflt-ansible --restart unless-stopped `
  -v ${PWD}/ansible:/ansible `
  tcflt-ansible

# 3. Verify in TcFltPkgMgr — Setup → 10. Diagnostics → Suite 21
```

### Detection modes (in priority order)

| Mode | Detection | How invoked |
|------|-----------|-------------|
| `native` | `ansible-playbook` on PATH | `ansible-playbook` |
| `wsl` | `wsl ansible-playbook --version` exits 0 | `wsl [-d <distro>] ansible-playbook` |
| `docker` | `docker exec tcflt-ansible ansible-playbook --version` exits 0 | `docker exec tcflt-ansible ansible-playbook` |
| *(none)* | None of the above | Suite 21 passes with Available=false |

The container name defaults to `tcflt-ansible` and can be overridden via `ansible.dockerContainer` in `settings.local.json`. The `community.docker`, `community.general`, and `ansible.posix` collections are pre-installed in the container.

---

## Ansible inventory (Phase 5.2)

`New-FltAnsibleInventory` generates an INI-format Ansible inventory from the fleet target list. It is called automatically before each Ansible run and cleaned up afterward via `Remove-FltAnsibleInventory`.

The file is written to `ansible/inventory/hosts.ini` (gitignored) and recreated fresh on every run.

### Inventory groups

| Group | Targets included |
|-------|-----------------|
| `[physical]` | `OS='linux'`, `TargetType='physical'` |
| `[vm]` | `OS='linux'`, `TargetType='vm'` |
| `[containers]` | `OS='linux'`, `TargetType='container'` |
| `[linux:children]` | Meta-group combining all of the above (written when more than one group exists) |

Non-Linux targets are silently skipped. If no Linux targets exist, the file is not written.

### Authentication

Inventory entries use SSH key authentication only — **passwords are never written to inventory files**.

- If `ssh.privateKeyPath` is set in settings and the file exists, `ansible_ssh_private_key_file` is added (path normalised to forward slashes for POSIX Ansible).
- Otherwise no auth var is written; Ansible uses its own key discovery at run time.

### Container targets

Linux container targets include `community.docker.docker_api` connection vars so the Ansible Docker connection plugin can reach them:

```ini
web-1 ansible_host=192.168.8.50 ansible_user=admin ansible_port=22 ansible_connection=community.docker.docker_api ansible_docker_host=tcp://192.168.8.50:2375
```

The Docker host address is resolved from the matching `DockerHost` target in the fleet. The daemon port defaults to 2375 and can be overridden with `docker.daemonPort` in `settings.local.json`.

---

## Ansible playbook builder (Phase 5.3)

Five private functions in `execution/AnsibleExecutor.ps1` generate YAML playbooks and write them to `ansible/playbooks/` (gitignored) before each Ansible run. Files are timestamped and cleaned up after the run.

| Function | Ansible module | Actions |
|----------|---------------|---------|
| `_Get-PackagePlaybook` | `ansible.builtin.package` | `install` · `upgrade` · `remove` |
| `_Get-ServicePlaybook` | `ansible.builtin.systemd` | `start` · `stop` · `restart` · `enable` · `disable` |
| `_Get-UserPlaybook` | `ansible.builtin.user` | `create` · `remove` |
| `_Get-FilePlaybook` | `ansible.builtin.copy` | copy a file from controller to targets |
| `_Get-DockerPlaybook` | `community.docker.docker_container` | `pull` · `start` · `stop` · `restart` · `recreate` · `remove` |

All playbooks use `become: true` (sudo escalation) and `gather_facts: false` for speed. Package operations use `ansible.builtin.package` which is distro-agnostic — the same playbook works on Debian, Ubuntu, and RPM-based targets. Docker container playbooks default to `hosts: containers`; all others default to `hosts: linux`.

---

## Preparing targets for WinGet

Use **Setup → select target → 4. Prepare target** to install WinGet on a remote Windows machine via SSH. The installer:

1. Checks if WinGet is already installed — skips if present
2. Downloads the latest WinGet bundle and Windows App Runtime redistributable from GitHub (~230MB total)
3. Provisions WinGet system-wide via a SYSTEM-context scheduled task
4. Attempts to install the Windows App Runtime framework as the authenticating user
5. If the framework install is blocked (Windows Update disabled machines), schedules a one-time logon task to complete activation at next autologin
6. Reboots the target — autologin fires, the logon task runs, WinGet activates
7. Verifies `winget --version` in a fresh SSH session after reboot

**Requirements:** Internet access on the target, SSH running as the authenticating user (not SYSTEM).

**Windows Update disabled (TwinCAT engineering PCs):** The Windows App Runtime framework package cannot be installed via SSH — it requires an interactive desktop token. The installer handles this automatically by scheduling a logon task that runs during autologin, which provides the required token. The reboot that follows activates WinGet fully without any manual intervention.

**If the automated install fails** and the hard-wall error is shown, three options are available:

1. Enable Windows Update temporarily, run it once, disable it — the runtime installs via WU
2. RDP to the target and run the displayed PowerShell commands once interactively
3. Keep using `tcpkg` for this target (edit target, set `PackageManager = tcpkg`)

---

## Configuration Reference

`config/settings.local.json` overrides (create with **Setup > 5**):

```jsonc
{
  "ssh": {
    "timeoutSeconds": 1800,   // per-target SSH timeout
    "throttleLimit":  25      // max parallel SSH connections (keep ≤50 to avoid TCP pool exhaustion)
  },
  "docker": {
    "throttleLimit": 20,      // max parallel docker exec connections
    "logTailLines":  50       // lines shown by Container > View logs
  },
  "tcpkg": {
    "executablePath":  "tcpkg",                                       // local tcpkg command
    "remoteTcpkgPath": "C:\\ProgramData\\Beckhoff\\TcPkg\\TcPkg.exe"  // path on remote targets
  },
  "log": {
    "retentionDays": 30,      // days to keep log entries
    "captureOutput": false    // log full tcpkg output (verbose)
  }
}
```

`config/feeds.local.json` — add custom feeds:

```jsonc
{
  "beckhoff": {},
  "custom": {
    "MyInternalFeed": {
      "url":      "https://my-server/nuget/",
      "priority": 10,
      "username": "feeduser"
    }
  }
}
```

---

## File Layout

```
TcFltPkgMgr/
├── TcFltPkgMgr.ps1           # Entry point
├── config/
│   ├── feeds.default.json    # Built-in Beckhoff feed presets (do not edit)
│   ├── feeds.local.json      # Your local feed overrides (gitignored)
│   ├── settings.default.json
│   ├── settings.local.json   # Your local settings (gitignored)
│   └── credentials.win.json  # Encrypted credentials — Windows (gitignored)
├── diagnostics/
│   └── Diagnostics.ps1       # Built-in self-test (Setup > 10)
├── logs/
│   └── commands.ndjson       # Command log (gitignored)
├── classes/                  # PS class definitions (FleetTarget etc.)
├── data/                     # Config, credential, target, package repositories
│   ├── CredentialAdapter.ps1        # Stable credential interface
│   ├── CredentialBackendWindows.ps1 # DPAPI backend (Windows)
│   ├── CredentialBackendFile.ps1    # AES-256 backend (Linux)
│   └── CredentialBackends.ps1       # Backend selector
├── execution/                # SSH executor, fleet executor, command log writer
└── ui/
    ├── DisplayAdapter.ps1    # Stable display interface (replaceable)
    ├── DashboardAnsi.ps1     # ANSI terminal backend
    ├── DisplayBackends.ps1   # Display backend selector
    ├── SortFilter.ps1        # Sort/filter helpers and interactive pickers
    └── menus/
        ├── FleetMenu.ps1
        ├── PackageMenu.ps1
        ├── TargetMenu.ps1
        └── UiConfigMenu.ps1  # Runtime UI settings (page size, display backend)
```