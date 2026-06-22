# =============================================================================
#  TcFltPkgMgr — Ansible Repository
#  Availability checks for Ansible on the operator machine.
#
#  Ansible may be available via three modes:
#    'native' — ansible-playbook is on PATH directly (Linux/macOS)
#    'wsl'    — ansible-playbook is available inside a WSL distribution
#    'docker' — ansible-playbook runs inside a Docker container on the operator
#               machine (the recommended approach on Windows — no WSL needed).
#               Container name is configured via ansible.dockerContainer setting.
#    ''       — Ansible not found
#
#  The 'docker' mode is checked last so native/WSL take priority if present.
#  For the docker mode, TcFltPkgMgr ships a Dockerfile to build the container.
# =============================================================================

# Return the Ansible Docker container name from settings.
function _Get-FltAnsibleDockerContainer {
    return Get-FltCfgValue 'ansible' 'dockerContainer' 'tcflt-ansible'
}

# Return the WSL prefix command for running Ansible.
function _Get-FltWslPrefix {
    $useWsl  = Get-FltCfgValue 'ansible' 'useWsl' $false
    if (-not $useWsl) { return '' }
    $distro = Get-FltCfgValue 'ansible' 'wslDistro' ''
    if ($distro) { return "wsl -d $distro" }
    return 'wsl'
}

# Return the full ansible-playbook invocation command for the current mode.
# Callers should use this rather than building the command themselves.
function _Get-FltAnsibleCmd {
    $exe    = Get-FltCfgValue 'ansible' 'executablePath' 'ansible-playbook'
    $mode   = Get-FltAnsibleMode
    switch ($mode) {
        'native' { return $exe }
        'wsl'    {
            $prefix = _Get-FltWslPrefix
            return "$prefix $exe"
        }
        'docker' {
            $container = _Get-FltAnsibleDockerContainer
            return "docker exec $container ansible-playbook"
        }
        default  { return $exe }
    }
}

# Return the ansible-galaxy invocation command for the current mode.
function _Get-FltAnsibleGalaxyCmd {
    $mode = Get-FltAnsibleMode
    switch ($mode) {
        'native' { return 'ansible-galaxy' }
        'wsl'    {
            $prefix = _Get-FltWslPrefix
            return "$prefix ansible-galaxy"
        }
        'docker' {
            $container = _Get-FltAnsibleDockerContainer
            return "docker exec $container ansible-galaxy"
        }
        default  { return 'ansible-galaxy' }
    }
}

# Return 'native', 'wsl', 'docker', or '' indicating how Ansible is reachable.
function Get-FltAnsibleMode {
    $exe = Get-FltCfgValue 'ansible' 'executablePath' 'ansible-playbook'

    # Check native
    if (Get-Command $exe -ErrorAction SilentlyContinue) { return 'native' }

    # Check WSL
    if (Get-Command 'wsl' -ErrorAction SilentlyContinue) {
        $distro = Get-FltCfgValue 'ansible' 'wslDistro' ''
        $wslCmd = if ($distro) { "wsl -d $distro ansible-playbook --version" } `
                  else          { "wsl ansible-playbook --version" }
        try {
            $out = & cmd /c $wslCmd 2>&1
            if ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'ansible') { return 'wsl' }
        } catch {}
    }

    # Check Docker container
    if (Get-Command 'docker' -ErrorAction SilentlyContinue) {
        $container = _Get-FltAnsibleDockerContainer
        try {
            $out = & docker exec $container ansible-playbook --version 2>&1
            if ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'ansible') { return 'docker' }
        } catch {}
    }

    return ''
}

# Returns $true if ansible-playbook is reachable via any mode.
function Test-FltAnsibleAvailable {
    return (Get-FltAnsibleMode) -ne ''
}

# Returns the ansible-playbook version string, or '' if not available.
function Get-FltAnsibleVersion {
    $mode = Get-FltAnsibleMode
    if ($mode -eq '') { return '' }

    try {
        $cmd = _Get-FltAnsibleCmd
        $raw = & cmd /c "$cmd --version" 2>&1
        $first = ($raw | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        return $first.Trim()
    } catch {
        return ''
    }
}

# Returns $true if the specified Ansible collection is installed.
function Test-FltAnsibleCollection {
    param([string]$CollectionName = 'community.docker')

    $mode = Get-FltAnsibleMode
    if ($mode -eq '') { return $false }

    try {
        $galaxyCmd = _Get-FltAnsibleGalaxyCmd
        $raw = & cmd /c "$galaxyCmd collection list $CollectionName" 2>&1
        return ($raw -join ' ') -match [regex]::Escape($CollectionName)
    } catch {
        return $false
    }
}

# Returns a summary of all Ansible availability information.
# [pscustomobject]@{ Available; Mode; Version; HasCommunityDocker }
function Get-FltAnsibleStatus {
    $mode    = Get-FltAnsibleMode
    $version = if ($mode -ne '') { Get-FltAnsibleVersion } else { '' }
    $docker  = if ($mode -ne '') { Test-FltAnsibleCollection 'community.docker' } else { $false }

    return [pscustomobject]@{
        Available          = $mode -ne ''
        Mode               = $mode       # 'native' | 'wsl' | 'docker' | ''
        Version            = $version
        HasCommunityDocker = $docker
    }
}

# Returns $true if the Ansible Docker container exists (running or stopped).
# Used by Setup to check whether 'docker build' has been run.
function Test-FltAnsibleDockerContainer {
    $container = _Get-FltAnsibleDockerContainer
    if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) { return $false }
    try {
        $out = & docker inspect $container 2>&1
        return $LASTEXITCODE -eq 0
    } catch { return $false }
}

# Returns $true if the Ansible Docker container is currently running.
function Test-FltAnsibleDockerContainerRunning {
    $container = _Get-FltAnsibleDockerContainer
    if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) { return $false }
    try {
        $out = & docker inspect --format '{{.State.Running}}' $container 2>&1
        return ($out -join '').Trim() -eq 'true'
    } catch { return $false }
}