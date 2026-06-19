# =============================================================================
#  TcFltPkgMgr — Ansible Repository
#  Availability checks for Ansible on the operator machine.
#
#  Ansible may be available:
#    'native' — ansible-playbook is on PATH directly (Linux/macOS or Windows
#               with Ansible installed natively via pip)
#    'wsl'    — ansible-playbook is available inside a WSL distribution
#               (common on Windows; use 'wsl ansible-playbook' to invoke)
#    ''       — Ansible not found
#
#  The 'wsl' mode uses 'wsl -d <distro>' when wslDistro is set in settings,
#  or 'wsl' (default distro) when it is not.
# =============================================================================

# Return the WSL prefix command for running Ansible.
# Returns '' if WSL mode is not configured/available.
function _Get-FltWslPrefix {
    $useWsl  = Get-FltCfgValue 'ansible' 'useWsl' $false
    if (-not $useWsl) { return '' }
    $distro = Get-FltCfgValue 'ansible' 'wslDistro' ''
    if ($distro) { return "wsl -d $distro" }
    return 'wsl'
}

# Return the ansible-playbook executable path/command.
# Respects the ansible.executablePath setting and WSL prefix.
function _Get-FltAnsibleCmd {
    $exe    = Get-FltCfgValue 'ansible' 'executablePath' 'ansible-playbook'
    $prefix = _Get-FltWslPrefix
    if ($prefix) { return "$prefix $exe" }
    return $exe
}

# Return the ansible-galaxy executable (same prefix, different binary).
function _Get-FltAnsibleGalaxyCmd {
    $prefix = _Get-FltWslPrefix
    if ($prefix) { return "$prefix ansible-galaxy" }
    return 'ansible-galaxy'
}

# Return 'native', 'wsl', or '' indicating how Ansible is reachable.
function Get-FltAnsibleMode {
    # Check native first
    $exe = Get-FltCfgValue 'ansible' 'executablePath' 'ansible-playbook'
    if (Get-Command $exe -ErrorAction SilentlyContinue) {
        return 'native'
    }
    # Check WSL
    if (Get-Command 'wsl' -ErrorAction SilentlyContinue) {
        $useWsl = Get-FltCfgValue 'ansible' 'useWsl' $false
        $distro = Get-FltCfgValue 'ansible' 'wslDistro' ''
        $wslCmd = if ($distro) { "wsl -d $distro ansible-playbook --version" } `
                  else          { "wsl ansible-playbook --version" }
        try {
            $out = & cmd /c $wslCmd 2>&1
            if ($LASTEXITCODE -eq 0 -and ($out -join '') -match 'ansible') {
                return 'wsl'
            }
        } catch {}
    }
    return ''
}

# Returns $true if ansible-playbook is reachable (native or WSL).
function Test-FltAnsibleAvailable {
    return (Get-FltAnsibleMode) -ne ''
}

# Returns the ansible-playbook version string, or '' if not available.
# e.g. 'ansible [core 2.17.3]'
function Get-FltAnsibleVersion {
    $mode = Get-FltAnsibleMode
    if ($mode -eq '') { return '' }

    try {
        $cmd = _Get-FltAnsibleCmd
        $raw = if ($mode -eq 'wsl') {
            & cmd /c "$cmd --version" 2>&1
        } else {
            & $cmd --version 2>&1
        }
        $first = ($raw | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        return $first.Trim()
    } catch {
        return ''
    }
}

# Returns $true if the community.docker Ansible collection is installed.
# Required for Docker container management via Ansible.
function Test-FltAnsibleCollection {
    param([string]$CollectionName = 'community.docker')

    $mode = Get-FltAnsibleMode
    if ($mode -eq '') { return $false }

    try {
        $galaxyCmd = _Get-FltAnsibleGalaxyCmd
        $raw = if ($mode -eq 'wsl') {
            & cmd /c "$galaxyCmd collection list $CollectionName" 2>&1
        } else {
            & $galaxyCmd collection list $CollectionName 2>&1
        }
        # ansible-galaxy collection list exits 0 even if not found;
        # check output for the collection name
        return ($raw -join ' ') -match [regex]::Escape($CollectionName)
    } catch {
        return $false
    }
}

# Returns a summary object with all Ansible availability information.
# Used by the prerequisites check and diagnostics.
# Returns [pscustomobject]@{ Available; Mode; Version; HasCommunityDocker }
function Get-FltAnsibleStatus {
    $mode    = Get-FltAnsibleMode
    $version = if ($mode -ne '') { Get-FltAnsibleVersion } else { '' }
    $docker  = if ($mode -ne '') { Test-FltAnsibleCollection 'community.docker' } else { $false }

    return [pscustomobject]@{
        Available         = $mode -ne ''
        Mode              = $mode          # 'native' | 'wsl' | ''
        Version           = $version
        HasCommunityDocker = $docker
    }
}