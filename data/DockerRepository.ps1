# =============================================================================
#  TcFltPkgMgr — Docker Repository
#  Docker operator-machine management.
#
#  Covers two distinct concerns:
#    1. Docker Desktop on the operator machine — starting, stopping, status
#    2. Docker on remote targets — managed via SSH (Phase 7)
#
#  This file handles concern 1 only. Remote Docker management is in
#  execution/DockerExecutor.ps1 (Phase 7).
# =============================================================================

# Known Docker Desktop executable paths (checked in order).
$Script:FltDockerDesktopPaths = @(
    'C:\Program Files\Docker\Docker\Docker Desktop.exe',
    'C:\Program Files (x86)\Docker\Docker\Docker Desktop.exe'
)

# Return the Docker Desktop executable path, or '' if not found.
function Get-FltDockerDesktopPath {
    foreach ($path in $Script:FltDockerDesktopPaths) {
        if (Test-Path $path -PathType Leaf) { return $path }
    }
    # Also check via registry (user-installed Docker Desktop)
    try {
        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\Docker Desktop.exe'
        $regVal  = Get-ItemPropertyValue $regPath '(default)' -ErrorAction Stop
        if ($regVal -and (Test-Path $regVal -PathType Leaf)) { return $regVal }
    } catch {}
    return ''
}

# Return $true if the Docker daemon is reachable (daemon running and responsive).
function Test-FltDockerAvailable {
    if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) { return $false }
    try {
        $null = & docker info 2>&1
        return $LASTEXITCODE -eq 0
    } catch { return $false }
}

# Return $true if Docker Desktop process is running (even if daemon not yet ready).
function Test-FltDockerDesktopRunning {
    return $null -ne (Get-Process 'Docker Desktop' -ErrorAction SilentlyContinue)
}

# Return 'running' | 'starting' | 'stopped' | 'not-installed'
function Get-FltDockerStatus {
    if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) { return 'not-installed' }
    if (Test-FltDockerAvailable)         { return 'running' }
    if (Test-FltDockerDesktopRunning)    { return 'starting' }
    return 'stopped'
}

# Start Docker Desktop and optionally wait for the daemon to become ready.
# Returns [pscustomobject]@{ Ok; Message }
function Start-FltDockerDesktop {
    param(
        [switch] $Wait,
        [int]    $TimeoutSecs = 60
    )

    $fail    = { param($msg) [pscustomobject]@{ Ok = $false; Message = $msg } }
    $succeed = { param($msg) [pscustomobject]@{ Ok = $true;  Message = $msg } }

    # Already running?
    if (Test-FltDockerAvailable) {
        return (& $succeed 'Docker daemon already running')
    }

    # Find Docker Desktop executable
    $exe = Get-FltDockerDesktopPath
    if (-not $exe) {
        return (& $fail 'Docker Desktop executable not found — is Docker Desktop installed?')
    }

    # Launch Docker Desktop
    try {
        Start-Process -FilePath $exe -WindowStyle Minimized
    } catch {
        return (& $fail "Failed to launch Docker Desktop: $($_.Exception.Message)")
    }

    if (-not $Wait) {
        return (& $succeed 'Docker Desktop launched — daemon starting in background')
    }

    # Wait for daemon to become ready
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSecs)
    $dots     = 0
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-FltDockerAvailable) {
            return (& $succeed 'Docker Desktop started and daemon is ready')
        }
        $dots++
        if ($dots % 5 -eq 0) {
            Write-Host "  Waiting for Docker daemon... ($([int]([DateTime]::UtcNow - ($deadline.AddSeconds(-$TimeoutSecs))).TotalSeconds)s)" `
                -ForegroundColor DarkGray
        }
    }

    return (& $fail "Docker daemon did not become ready within ${TimeoutSecs}s — Docker Desktop may still be starting")
}

# Ensure Docker is running — launch if stopped, wait until ready.
# Prompts operator before launching if $Confirm is set.
# Returns [pscustomobject]@{ Ok; Message }
function Ensure-FltDockerRunning {
    param(
        [switch] $Confirm,
        [int]    $TimeoutSecs = 90
    )

    $status = Get-FltDockerStatus

    switch ($status) {
        'running'       { return [pscustomobject]@{ Ok = $true; Message = 'Docker daemon is running' } }
        'not-installed' { return [pscustomobject]@{ Ok = $false; Message = 'Docker is not installed — install Docker Desktop from https://www.docker.com/products/docker-desktop/' } }
        'starting' {
            Write-Host '  Docker Desktop is starting — waiting for daemon...' -ForegroundColor DarkGray
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSecs)
            while ([DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Seconds 3
                if (Test-FltDockerAvailable) {
                    return [pscustomobject]@{ Ok = $true; Message = 'Docker daemon ready' }
                }
            }
            return [pscustomobject]@{ Ok = $false; Message = "Docker daemon did not become ready within ${TimeoutSecs}s" }
        }
        'stopped' {
            if ($Confirm) {
                Write-Host '  Docker Desktop is not running.' -ForegroundColor Yellow
                Write-Host '  1. Start Docker Desktop   0. Cancel' -ForegroundColor Cyan
                $choice = (Read-Host '  Choice').Trim()
                if ($choice -ne '1') {
                    return [pscustomobject]@{ Ok = $false; Message = 'Docker start cancelled by operator' }
                }
            }
            return Start-FltDockerDesktop -Wait -TimeoutSecs $TimeoutSecs
        }
    }
}