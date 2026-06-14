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
| Name | A friendly label (e.g. `DCC-1`) |
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
DCC-1,192.168.8.101,22,Administrator,True,
DCC-2,192.168.8.102,22,Administrator,True,
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

---

## Other Operations

| Menu | Description |
|------|-------------|
| **2. Fleet Upgrade** | Upgrade a package across selected targets |
| **3. Fleet Uninstall** | Uninstall a package across selected targets |
| **4. Package Status** | Check installed version of a package across all targets at once |
| **5. Outdated Check** | List all packages with newer versions available across the fleet |
| **7. Setup** | Add/remove targets, manage feeds, import/export config, view command log |

---

## Command Log

All `tcpkg` commands run by this tool are logged to `logs/commands.ndjson` (newline-delimited JSON). Each entry includes timestamp, session ID, target, command, exit code, and duration.

Batch operations (install/upgrade/uninstall) are logged as a single `batch` event with per-target results.

To view recent log entries from inside the tool: **Setup > 8. View command log**.

---

## Configuration Reference

`config/settings.local.json` overrides (create with **Setup > 5**):

```jsonc
{
  "ssh": {
    "timeoutSeconds": 1800,   // per-target SSH timeout
    "throttleLimit":  10      // max parallel SSH connections
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
│   └── settings.local.json   # Your local settings (gitignored)
├── logs/
│   └── commands.ndjson       # Command log (gitignored)
├── classes/                  # PS class definitions
├── data/                     # Config, credential, target, package repositories
├── execution/                # SSH executor, fleet executor, command log writer
└── ui/                       # Dashboard, menus, prompts
```