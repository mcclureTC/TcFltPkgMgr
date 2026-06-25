# =============================================================================
#  TcFltPkgMgr — System Menu
#  Startup sequence and health check for the operator environment.
#
#  Startup sequence (choice 1):
#    1. Docker Desktop running
#    2. tcflt-ansible container running (starts it if stopped)
#    3. All Linux targets reachable via SSH
#    4. All Windows targets reachable via SSH
#
#  Health check (choice 2):
#    Same checks, read-only, no remediation.
#
#  Phase 9.x
# =============================================================================

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function _Test-FltDockerRunning {
    try {
        $out = (& cmd /c 'docker info 2>&1') -join ''
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function _Start-FltDockerDesktop {
    # Try common Docker Desktop install paths
    $paths = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Docker\Docker Desktop.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            Start-Process $p
            return $true
        }
    }
    return $false
}

function _Get-FltVmrunExe {
    $paths = @(
        "${env:ProgramFiles(x86)}\VMware\VMware Workstation\vmrun.exe",
        "$env:ProgramFiles\VMware\VMware Workstation\vmrun.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $p } }
    return ''
}

function _Test-FltVmRunning {
    param([string]$VmxPath)
    $vmrun = _Get-FltVmrunExe
    if (-not $vmrun) { return $false }
    $running = (& cmd /c "`"$vmrun`" list 2>&1") -join "`n"
    return ($running -match [regex]::Escape($VmxPath))
}

function _Start-FltVm {
    param([string]$VmxPath)
    $vmrun = _Get-FltVmrunExe
    if (-not $vmrun) { return $false }
    & cmd /c "`"$vmrun`" start `"$VmxPath`" nogui 2>&1" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function _Test-FltAnsibleContainer {
    $name = Get-FltCfgValue 'ansible' 'dockerContainer' 'tcflt-ansible'
    try {
        $out = (& cmd /c "docker inspect --format={{.State.Running}} $name 2>&1") -join ''
        return ($out.Trim() -eq 'true')
    } catch { return $false }
}

function _Start-FltAnsibleContainer {
    $name = Get-FltCfgValue 'ansible' 'dockerContainer' 'tcflt-ansible'
    try {
        $null = (& cmd /c "docker start $name 2>&1")
        Start-Sleep -Seconds 2
        return (_Test-FltAnsibleContainer)
    } catch { return $false }
}

function _Test-FltSshReachable {
    param([string]$Address, [int]$Port = 22, [int]$TimeoutMs = 3000)
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect($Address, $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $tcp.Close()
        return $ok
    } catch { return $false }
}

function _Write-SysRow {
    param([string]$Label, [string]$Status, [string]$Note = '')
    $clr = switch ($Status) {
        'OK'      { "`e[92m" }
        'Failed'  { "`e[91m" }
        'Running' { "`e[92m" }
        'Stopped' { "`e[91m" }
        'Checking'{ "`e[93m" }
        'Skipped' { "`e[90m" }
        default   { "`e[37m" }
    }
    $noteStr = if ($Note) { "  $Note" } else { '' }
    Write-Host ("  {0,-32} {1}[{2}]{3}`e[0m" -f $Label, $clr, $Status.PadRight(8), $noteStr)
}

# ---------------------------------------------------------------------------
# Startup sequence
# ---------------------------------------------------------------------------

function Invoke-FltStartupCheck {
    Clear-Host
    Write-Host '  System  >  Startup check' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Checking operator environment...' -ForegroundColor DarkGray
    Write-Host ''

    $allOk = $true

    # ── 1. Docker Desktop ────────────────────────────────────────────────────
    Write-Host -NoNewline ("  {0,-32} " -f 'Docker Desktop')
    Write-Host "[Checking]" -ForegroundColor Yellow
    $dockerOk = _Test-FltDockerRunning
    Write-Host "`e[1A`e[0K" -NoNewline  # overwrite checking line
    if ($dockerOk) {
        _Write-SysRow 'Docker Desktop' 'Running'
    } else {
        _Write-SysRow 'Docker Desktop' 'Stopped' 'attempting to start...'
        $allOk = $false
        Write-Host ''

        # Attempt automatic start
        $launched = _Start-FltDockerDesktop
        if ($launched) {
            Write-Host '  Docker Desktop launching...' -ForegroundColor DarkGray
        } else {
            Write-Host '  Could not find Docker Desktop executable.' -ForegroundColor Yellow
        }
        Write-Host '  Press Enter once Docker Desktop is ready, or Escape/Q to skip.' -ForegroundColor DarkGray
        Write-Host ''

        # Wait for keypress — Enter = retry, Escape/Q = skip
        $userKey = $null
        while ($true) {
            if ([Console]::KeyAvailable) {
                $k = [Console]::ReadKey($true)
                if ($k.Key -eq [ConsoleKey]::Escape -or
                    $k.KeyChar -in @('q','Q')) {
                    $userKey = 'skip'; break
                }
                if ($k.Key -eq [ConsoleKey]::Enter) {
                    $userKey = 'retry'; break
                }
            }
            Start-Sleep -Milliseconds 100
        }

        if ($userKey -eq 'skip') {
            _Write-SysRow 'Docker Desktop' 'Skipped' 'user skipped'
            $allOk = $false
        } else {
            # Poll until Docker is ready or 60s timeout — show countdown
            $timeoutSecs = 60
            $elapsed     = 0
            while (-not (_Test-FltDockerRunning) -and $elapsed -lt $timeoutSecs) {
                $remaining = $timeoutSecs - $elapsed
                Write-Host -NoNewline "`r  Waiting for Docker Desktop... ($remaining s remaining)  "
                Start-Sleep -Seconds 2
                $elapsed += 2
            }
            Write-Host ''
            $dockerOk = _Test-FltDockerRunning
            if ($dockerOk) {
                _Write-SysRow 'Docker Desktop' 'Running' 'started'
                $allOk = $true
            } else {
                _Write-SysRow 'Docker Desktop' 'Failed' 'timed out — press Escape to skip next time'
                $allOk = $false
            }
        }
    }

    # ── 2. tcflt-ansible container ───────────────────────────────────────────
    $containerName = Get-FltCfgValue 'ansible' 'dockerContainer' 'tcflt-ansible'
    if (-not $dockerOk) {
        _Write-SysRow "Container: $containerName" 'Skipped' 'Docker not running'
        $ansibleOk = $false
    } else {
        Write-Host -NoNewline ("  {0,-32} " -f "Container: $containerName")
        Write-Host "[Checking]" -ForegroundColor Yellow
        $ansibleOk = _Test-FltAnsibleContainer
        Write-Host "`e[1A`e[0K" -NoNewline

        if ($ansibleOk) {
            _Write-SysRow "Container: $containerName" 'Running'
        } else {
            _Write-SysRow "Container: $containerName" 'Stopped' 'attempting docker start...'
            $ansibleOk = _Start-FltAnsibleContainer
            if ($ansibleOk) {
                _Write-SysRow "Container: $containerName" 'Running' 'started automatically'
            } else {
                _Write-SysRow "Container: $containerName" 'Failed' "run: docker start $containerName"
                $allOk = $false
            }
        }
    }

    Write-Host ''

    # ── 3. Linux targets ─────────────────────────────────────────────────────
    $linuxTargets = @($Script:FleetTargets | Where-Object {
        $_.OS -eq 'linux' -and $_.TargetType -ne 'container' -and
        $_.Address -and $_.Address -ne '__local__'
    })

    if ($linuxTargets.Count -eq 0) {
        Write-Host '  No Linux targets configured.' -ForegroundColor DarkGray
    } else {
        Write-Host '  Linux targets:' -ForegroundColor DarkGray
        foreach ($t in $linuxTargets) {
            $ok = _Test-FltSshReachable -Address $t.Address -Port $t.Port
            if ($ok) {
                _Write-SysRow "  $($t.Name)" 'OK' $t.Address
            } else {
                # If a VMX path is set, try to start the VM
                if ($t.VmxPath -and $t.TargetType -eq 'vm') {
                    _Write-SysRow "  $($t.Name)" 'Stopped' "starting VM..."
                    $vmStarted = _Start-FltVm -VmxPath $t.VmxPath
                    if ($vmStarted) {
                        Write-Host "  Waiting for $($t.Name) to boot..." -ForegroundColor DarkGray
                        $waited = 0
                        while (-not (_Test-FltSshReachable -Address $t.Address -Port $t.Port) -and $waited -lt 60) {
                            $remaining = 60 - $waited
                            Write-Host -NoNewline "`r  Waiting for $($t.Name)... ($remaining s remaining)  "
                            Start-Sleep -Seconds 3
                            $waited += 3
                        }
                        Write-Host ''
                        $ok = _Test-FltSshReachable -Address $t.Address -Port $t.Port
                        if ($ok) {
                            _Write-SysRow "  $($t.Name)" 'OK' 'VM started'
                        } else {
                            _Write-SysRow "  $($t.Name)" 'Failed' 'VM started but SSH not reachable'
                            $allOk = $false
                        }
                    } else {
                        _Write-SysRow "  $($t.Name)" 'Failed' 'vmrun start failed'
                        $allOk = $false
                    }
                } else {
                    _Write-SysRow "  $($t.Name)" 'Failed' "$($t.Address) not reachable (no VMX path set)"
                    $allOk = $false
                }
            }
        }
    }

    Write-Host ''

    # ── 4. Windows targets ───────────────────────────────────────────────────
    $winTargets = @($Script:FleetTargets | Where-Object {
        $_.OS -ne 'linux' -and $_.TargetType -ne 'container' -and
        $_.Address -and $_.Address -ne '__local__'
    })

    if ($winTargets.Count -eq 0) {
        Write-Host '  No Windows targets configured.' -ForegroundColor DarkGray
    } else {
        Write-Host '  Windows targets:' -ForegroundColor DarkGray
        foreach ($t in $winTargets) {
            $ok = _Test-FltSshReachable -Address $t.Address -Port $t.Port
            if ($ok) {
                _Write-SysRow "  $($t.Name)" 'OK' $t.Address
            } else {
                _Write-SysRow "  $($t.Name)" 'Failed' "$($t.Address) not reachable on port $($t.Port)"
                $allOk = $false
            }
        }
    }

    Write-Host ''
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
    if ($allOk) {
        Write-Host '  All systems ready.' -ForegroundColor Green
    } else {
        Write-Host '  One or more checks failed. Review the items above.' -ForegroundColor Yellow
    }
    Write-Host ''
    Read-Host '  Press Enter to return'
}

# ---------------------------------------------------------------------------
# Health check (read-only)
# ---------------------------------------------------------------------------

function Invoke-FltHealthCheck {
    Clear-Host
    Write-Host '  System  >  Health check' -ForegroundColor Cyan
    Write-Host ''

    # Docker Desktop
    $dockerOk     = _Test-FltDockerRunning
    $dockerStatus = if ($dockerOk) { 'Running' } else { 'Stopped' }
    _Write-SysRow 'Docker Desktop' $dockerStatus

    # tcflt-ansible container
    $containerName = Get-FltCfgValue 'ansible' 'dockerContainer' 'tcflt-ansible'
    if ($dockerOk) {
        $ansibleOk     = _Test-FltAnsibleContainer
        $ansibleStatus = if ($ansibleOk) { 'Running' } else { 'Stopped' }
        _Write-SysRow "Container: $containerName" $ansibleStatus
    } else {
        _Write-SysRow "Container: $containerName" 'Skipped' 'Docker not running'
    }

    Write-Host ''

    # Linux targets
    $linuxTargets = @($Script:FleetTargets | Where-Object {
        $_.OS -eq 'linux' -and $_.TargetType -ne 'container' -and
        $_.Address -and $_.Address -ne '__local__'
    })

    if ($linuxTargets.Count -gt 0) {
        Write-Host '  Linux targets:' -ForegroundColor DarkGray
        foreach ($t in $linuxTargets) {
            $ok         = _Test-FltSshReachable -Address $t.Address -Port $t.Port
            $sshStatus  = if ($ok) { 'OK' } else { 'Failed' }
            _Write-SysRow "  $($t.Name)" $sshStatus $t.Address
        }
        Write-Host ''
    }

    # Windows targets
    $winTargets = @($Script:FleetTargets | Where-Object {
        $_.OS -ne 'linux' -and $_.TargetType -ne 'container' -and
        $_.Address -and $_.Address -ne '__local__'
    })

    if ($winTargets.Count -gt 0) {
        Write-Host '  Windows targets:' -ForegroundColor DarkGray
        foreach ($t in $winTargets) {
            $ok        = _Test-FltSshReachable -Address $t.Address -Port $t.Port
            $sshStatus = if ($ok) { 'OK' } else { 'Failed' }
            _Write-SysRow "  $($t.Name)" $sshStatus $t.Address
        }
        Write-Host ''
    }

    Read-Host '  Press Enter to return'
}

# ---------------------------------------------------------------------------
# System menu
# ---------------------------------------------------------------------------

function Invoke-SystemMenu {
    while ($true) {
        Clear-Host
        Write-Host '  System' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  1. Startup check   (Docker, containers, all targets)'
        Write-Host '  2. Health check    (read-only status of all systems)'
        Write-Host ''
        Write-Host '  0. Back' -ForegroundColor DarkGray
        Write-Host ''

        $choice = (Read-Host '  Choice').Trim()
        switch ($choice) {
            '1' { Invoke-FltStartupCheck }
            '2' { Invoke-FltHealthCheck  }
            '0' { return }
            ''  { return }
            default {
                Write-Host '  Enter 1 or 2.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 600
            }
        }
    }
}