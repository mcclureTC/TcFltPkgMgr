<#
.SYNOPSIS
    TcFlt Package Manager — Fleet-first TwinCAT package management tool.

.DESCRIPTION
    A PowerShell 7 tool for managing Beckhoff TwinCAT packages across a fleet
    of remote PCs. The fleet is the home screen; parallel SSH is the default
    execution path; every tcpkg command issued is logged and displayed.

    Architecture: SOLID-aligned layered modules.
      classes/  — typed data models (no logic, no tcpkg calls)
      data/     — data repositories (tcpkg calls, config, credentials)
      execution/ — SSH executor, fleet orchestrator, command log
      ui/        — dashboard (render), prompts (input), menus (flow)

    Configuration:
      config/feeds.default.json    — Beckhoff feed presets (committed)
      config/settings.default.json — tool defaults (committed)
      config/feeds.local.json      — site feeds, gitignored
      config/settings.local.json   — site overrides, gitignored
      config/profiles.json         — fleet profiles, gitignored

    Command log: logs/tcflt-YYYY-MM-DD.log.json (daily rotation, gitignored)

.PARAMETER Live
    Start in live mode (read-only OFF). By default the tool starts read-only.

.PARAMETER AsAdmin
    Silently relaunch as Administrator if the current session is not elevated.

.EXAMPLE
    .\TcFltPkgMgr.ps1

.EXAMPLE
    .\TcFltPkgMgr.ps1 -Live -AsAdmin

.NOTES
    Requires PowerShell 7+.
    Posh-SSH (BSD 3-Clause, Copyright (c) 2015 Carlos Perez) is an optional
    runtime dependency for parallel SSH batch mode. See THIRD-PARTY-NOTICES.md.

.LINK
    https://github.com/darkoperator/Posh-SSH
#>

[CmdletBinding()]
param(
    [switch] $Live,
    [switch] $AsAdmin
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# -- Self-elevation -------------------------------------------------------------
function _Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($AsAdmin -and -not (_Test-IsAdmin)) {
    $scriptPath = $PSCommandPath
    if ($scriptPath) {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"")
        if ($Live)    { $argList += '-Live'    }
        if ($AsAdmin) { $argList += '-AsAdmin' }
        Start-Process -FilePath 'pwsh.exe' -ArgumentList $argList -Verb RunAs
        exit 0
    }
}

# -- Resolve script root --------------------------------------------------------
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# -- Load modules in dependency order ------------------------------------------
$modules = @(
    'classes\Models.ps1',
    'data\ConfigRepository.ps1',
    'data\CredentialRepository.ps1',
    'execution\CommandLog.ps1',
    'data\TargetRepository.ps1',
    'data\PackageRepository.ps1',
    'data\FleetQuery.ps1',
    'execution\SshExecutor.ps1',
    'execution\FleetExecutor.ps1',
    'ui\Prompts.ps1',
    'ui\DisplayAdapter.ps1',      # stable interface — menus call this
    'ui\DashboardAnsi.ps1',       # ANSI backend — dot-sourced at script scope
    'ui\DisplayBackends.ps1',     # backend loader
    'ui\menus\TargetMenu.ps1',
    'ui\menus\PackageMenu.ps1',
    'ui\menus\FleetMenu.ps1'
)

try {

foreach ($m in $modules) {
    $path = Join-Path $Root $m
    if (Test-Path $path) {
        . $path
    } else {
        Write-Warning "Module not found: $path"
    }
}

# -- Initialise display backend ------------------------------------------------
# Must run after ConfigRepository (for Get-FltCfgValue) and DisplayBackends.
# The $Root\ui path is passed so the backend can find DashboardAnsi.ps1.
Set-FltDisplayBackend `
    -Backend (Get-FltCfgValue 'ui' 'displayBackend' 'ansi') `
    -UiRoot  (Join-Path $Root 'ui')

# -- Global state --------------------------------------------------------------

# Read-only mode - true = no changes are made; commands are shown but not run.
$Script:FltReadOnly = -not $Live

# Last exit code from a tcpkg call.
$Script:FltLastExit = 0

# Last tcpkg command string issued (shown in the dashboard command row).
$Script:FltLastCmd = ''

# Posh-SSH availability flag (cached after first successful import).
$Script:FltPoshSshAvailable = $false

# Fleet targets loaded at startup and refreshed after mutations.
$Script:FleetTargets = @()

# Batch dashboard state (set by Show-FleetBatchDashboard).
$Script:FltBatchStatus      = @{}
$Script:FltBatchDashHeight  = 0
$Script:FltBatchScrollStart = 0

# General dashboard height tracker.
$Script:FltDashHeight = 0

# Session ID for the command log (8-char hex).
$Script:FltSessionId = ''

# Config and log directories.
$Script:FltConfigDir = Join-Path $Root 'config'
$Script:FltLogDir    = Join-Path $Root 'logs'

# Merged configuration hashtable (populated by Initialize-FltConfig).
$Script:FltCfg = @{}

# Available feed definitions (populated by Initialize-FltConfig).
$Script:FltFeeds = @()

# -- Initialise -----------------------------------------------------------------
Initialize-FltConfig -ConfigDir $Script:FltConfigDir
Initialize-FltLog    -LogDir    $Script:FltLogDir

# -- Admin check ----------------------------------------------------------------
if (-not (_Test-IsAdmin)) {
    Write-Host 'Note: not running as Administrator. Most tcpkg actions require elevation.' -ForegroundColor Yellow

    # Check if tcpkg is even available before offering elevation.
    $tcpkgExe = Get-FltTcpkgExe
    if (-not (Get-Command $tcpkgExe -ErrorAction SilentlyContinue)) {
        Write-Host 'Warning: tcpkg was not found on PATH.' -ForegroundColor Yellow
        Write-Host 'You can still explore the tool in read-only mode.' -ForegroundColor Yellow
    }

    $r = (Read-Host 'Relaunch as Administrator?  [1] Yes  [0] No  (default 0)').Trim()
    if ($r -eq '1') {
        $scriptPath = $PSCommandPath
        if ($scriptPath) {
            $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"")
            if ($Live)    { $argList += '-Live'    }
            $argList += '-AsAdmin'
            Start-Process -FilePath 'pwsh.exe' -ArgumentList $argList -Verb RunAs
            exit 0
        } else {
            Write-Host 'Cannot self-elevate (script path unknown).' -ForegroundColor Yellow
            Start-Sleep -Seconds 2
        }
    }
}

# -- Generate local config if missing ------------------------------------------
$created = New-FltLocalConfig -ConfigDir $Script:FltConfigDir
if ($created.Count -gt 0) {
    Write-Host ''
    Write-Host '  First run: created local config file(s):' -ForegroundColor Cyan
    $created | ForEach-Object { Write-Host "    config/$_" }
    Write-Host '  Edit these files to add custom feeds and site settings.' -ForegroundColor DarkGray
    Write-Host ''
    Start-Sleep -Seconds 2
}

# -- Start ----------------------------------------------------------------------
    Invoke-FleetMenu

} catch {
    Write-Host ''
    Write-Host '  FATAL ERROR - press Enter to exit' -ForegroundColor Red
    Write-Host ''
    Write-Host ("  {0}" -f $_.Exception.Message)      -ForegroundColor Yellow
    Write-Host ("  {0}" -f $_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  Press Enter'
}