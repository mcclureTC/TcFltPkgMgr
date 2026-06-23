# =============================================================================
#  TcFltPkgMgr — Command Log
#  Daily-rotating NDJSON log. One JSON object per line for append efficiency.
#  Log file name: logs/tcflt-YYYY-MM-DD.log.json
# =============================================================================

# Initialise the log subsystem. Call once at startup.
function Initialize-FltLog {
    param([string]$LogDir)
    $Script:FltLogDir   = $LogDir
    $Script:FltSessionId = (New-Guid).ToString('N').Substring(0, 8)
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir | Out-Null
    }
    # Enforce retention on startup (non-blocking)
    Invoke-FltLogRetention
}

# Path to today's log file — computed fresh each call for midnight rollover safety.
function Get-FltLogPath {
    $date = (Get-Date).ToString('yyyy-MM-dd')
    return Join-Path $Script:FltLogDir "tcflt-$date.log.json"
}

# Begin a command entry. Returns the entry object; caller must call
# Complete-FltCommandEntry after execution to record exit code and duration.
function Start-FltCommandEntry {
    param(
        [string] $Command,
        [string] $Target = 'local',
        [string] $Mode   = 'live'    # 'live' or 'read-only'
    )
    $entry = [CommandEntry]::new()
    $entry.Timestamp  = (Get-Date).ToString('o')
    $entry.SessionId  = $Script:FltSessionId
    $entry.Target     = $Target
    $entry.Mode       = $Mode
    $entry.Command    = $Command
    $entry.ExitCode   = -1
    $entry.DurationSec = 0

    # Immediately update the dashboard last-command display
    $Script:FltLastCmd = "[$Target]  $Command"

    if (Get-FltCfgValue 'log' 'captureSession' $false) {
        _Write-FltLogEntry @{ ts = $entry.Timestamp; session = $entry.SessionId;
            event = 'cmd_start'; target = $Target; mode = $Mode; cmd = $Command }
    }

    return $entry
}

# Complete a command entry started by Start-FltCommandEntry and write it to the log.
function Complete-FltCommandEntry {
    param(
        [CommandEntry] $Entry,
        [int]          $ExitCode,
        [double]       $DurationSec,
        [string]       $Output = ''
    )
    $Entry.ExitCode    = $ExitCode
    $Entry.DurationSec = [math]::Round($DurationSec, 2)

    $record = [ordered]@{
        ts      = $Entry.Timestamp
        session = $Entry.SessionId
        target  = $Entry.Target
        mode    = $Entry.Mode
        cmd     = $Entry.Command
        exit    = $ExitCode
        durSec  = $Entry.DurationSec
        output  = $null
    }

    if ((Get-FltCfgValue 'log' 'captureOutput' $false) -and $Output) {
        # Strip version banner before storing
        $lines = ($Output -split "`n") | Where-Object { $_ -notmatch '^TcPkg \d' }
        $record.output = ($lines -join "`n").Trim()
        $Entry.Output  = $record.output
    }

    _Write-FltLogEntry $record
}

# Write batch operation results to log. Called once per batch after completion.
function Write-FltBatchEntry {
    param(
        [string]   $Action,
        [string]   $PackageSpec,
        [object[]] $Results
    )
    if (-not (Get-FltCfgValue 'log' 'captureFleet' $true)) { return }

    # PackageManager is now a first-class field on BatchResult — read from first result
    $pm = ($Results | Select-Object -First 1).PackageManager
    if (-not $pm) { $pm = 'tcpkg' }   # safe default for legacy callers

    $record = [ordered]@{
        ts             = (Get-Date).ToString('o')
        session        = $Script:FltSessionId
        event          = 'batch'
        action         = $Action
        package        = $PackageSpec
        packageManager = $pm
        results        = @($Results | ForEach-Object {
            $tgt  = $Script:FleetTargets | Where-Object { $_.Name -eq $_.TargetName } | Select-Object -First 1
            $tgtN = $_.TargetName   # capture for inner scope
            $tgt  = $Script:FleetTargets | Where-Object { $_.Name -eq $tgtN } | Select-Object -First 1
            [ordered]@{
                target      = $_.TargetName
                targetType  = if ($tgt) { $tgt.TargetType } else { '' }
                status      = $_.Status
                durSec      = [math]::Round($_.DurationSec, 1)
                note        = $_.Note
            }
        })
    }
    _Write-FltLogEntry $record
}

# Write a fleet query result (installed package state across all targets).
function Write-FltFleetQueryEntry {
    param([FleetPackageSummary] $Summary)
    if (-not (Get-FltCfgValue 'log' 'captureFleet' $true)) { return }
    $record = [ordered]@{
        ts      = (Get-Date).ToString('o')
        session = $Script:FltSessionId
        event   = 'fleet_query'
        package = $Summary.PackageName
        states  = @($Summary.States | ForEach-Object {
            [ordered]@{ target = $_.TargetName; installed = $_.InstalledVersion; status = $_.Status }
        })
    }
    _Write-FltLogEntry $record
}

# Internal: append one NDJSON line to today's log file.
function _Write-FltLogEntry {
    param([object]$Record)
    try {
        $line = $Record | ConvertTo-Json -Compress -Depth 5
        Add-Content -Path (Get-FltLogPath) -Value $line -Encoding UTF8
    } catch {
        # Log write failure is non-fatal — never crash the tool because of logging.
    }
}

# Delete log files older than retentionDays.
function Invoke-FltLogRetention {
    if (-not (Test-Path $Script:FltLogDir)) { return }
    $days = 30
    if ($Script:FltCfg -and $Script:FltCfg.ContainsKey('log') -and $Script:FltCfg.log.ContainsKey('retentionDays')) {
        $days = [int]$Script:FltCfg.log.retentionDays
    }
    $cutoff = (Get-Date).AddDays(-$days)
    Get-ChildItem -Path $Script:FltLogDir -Filter 'tcflt-*.log.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Read command history from log files for the log viewer.
function Get-FltCommandHistory {
    param(
        [int]    $LastDays  = 7,
        [string] $Target    = '',
        [string] $CmdVerb   = '',      # e.g. 'install', 'upgrade'
        [string] $SessionId = ''
    )
    if (-not (Test-Path $Script:FltLogDir)) { return @() }

    $cutoff = (Get-Date).AddDays(-$LastDays)
    $results = [System.Collections.Generic.List[object]]::new()

    Get-ChildItem -Path $Script:FltLogDir -Filter 'tcflt-*.log.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cutoff } |
        Sort-Object Name |
        ForEach-Object {
            Get-Content $_.FullName -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try { $_ | ConvertFrom-Json } catch { $null }
                } |
                Where-Object { $null -ne $_ -and $null -ne $_.cmd } |
                Where-Object {
                    (-not $Target    -or $_.target  -eq $Target)       -and
                    (-not $CmdVerb   -or $_.cmd -like "*$CmdVerb*")    -and
                    (-not $SessionId -or $_.session -eq $SessionId)
                } |
                ForEach-Object { $results.Add($_) }
        }

    return $results.ToArray()
}

# Display the command history in a simple table in the content zone.
function Show-FltCommandLog {
    param(
        [int]    $LastDays = 7,
        [string] $Target   = '',
        [string] $CmdVerb  = ''
    )
    $entries = Get-FltCommandHistory -LastDays $LastDays -Target $Target -CmdVerb $CmdVerb
    if ($entries.Count -eq 0) {
        Write-Host "  No log entries found for the last $LastDays day(s)." -ForegroundColor Yellow
        return
    }

    $w = [Math]::Max([Console]::WindowWidth, 60) - 1
    Write-Host ''
    Write-Host ("  {0,-19}  {1,-14}  {2,-6}  {3,-5}  {4}" -f `
        'Timestamp', 'Target', 'Mode', 'Exit', 'Command') -ForegroundColor DarkGray
    Write-Host ("  " + '-' * ($w - 2)) -ForegroundColor DarkGray

    foreach ($e in $entries | Select-Object -Last 50) {
        $ts    = try { ([datetime]$e.ts).ToString('MM-dd HH:mm:ss') } catch { $e.ts }
        $color = if ($e.exit -eq 0) { 'Green' } elseif ($e.exit -eq -1) { 'DarkGray' } else { 'Red' }
        $mode  = if ($e.mode -eq 'read-only') { 'R/O  ' } else { 'live ' }
        $cmdMax = $w - 52
        $cmd   = if ($e.cmd.Length -gt $cmdMax) { $e.cmd.Substring(0, $cmdMax - 1) + '~' } else { $e.cmd }
        Write-Host ("  {0,-19}  {1,-14}  {2,-6}  {3,-5}  {4}" -f `
            $ts, ($e.target ?? 'local'), $mode, $e.exit, $cmd) -ForegroundColor $color
    }
    Write-Host ''
}