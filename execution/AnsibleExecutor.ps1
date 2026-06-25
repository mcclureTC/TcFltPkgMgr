# =============================================================================
#  TcFltPkgMgr — Ansible Executor
#  Inventory builder, playbook builder, and batch executor for Linux targets.
#
#  Phase 5.2 — New-FltAnsibleInventory / Remove-FltAnsibleInventory
#  Phase 5.3 — Playbook builders (_Get-PackagePlaybook, _Get-ServicePlaybook, etc.)
#  Phase 5.4 — Invoke-FltAnsibleBatch (batch executor)
#  Phase 5.6 — Vault helpers (_Get-VaultPasswordFile, Invoke-FltVaultSetup)
# =============================================================================

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Private helper: resolve the default inventory path at call time.
# Cannot be set at module scope — $Script:FltConfigDir is assigned by
# TcFltPkgMgr.ps1 after all modules are dot-sourced.
# ---------------------------------------------------------------------------

function _Get-FltAnsibleInventoryPath {
    $root = Split-Path $Script:FltConfigDir -Parent
    return Join-Path $root 'ansible' 'inventory' 'hosts.ini'
}

# ---------------------------------------------------------------------------
# Private helper: build the ansible_* SSH variable string for one target
# ---------------------------------------------------------------------------

function _Get-AnsibleSshVars {
    param([FleetTarget] $Target)

    $port = if ($Target.Port -gt 0) { $Target.Port } else { 22 }

    # User: target's own User field → ssh.defaultUser setting → 'ansible'
    $user = $Target.User
    if ([string]::IsNullOrEmpty($user)) {
        $user = Get-FltCfgValue 'ssh' 'defaultUser' ''
    }
    if ([string]::IsNullOrEmpty($user)) { $user = 'ansible' }

    $vars = "ansible_host=$($Target.Address) ansible_user=$user ansible_port=$port"

    # Auth: SSH key file only — passwords are never written to inventory.
    # Priority:
    #   1. Explicit ssh.privateKeyPath setting (host-side path)
    #   2. Docker mode — always use the container's baked-in key
    #   3. Otherwise rely on Ansible's default key discovery (~/.ssh/id_ed25519)
    $keyPath = Get-FltCfgValue 'ssh' 'privateKeyPath' ''
    if (-not [string]::IsNullOrEmpty($keyPath) -and (Test-Path $keyPath)) {
        $posixKey = $keyPath -replace '\\', '/'
        $vars += " ansible_ssh_private_key_file=$posixKey"
    } else {
        $ansibleMode = Get-FltAnsibleMode
        if ($ansibleMode -eq 'docker') {
            # Key is baked into the container image at build time
            $vars += ' ansible_ssh_private_key_file=/root/.ssh/id_ed25519'
        }
    }

    $vars += ' ansible_become=true'

    $vars
}

# ---------------------------------------------------------------------------
# Phase 5.2 — Inventory builder
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Generates an Ansible INI-format inventory file from FleetTarget objects.

.DESCRIPTION
    Filters to Linux OS targets only.  Groups by TargetType:
      [physical]       — TargetType = 'physical'
      [vm]             — TargetType = 'vm'
      [containers]     — TargetType = 'container'
      [linux:children] — meta-group written when more than one group exists

    Container targets include community.docker.docker_api connection vars.
    The Docker host address is resolved from the target list; the daemon port
    comes from docker.daemonPort in settings (default 2375).

    File is written to ansible/inventory/hosts.ini by default (gitignored).
    The parent directory is created automatically when missing.

.PARAMETER Targets
    Array of FleetTarget objects.  Non-Linux targets are silently skipped.

.PARAMETER Path
    Override the output path.  Used by tests; production callers use default.

.OUTPUTS
    [pscustomobject] @{ Ok; Path; TargetCount; Message }
#>
function New-FltAnsibleInventory {
    param(
        [Parameter(Mandatory)] [FleetTarget[]] $Targets,
        [string] $Path = ''
    )

    if ([string]::IsNullOrEmpty($Path)) { $Path = _Get-FltAnsibleInventoryPath }

    # Filter to Linux only
    $linuxTargets = @($Targets | Where-Object { $_.OS -eq 'linux' })

    if ($linuxTargets.Count -eq 0) {
        return [pscustomobject]@{
            Ok          = $false
            Path        = $Path
            TargetCount = 0
            Message     = 'No Linux targets in fleet — inventory not written.'
        }
    }

    # Ensure parent directory exists
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) {
        try {
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
        } catch {
            return [pscustomobject]@{
                Ok          = $false
                Path        = $Path
                TargetCount = 0
                Message     = "Cannot create inventory directory '$dir': $_"
            }
        }
    }

    # Group by TargetType
    $physical   = @($linuxTargets | Where-Object { $_.TargetType -eq 'physical' })
    $vms        = @($linuxTargets | Where-Object { $_.TargetType -eq 'vm' })
    $containers = @($linuxTargets | Where-Object { $_.TargetType -eq 'container' })

    # Build INI lines
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Ansible inventory — generated by TcFltPkgMgr")
    $lines.Add("# $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Do not edit — regenerated on each Ansible run.")
    $lines.Add('')

    # Sanitise name for INI alias — spaces and special chars break Ansible INI parsing.
    # The real name is preserved via ansible_host and a comment.
    function _FltAnsibleAlias { param([string]$Name) $Name -replace '[^a-zA-Z0-9_\-]','_' }

    if ($physical.Count -gt 0) {
        $lines.Add('[physical]')
        foreach ($t in $physical) {
            $alias = _FltAnsibleAlias $t.Name
            $lines.Add("$alias $(_Get-AnsibleSshVars $t)  # $($t.Name)")
        }
        $lines.Add('')
    }

    if ($vms.Count -gt 0) {
        $lines.Add('[vm]')
        foreach ($t in $vms) {
            $alias = _FltAnsibleAlias $t.Name
            $lines.Add("$alias $(_Get-AnsibleSshVars $t)  # $($t.Name)")
        }
        $lines.Add('')
    }

    if ($containers.Count -gt 0) {
        $lines.Add('[containers]')
        $daemonPort = Get-FltCfgValue 'docker' 'daemonPort' 2375
        if (-not $daemonPort -or $daemonPort -eq 0) { $daemonPort = 2375 }

        foreach ($t in $containers) {
            # Resolve Docker host address from the full target list
            $hostTarget = $Targets | Where-Object { $_.Name -eq $t.DockerHost } |
                          Select-Object -First 1
            $dockerAddr = if ($null -ne $hostTarget -and $hostTarget.Address) {
                $hostTarget.Address
            } else {
                $t.DockerHost   # fall back to the name itself (DNS/hosts resolution)
            }
            $sshVars = _Get-AnsibleSshVars $t
            # All vars on one line — Ansible INI does not use line continuation
            $dockerVars = "ansible_connection=community.docker.docker_api" +
                          " ansible_docker_host=tcp://${dockerAddr}:${daemonPort}"
            $alias = _FltAnsibleAlias $t.Name
            $lines.Add("$alias $sshVars $dockerVars  # $($t.Name)")
        }
        $lines.Add('')
    }

    # [linux:children] meta-group — always written so playbooks can use hosts: linux
    $groups = @()
    if ($physical.Count   -gt 0) { $groups += 'physical' }
    if ($vms.Count        -gt 0) { $groups += 'vm' }
    if ($containers.Count -gt 0) { $groups += 'containers' }

    if ($groups.Count -gt 0) {
        $lines.Add('[linux:children]')
        foreach ($g in $groups) { $lines.Add($g) }
        $lines.Add('')
    }

    # Write file (UTF-8, LF line endings — required by Ansible on POSIX hosts)
    try {
        $content = $lines -join "`n"
        [System.IO.File]::WriteAllText($Path, $content, [System.Text.Encoding]::UTF8)
    } catch {
        return [pscustomobject]@{
            Ok          = $false
            Path        = $Path
            TargetCount = $linuxTargets.Count
            Message     = "Failed to write inventory to '$Path': $_"
        }
    }

    $noun = if ($linuxTargets.Count -ne 1) { 'targets' } else { 'target' }
    return [pscustomobject]@{
        Ok          = $true
        Path        = $Path
        TargetCount = $linuxTargets.Count
        Message     = "Inventory written: $($linuxTargets.Count) Linux $noun."
    }
}

# ---------------------------------------------------------------------------
# Phase 5.2 — Inventory cleanup
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Removes the generated hosts.ini inventory file.

.DESCRIPTION
    Called after each Ansible run to keep the gitignored ansible/ tree clean.
    Silent no-op when the file does not exist.
#>
function Remove-FltAnsibleInventory {
    param([string] $Path = '')
    if ([string]::IsNullOrEmpty($Path)) { $Path = _Get-FltAnsibleInventoryPath }

    if (Test-Path $Path) {
        try {
            Remove-Item $Path -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Remove-FltAnsibleInventory: could not remove '$Path': $_"
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 5.3 — Playbook path helper (lazy, mirrors inventory path helper)
# ---------------------------------------------------------------------------

function _Get-FltAnsiblePlaybookDir {
    $root = Split-Path $Script:FltConfigDir -Parent
    return Join-Path $root 'ansible' 'playbooks'
}

# ---------------------------------------------------------------------------
# Phase 5.3 — Playbook builders
#
# Each function returns a [pscustomobject]@{ Ok; Path; Message } after writing
# a YAML playbook file under ansible/playbooks/ (gitignored).
# The caller (Invoke-FltAnsibleBatch, Phase 5.4) passes the path to
# ansible-playbook and removes it afterward.
#
# Conventions:
#   - hosts: linux  (targets the [linux:children] meta-group or explicit group)
#   - become: true  (sudo escalation — sudo password via Vault if needed)
#   - gather_facts: false by default to keep runs fast; enabled only when needed
#   - All modules use their fully-qualified collection name (FQCN)
# ---------------------------------------------------------------------------

function _Write-AnsiblePlaybook {
    <#
    .SYNOPSIS
        Writes a YAML string to a temp playbook file and returns the path.
    .PARAMETER Yaml
        The playbook YAML content (string).
    .PARAMETER Name
        Short slug used in the filename, e.g. 'package-install'.
    .OUTPUTS
        [pscustomobject] @{ Ok; Path; Message }
    #>
    param(
        [Parameter(Mandatory)] [string] $Yaml,
        [Parameter(Mandatory)] [string] $Name
    )

    $dir = _Get-FltAnsiblePlaybookDir
    if (-not (Test-Path $dir)) {
        try {
            $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Ok = $false; Path = ''; Message = "Cannot create playbook dir '$dir': $_" }
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $path  = Join-Path $dir "$Name-$stamp.yml"

    try {
        [System.IO.File]::WriteAllText($path, $Yaml, [System.Text.Encoding]::UTF8)
    } catch {
        return [pscustomobject]@{ Ok = $false; Path = $path; Message = "Cannot write playbook '$path': $_" }
    }

    return [pscustomobject]@{ Ok = $true; Path = $path; Message = "Playbook written: $path" }
}

function _Get-PackagePlaybook {
    <#
    .SYNOPSIS
        Builds a playbook that installs, upgrades, or removes a package.
    .PARAMETER Action
        'install' | 'upgrade' | 'remove'
    .PARAMETER PackageName
        The distro-agnostic package name (e.g. 'curl', 'docker-ce').
    .PARAMETER Hosts
        Ansible host pattern (default 'linux').
    .OUTPUTS
        [pscustomobject] @{ Ok; Path; Message }
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('install','upgrade','remove')]
        [string] $Action,

        [Parameter(Mandatory)] [string] $PackageName,
        [string] $Hosts = 'linux'
    )

    $state = switch ($Action) {
        'install' { 'present' }
        'upgrade' { 'latest'  }
        'remove'  { 'absent'  }
    }

    $yaml = @"
---
# TcFltPkgMgr — generated playbook: package $Action
# Package : $PackageName
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- name: Package $Action — $PackageName
  hosts: $Hosts
  become: true
  gather_facts: false
  tasks:
    - name: $Action $PackageName
      ansible.builtin.package:
        name: $PackageName
        state: $state
"@

    _Write-AnsiblePlaybook -Yaml $yaml -Name "package-$Action"
}

function _Get-ServicePlaybook {
    <#
    .SYNOPSIS
        Builds a playbook that starts, stops, restarts, enables, or disables a systemd service.
    .PARAMETER Action
        'start' | 'stop' | 'restart' | 'enable' | 'disable'
    .PARAMETER ServiceName
        The systemd unit name (e.g. 'docker', 'nginx').
    .PARAMETER Hosts
        Ansible host pattern (default 'linux').
    .OUTPUTS
        [pscustomobject] @{ Ok; Path; Message }
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('start','stop','restart','enable','disable')]
        [string] $Action,

        [Parameter(Mandatory)] [string] $ServiceName,
        [string] $Hosts = 'linux'
    )

    # Map action to state/enabled combinations
    $state   = $null
    $enabled = $null
    switch ($Action) {
        'start'   { $state = 'started'  }
        'stop'    { $state = 'stopped'  }
        'restart' { $state = 'restarted' }
        'enable'  { $enabled = 'true'   }
        'disable' { $enabled = 'false'  }
    }

    $stateYaml   = if ($null -ne $state)   { "`n        state: $state"     } else { '' }
    $enabledYaml = if ($null -ne $enabled) { "`n        enabled: $enabled" } else { '' }

    $yaml = @"
---
# TcFltPkgMgr — generated playbook: service $Action
# Service  : $ServiceName
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- name: Service $Action — $ServiceName
  hosts: $Hosts
  become: true
  gather_facts: false
  tasks:
    - name: $Action $ServiceName
      ansible.builtin.systemd:
        name: $ServiceName$stateYaml$enabledYaml
        daemon_reload: false
"@

    _Write-AnsiblePlaybook -Yaml $yaml -Name "service-$Action"
}

function _Get-UserPlaybook {
    <#
    .SYNOPSIS
        Builds a playbook that creates or removes a system user.
    .PARAMETER Action
        'create' | 'remove'
    .PARAMETER UserName
        The Linux username (e.g. 'deploy').
    .PARAMETER Groups
        Optional array of supplementary groups (e.g. @('docker','sudo')).
    .PARAMETER Shell
        Login shell (default '/bin/bash').
    .PARAMETER Hosts
        Ansible host pattern (default 'linux').
    .OUTPUTS
        [pscustomobject] @{ Ok; Path; Message }
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('create','remove')]
        [string] $Action,

        [Parameter(Mandatory)] [string] $UserName,
        [string[]] $Groups = @(),
        [string]   $Shell  = '/bin/bash',
        [string]   $Hosts  = 'linux'
    )

    $state = if ($Action -eq 'create') { 'present' } else { 'absent' }

    $groupsYaml = if ($Groups.Count -gt 0 -and $Action -eq 'create') {
        "`n        groups: " + ($Groups -join ',')
    } else { '' }

    $shellYaml  = if ($Action -eq 'create') { "`n        shell: $Shell" } else { '' }
    $removeYaml = if ($Action -eq 'remove') { "`n        remove: true`n        force: true" } else { '' }

    $yaml = @"
---
# TcFltPkgMgr — generated playbook: user $Action
# User     : $UserName
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- name: User $Action — $UserName
  hosts: $Hosts
  become: true
  gather_facts: false
  tasks:
    - name: $Action user $UserName
      ansible.builtin.user:
        name: $UserName
        state: $state$groupsYaml$shellYaml$removeYaml
"@

    _Write-AnsiblePlaybook -Yaml $yaml -Name "user-$Action"
}

function _Get-FilePlaybook {
    <#
    .SYNOPSIS
        Builds a playbook that copies a file from the Ansible controller to targets.
    .PARAMETER Src
        Source path on the Ansible controller (absolute, or relative to the playbook).
    .PARAMETER Dest
        Destination path on the target hosts.
    .PARAMETER Owner
        File owner on the target (default 'root').
    .PARAMETER Group
        File group on the target (default 'root').
    .PARAMETER Mode
        File mode in octal string form (default '0644').
    .PARAMETER Hosts
        Ansible host pattern (default 'linux').
    .OUTPUTS
        [pscustomobject] @{ Ok; Path; Message }
    #>
    param(
        [Parameter(Mandatory)] [string] $Src,
        [Parameter(Mandatory)] [string] $Dest,
        [string] $Owner = 'root',
        [string] $Group = 'root',
        [string] $Mode  = '0644',
        [string] $Hosts = 'linux'
    )

    $yaml = @"
---
# TcFltPkgMgr — generated playbook: file copy
# Src      : $Src
# Dest     : $Dest
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- name: Copy file to targets
  hosts: $Hosts
  become: true
  gather_facts: false
  tasks:
    - name: Copy $Src to $Dest
      ansible.builtin.copy:
        src: $Src
        dest: $Dest
        owner: $Owner
        group: $Group
        mode: '$Mode'
"@

    _Write-AnsiblePlaybook -Yaml $yaml -Name 'file-copy'
}

function _Get-DockerPlaybook {
    <#
    .SYNOPSIS
        Builds a playbook that manages a Docker container lifecycle on targets.
    .PARAMETER Action
        'pull' | 'start' | 'stop' | 'restart' | 'recreate' | 'remove'
    .PARAMETER ContainerName
        The Docker container name (e.g. 'web-1').
    .PARAMETER Image
        Docker image (required for 'pull', 'start', 'recreate').
    .PARAMETER Hosts
        Ansible host pattern (default 'containers').
    .OUTPUTS
        [pscustomobject] @{ Ok; Path; Message }
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('pull','start','stop','restart','recreate','remove')]
        [string] $Action,

        [Parameter(Mandatory)] [string] $ContainerName,
        [string] $Image = '',
        [string] $Hosts = 'containers'
    )

    # Map action to community.docker.docker_container state
    $state = switch ($Action) {
        'pull'     { 'started'  }  # pulls image then ensures running
        'start'    { 'started'  }
        'stop'     { 'stopped'  }
        'restart'  { 'started'  }  # force_kill + started = restart
        'recreate' { 'started'  }  # recreate=true forces pull + recreate
        'remove'   { 'absent'   }
    }

    $forceKillYaml = if ($Action -eq 'restart')  { "`n        force_kill: true"   } else { '' }
    $recreateYaml  = if ($Action -eq 'recreate') { "`n        recreate: true`n        pull: true" } else { '' }
    $pullYaml      = if ($Action -eq 'pull')     { "`n        pull: true"          } else { '' }
    $imageYaml     = if (-not [string]::IsNullOrEmpty($Image)) { "`n        image: $Image" } else { '' }

    $yaml = @"
---
# TcFltPkgMgr — generated playbook: container $Action
# Container: $ContainerName
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
- name: Container $Action — $ContainerName
  hosts: $Hosts
  become: true
  gather_facts: false
  tasks:
    - name: $Action container $ContainerName
      community.docker.docker_container:
        name: $ContainerName$imageYaml
        state: $state$forceKillYaml$recreateYaml$pullYaml
"@

    _Write-AnsiblePlaybook -Yaml $yaml -Name "container-$Action"
}

# ---------------------------------------------------------------------------
# Phase 5.4 — Batch executor
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Runs an Ansible playbook against a set of FleetTarget objects and returns
    BatchResult[] — one per target — matching the shape produced by
    Invoke-FltSshBatch and Invoke-FltWinGetBatch.

.DESCRIPTION
    Workflow:
      1. Build inventory  via New-FltAnsibleInventory
      2. Build playbook   via the supplied $PlaybookBuilder scriptblock
      3. Run ansible-playbook -i <inv> <playbook> --one-line -o json --forks <n>
      4. Parse JSON stdout → BatchResult[] (one entry per host)
      5. Call $OnProgress with a status dict after completion
      6. Clean up inventory and playbook files
      7. Write a batch log entry via Write-FltBatchEntry

    Exit code mapping (ansible-playbook):
      0  — all hosts OK
      2  — one or more hosts failed (task error)
      4  — one or more hosts unreachable
      6  — both failures and unreachable
      8  — parse/config error (counted as all-failed)

    The $OnProgress callback receives a ConcurrentDictionary<string,string>
    keyed by target name, value = "Status|DurationSec|Note" — same contract
    as Invoke-FltSshBatch.

.PARAMETER Targets
    Linux FleetTarget objects to manage. Non-Linux targets are silently skipped.

.PARAMETER PlaybookBuilder
    A scriptblock that returns a [pscustomobject]@{ Ok; Path; Message } by
    calling one of the _Get-*Playbook functions.  Evaluated by the executor
    so the caller never writes the playbook file itself.
    Example: { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' }

.PARAMETER Action
    Verb stored in BatchResult.Action (e.g. 'install', 'upgrade', 'start').

.PARAMETER PackageSpec
    Package or resource name stored in BatchResult.PackageSpec.

.PARAMETER OnProgress
    Optional scriptblock called once after the run completes, receiving the
    status ConcurrentDictionary. Matches the SshExecutor contract.

.PARAMETER ReadOnly
    When $true, skips the actual ansible-playbook call and returns Skipped
    results — mirrors the read-only mode used by the other executors.

.OUTPUTS
    [BatchResult[]]
#>
function Invoke-FltAnsibleBatch {
    param(
        [Parameter(Mandatory)] [FleetTarget[]] $Targets,
        [Parameter(Mandatory)] [scriptblock]   $PlaybookBuilder,
        [string]      $Action      = 'run',
        [string]      $PackageSpec = '',
        [scriptblock] $OnProgress  = $null,
        [bool]        $ReadOnly    = $false
    )

    $started = [datetime]::UtcNow

    # ------------------------------------------------------------------
    # Read-only mode — return Skipped results immediately
    # ------------------------------------------------------------------
    if ($ReadOnly) {
        $results = @($Targets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName     = $_.Name
            $r.Action         = $Action
            $r.PackageSpec    = $PackageSpec
            $r.PackageManager = 'ansible'
            $r.Status         = 'Skipped'
            $r.DurationSec    = 0
            $r.TimedOut       = $false
            $r.Note           = 'Read-only mode'
            $r
        })
        if ($OnProgress) {
            $dict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
            foreach ($res in $results) { [void]$dict.TryAdd($res.TargetName, "Skipped|0|Read-only mode") }
            & $OnProgress $dict
        }
        Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $results
        return $results
    }

    # ------------------------------------------------------------------
    # Check Ansible availability
    # ------------------------------------------------------------------
    $ansibleMode = Get-FltAnsibleMode
    if ($ansibleMode -eq '') {
        $results = @($Targets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName     = $_.Name
            $r.Action         = $Action
            $r.PackageSpec    = $PackageSpec
            $r.PackageManager = 'ansible'
            $r.Status         = 'Failed'
            $r.DurationSec    = 0
            $r.TimedOut       = $false
            $r.Note           = 'Ansible not available — install native, WSL, or Docker container'
            $r
        })
        Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $results
        return $results
    }

    # ------------------------------------------------------------------
    # Step 1 — Build inventory
    # ------------------------------------------------------------------
    $invResult = New-FltAnsibleInventory -Targets $Targets
    if (-not $invResult.Ok) {
        $results = @($Targets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName     = $_.Name
            $r.Action         = $Action
            $r.PackageSpec    = $PackageSpec
            $r.PackageManager = 'ansible'
            $r.Status         = 'Failed'
            $r.DurationSec    = 0
            $r.TimedOut       = $false
            $r.Note           = "Inventory error: $($invResult.Message)"
            $r
        })
        Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $results
        return $results
    }
    $invPath = $invResult.Path

    # ------------------------------------------------------------------
    # Step 2 — Build playbook
    # ------------------------------------------------------------------
    $playbookResult = & $PlaybookBuilder
    if (-not $playbookResult.Ok) {
        Remove-FltAnsibleInventory -Path $invPath
        $results = @($Targets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName     = $_.Name
            $r.Action         = $Action
            $r.PackageSpec    = $PackageSpec
            $r.PackageManager = 'ansible'
            $r.Status         = 'Failed'
            $r.DurationSec    = 0
            $r.TimedOut       = $false
            $r.Note           = "Playbook error: $($playbookResult.Message)"
            $r
        })
        Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $results
        return $results
    }
    $playbookPath = $playbookResult.Path

    # ------------------------------------------------------------------
    # Step 3 — Run ansible-playbook
    # ------------------------------------------------------------------
    $forks      = Get-FltCfgValue 'ansible' 'forks' 10
    $ansibleCmd = _Get-FltAnsibleCmd

    # Paths passed to Ansible must be translated depending on mode:
    #   Docker — convert Windows absolute path to container bind-mount path (/ansible/...)
    #   WSL    — convert Windows path to Linux path via wslpath
    #   Native — use path as-is (forward slashes for safety)
    if ($ansibleMode -eq 'docker') {
        # The bind-mount maps <TcFltPkgMgr root>/ansible → /ansible in the container.
        # Strip everything up to and including /ansible/ and prepend /ansible/.
        $ansibleRootHost = Split-Path $Script:FltConfigDir -Parent | Join-Path -ChildPath 'ansible'
        function _ToContainerPath {
            param([string]$HostPath)
            $rel = $HostPath.Substring($ansibleRootHost.Length).TrimStart('\').TrimStart('/')
            return '/ansible/' + ($rel -replace '\\','/')
        }
        $posixInv      = _ToContainerPath $invPath
        $posixPlaybook = _ToContainerPath $playbookPath
    } else {
        $posixInv      = $invPath      -replace '\\', '/'
        $posixPlaybook = $playbookPath -replace '\\', '/'
    }

    # Vault password file — written to a temp path if a vault password is stored.
    # Omitted entirely when no vault password is configured (playbooks without
    # encrypted vars work without it).
    $vaultFile    = _Get-VaultPasswordFile
    $posixVault   = if ($vaultFile) {
        if ($ansibleMode -eq 'docker') { _ToContainerPath $vaultFile } 
        else { $vaultFile -replace '\\','/' }
    } else { '' }
    $vaultFlag    = if ($posixVault) { " --vault-password-file `"$posixVault`"" } else { '' }

    $cmdLine = "$ansibleCmd -i `"$posixInv`" `"$posixPlaybook`"$vaultFlag --forks $forks 2>&1"

    $rawOutput  = ''
    $exitCode   = -1
    $runStarted = [datetime]::UtcNow

    try {
        $rawOutput = (& cmd /c $cmdLine) -join "`n"
        $exitCode  = $LASTEXITCODE
    } catch {
        $rawOutput = $_.Exception.Message
        $exitCode  = -1
    }


    $duration = ([datetime]::UtcNow - $runStarted).TotalSeconds

    # ------------------------------------------------------------------
    # Step 4 — Parse JSON output → BatchResult[]
    # ------------------------------------------------------------------
    $results = _Parse-AnsibleOutput `
        -RawOutput  $rawOutput `
        -ExitCode   $exitCode `
        -Targets    $Targets `
        -Action     $Action `
        -PackageSpec $PackageSpec `
        -Duration   $duration

    # ------------------------------------------------------------------
    # Step 5 — Invoke progress callback
    # ------------------------------------------------------------------
    if ($OnProgress) {
        $dict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
        foreach ($res in $results) {
            $entry = "$($res.Status)|$([math]::Round($res.DurationSec,1))|$($res.Note)"
            [void]$dict.TryAdd($res.TargetName, $entry)
        }
        & $OnProgress $dict
    }

    # ------------------------------------------------------------------
    # Step 6 — Clean up temp files
    # ------------------------------------------------------------------
    Remove-FltAnsibleInventory -Path $invPath
    # Only delete playbook if it was generated by TcFltPkgMgr.
    # Generated files follow the pattern: <action>-<timestamp>.yml
    # e.g. package-install-20260624-143705.yml, service-stop-20260624.yml
    $generatedPlaybookDir = _Get-FltAnsiblePlaybookDir
    $generatedPattern     = '^(package|service|user)-.*-\d{8}-\d{6}\.yml$'
    $playbookLeaf         = Split-Path $playbookPath -Leaf
    if ((Test-Path $playbookPath) -and
        $playbookPath.StartsWith($generatedPlaybookDir) -and
        $playbookLeaf -match $generatedPattern) {
        try { Remove-Item $playbookPath -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($vaultFile -and (Test-Path $vaultFile)) {
        try { Remove-Item $vaultFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    # ------------------------------------------------------------------
    # Step 7 — Log
    # ------------------------------------------------------------------
    Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $results

    return $results
}

# ---------------------------------------------------------------------------
# Phase 5.4 — Ansible JSON output parser (private)
# ---------------------------------------------------------------------------

function _Parse-AnsibleOutput {
    param(
        [string]        $RawOutput,
        [int]           $ExitCode,
        [FleetTarget[]] $Targets,
        [string]        $Action,
        [string]        $PackageSpec,
        [double]        $Duration
    )

    # ansible-playbook text output ends with a PLAY RECAP block:
    #
    #   PLAY RECAP *****
    #   192.168.x.x : ok=1  changed=1  unreachable=0  failed=0  ...
    #
    # Exit code semantics:
    #   0 — all OK
    #   2 — one or more tasks FAILED
    #   3 — one or more hosts UNREACHABLE
    #   4 — some FAILED, some UNREACHABLE
    #   other — config/parse error

    $targetMap = @{}
    foreach ($t in $Targets) { $targetMap[$t.Name] = $t }

    $results = [System.Collections.Generic.List[BatchResult]]::new()

    # Seed all targets as pending — overwritten as we parse
    foreach ($t in $Targets) {
        $r = [BatchResult]::new()
        $r.TargetName     = $t.Name
        $r.Action         = $Action
        $r.PackageSpec    = $PackageSpec
        $r.PackageManager = 'ansible'
        $r.DurationSec    = $Duration
        $r.TimedOut       = $false
        $r.Status         = 'Failed'
        $r.Note           = ''
        $results.Add($r)
    }

    # No output at all — surface raw exit code
    if ([string]::IsNullOrWhiteSpace($RawOutput)) {
        foreach ($r in $results) {
            $r.Status = 'Failed'
            $r.Note   = "No output from ansible-playbook (exit $ExitCode)"
        }
        return $results.ToArray()
    }

    # Parse the ansible-playbook PLAY RECAP block.
    # The recap contains one line per host:
    #   <host> : ok=N  changed=N  unreachable=N  failed=N  skipped=N  rescued=N  ignored=N
    # We also scan for fatal/unreachable messages for the note field.

    # Build a map of ansible_host → TargetName so recap IPs resolve back to names
    $hostToTarget = @{}
    foreach ($t in $Targets) { $hostToTarget[$t.Address] = $t.Name }

    $parsed  = @{}
    $lastMsg = @{}   # last fatal/unreachable message per host

    foreach ($line in ($RawOutput -split "`n")) {
        $line = $line.Trim()

        # Fatal / unreachable task messages — capture for note
        if ($line -match 'fatal:.*\[(.*?)\].*FAILED!.*"msg":\s*"(.+?)"') {
            $h = $Matches[1].Trim()
            $lastMsg[$h] = $Matches[2].Trim()
        } elseif ($line -match 'fatal:.*\[(.*?)\].*=>') {
            $h = $Matches[1].Trim()
            if ($line -match '"msg":\s*"(.+?)"') { $lastMsg[$h] = $Matches[1].Trim() }
        }

        # PLAY RECAP line
        if ($line -match '^([\w\.\-]+)\s*:\s*ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)') {
            $recapHost   = $Matches[1].Trim()
            $okCount     = [int]$Matches[2]
            $changed     = [int]$Matches[3]
            $unreachable = [int]$Matches[4]
            $failed      = [int]$Matches[5]

            $status = if    ($unreachable -gt 0) { 'Unreachable' }
                      elseif ($failed     -gt 0) { 'Failed'      }
                      elseif ($okCount -gt 0 -or $changed -gt 0) { 'OK' }
                      else                       { 'Failed'       }

            $note = if ($lastMsg.ContainsKey($recapHost)) { $lastMsg[$recapHost] } else { '' }
            $parsed[$recapHost] = [pscustomobject]@{ Status = $status; Note = $note }
        }
    }

    # Merge parsed results — match by ansible_host (IP) or target name
    foreach ($r in $results) {
        $tgt = $Targets | Where-Object { $_.Name -eq $r.TargetName } | Select-Object -First 1
        $ip  = if ($tgt) { $tgt.Address } else { '' }

        # Try IP first (ansible uses IP from inventory), then name
        $key = if ($parsed.ContainsKey($ip))            { $ip }
               elseif ($parsed.ContainsKey($r.TargetName)) { $r.TargetName }
               else                                      { $null }

        if ($key) {
            $p = $parsed[$key]
            $r.Status = $p.Status
            $r.Note   = $p.Note
        } elseif ($ExitCode -eq 0) {
            $r.Status = 'OK'
        } else {
            # Host missing from recap — surface first error line from raw output
            $errLine = $RawOutput -split "`n" |
                       Where-Object { $_ -match 'ERROR|error:|fatal:|UNREACHABLE' } |
                       Select-Object -First 1
            $r.Note = if ($errLine) { $errLine.Trim() } else { "Exit $ExitCode" }
        }
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Phase 5.6 — Vault helpers
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Retrieves the Ansible Vault password from the credential store and writes
    it to a temp file for use with --vault-password-file.

.DESCRIPTION
    Returns the temp file path when a vault password is stored, or $null when
    none is configured (so callers can omit --vault-password-file entirely).
    The caller is responsible for deleting the file after the run.

.OUTPUTS
    [string] Temp file path, or $null if no vault password is stored.
#>
function _Get-VaultPasswordFile {
    $pw = Get-FltStoredPassword -CredentialName 'ansible_vault'
    if ([string]::IsNullOrEmpty($pw)) { return $null }

    $path = Join-Path ([System.IO.Path]::GetTempPath()) "tcflt_vault_$(Get-Random).tmp"
    try {
        # Write with no trailing newline — ansible-vault reads exactly what's there
        [System.IO.File]::WriteAllText($path, $pw, [System.Text.Encoding]::UTF8)
        # Restrict permissions on the temp file immediately
        if ($IsWindows -or $PSVersionTable.Platform -ne 'Unix') {
            # Windows: set file to current-user-only via ACL
            try {
                $acl  = Get-Acl $path
                $acl.SetAccessRuleProtection($true, $false)
                $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                    'FullControl', 'Allow')
                $acl.AddAccessRule($rule)
                Set-Acl -Path $path -AclObject $acl
            } catch { <# non-fatal — temp file is short-lived #> }
        } else {
            # Linux/macOS: chmod 600
            try { & chmod 600 $path } catch {}
        }
        return $path
    } catch {
        Write-Verbose "_Get-VaultPasswordFile: could not write temp file: $_"
        return $null
    }
}

<#
.SYNOPSIS
    Prompts for the Ansible Vault password and saves it to the credential store.

.DESCRIPTION
    Called from the Linux Admin menu (Phase 6) > Setup > Vault password.
    The operator enters the vault password once; TcFltPkgMgr passes it
    automatically to every ansible-playbook run via --vault-password-file.

    To rotate the vault password:
      1. Re-key vault files: ansible-vault rekey ansible/group_vars/all.yml.vault
      2. Update here: TcFltPkgMgr > Linux Admin > Setup > Vault password

.OUTPUTS
    [pscustomobject] @{ Ok; Message }
#>
function Invoke-FltVaultSetup {
    Write-Host ''
    Write-Host '  Ansible Vault password setup' -ForegroundColor Cyan
    Write-Host '  The vault password is used to encrypt/decrypt secrets in'
    Write-Host '  ansible/group_vars/ and ansible/host_vars/ files.'
    Write-Host ''

    $existing = Get-FltStoredPassword -CredentialName 'ansible_vault'
    if ($existing) {
        Write-Host '  A vault password is already stored.' -ForegroundColor Green
        $choice = (Read-Host '  Replace it? [1] Yes  [0] No (default 0)').Trim()
        if ($choice -ne '1') {
            return [pscustomobject]@{ Ok = $true; Message = 'Vault password unchanged.' }
        }
    }

    $pw = (Read-Host '  Enter vault password').Trim()
    if ([string]::IsNullOrEmpty($pw)) {
        return [pscustomobject]@{ Ok = $false; Message = 'No password entered — vault password not saved.' }
    }

    $confirm = (Read-Host '  Confirm vault password').Trim()
    if ($pw -ne $confirm) {
        return [pscustomobject]@{ Ok = $false; Message = 'Passwords do not match — vault password not saved.' }
    }

    if (Set-FltStoredPassword -CredentialName 'ansible_vault' -PlainPassword $pw) {
        Write-Host '  Vault password saved.' -ForegroundColor Green
        return [pscustomobject]@{ Ok = $true; Message = 'Vault password saved successfully.' }
    } else {
        return [pscustomobject]@{ Ok = $false; Message = 'Failed to save vault password to credential store.' }
    }
}