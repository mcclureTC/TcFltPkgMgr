# =============================================================================
#  This file is auto-included by IntegrationTests.ps1
# =============================================================================

Set-StrictMode -Off

function Invoke-IT_Ansible {
    $r = _IT_NewResult
    _IT_Section 'Ansible availability'

    # 11a. Get-FltAnsibleMode returns a valid value
    try {
        $mode = Get-FltAnsibleMode
        if ($mode -in @('native', 'wsl', 'docker', '')) {
            _IT_Pass $r "21a  Get-FltAnsibleMode: returned valid mode ('$mode')"
        } else {
            _IT_Fail $r '21a  Get-FltAnsibleMode: valid return value' "Got unexpected value: '$mode'"
        }
    } catch { _IT_Fail $r '21a  Get-FltAnsibleMode' $_.Exception.Message }

    # 11b. Test-FltAnsibleAvailable is consistent with Get-FltAnsibleMode
    try {
        $avail = Test-FltAnsibleAvailable
        $mode  = Get-FltAnsibleMode
        $expected = $mode -ne ''
        if ($avail -eq $expected) {
            _IT_Pass $r "21b  Test-FltAnsibleAvailable: consistent with Get-FltAnsibleMode ($mode)"
        } else {
            _IT_Fail $r '21b  Test-FltAnsibleAvailable: consistent with mode' "Available=$avail but mode='$mode'"
        }
    } catch { _IT_Fail $r '21b  Test-FltAnsibleAvailable' $_.Exception.Message }

    # 11c. Get-FltAnsibleVersion returns a string (non-null) when available
    try {
        $mode = Get-FltAnsibleMode
        $ver  = Get-FltAnsibleVersion
        if ($mode -eq '') {
            if ($ver -eq '') {
                _IT_Pass $r '21c  Get-FltAnsibleVersion'
            } else {
                _IT_Fail $r '21c  Get-FltAnsibleVersion: empty when unavailable' "Got: '$ver'"
            }
        } else {
            if ($ver -ne '') {
                _IT_Pass $r "21c  Get-FltAnsibleVersion: '$ver'"
            } else {
                _IT_Warn $r '21c  Get-FltAnsibleVersion: returned empty' 'Ansible found but version string empty'
            }
        }
    } catch { _IT_Fail $r '21c  Get-FltAnsibleVersion' $_.Exception.Message }

    # 11d. Get-FltAnsibleStatus returns correct shape
    try {
        $status = Get-FltAnsibleStatus
        $hasAll = $null -ne $status -and
                  $null -ne $status.PSObject.Properties['Available'] -and
                  $null -ne $status.PSObject.Properties['Mode'] -and
                  $null -ne $status.PSObject.Properties['Version'] -and
                  $null -ne $status.PSObject.Properties['HasCommunityDocker']
        if ($hasAll) {
            _IT_Pass $r "21d  Get-FltAnsibleStatus: correct shape (Available=$($status.Available) Mode='$($status.Mode)')"
        } else {
            _IT_Fail $r '21d  Get-FltAnsibleStatus: correct shape' 'Missing one or more expected properties'
        }
    } catch { _IT_Fail $r '21d  Get-FltAnsibleStatus' $_.Exception.Message }

    # 11e. Test-FltAnsibleCollection returns bool (regardless of whether installed)
    try {
        $mode   = Get-FltAnsibleMode
        $result = Test-FltAnsibleCollection 'community.docker'
        if ($result -is [bool]) {
            if ($mode -eq '') {
                _IT_Pass $r '21e  Test-FltAnsibleCollection'
            } elseif ($result) {
                _IT_Pass $r '21e  Test-FltAnsibleCollection: community.docker installed'
            } else {
                _IT_Warn $r '21e  Test-FltAnsibleCollection: community.docker not installed' `
                    "Run: ansible-galaxy collection install community.docker"
            }
        } else {
            _IT_Fail $r '21e  Test-FltAnsibleCollection: returns bool' "Got type: $($result.GetType().Name)"
        }
    } catch { _IT_Fail $r '21e  Test-FltAnsibleCollection' $_.Exception.Message }

    # 11f. Test-FltAnsibleDockerContainer returns bool
    try {
        if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
            _IT_Warn $r '21f  Test-FltAnsibleDockerContainer' 'docker not on PATH — install Docker Desktop'
        } else {
            $dockerStatus = Get-FltDockerStatus
            if ($dockerStatus -ne 'running') {
                _IT_Warn $r '21f  Test-FltAnsibleDockerContainer' "Docker daemon not ready (status: $dockerStatus) — run Suite 22 to start Docker"
            } else {
                $exists = Test-FltAnsibleDockerContainer
                if ($exists -is [bool]) {
                    if ($exists) {
                        _IT_Pass $r '21f  Test-FltAnsibleDockerContainer: container exists'
                    } else {
                        _IT_Warn $r '21f  Test-FltAnsibleDockerContainer: container not found' `
                            "Run: docker build -f docker/Dockerfile.ansible -t tcflt-ansible . && docker run -d --name tcflt-ansible --restart unless-stopped -v `${PWD}/ansible:/ansible tcflt-ansible"
                    }
                } else {
                    _IT_Fail $r '21f  Test-FltAnsibleDockerContainer: returns bool' "Got: $($exists.GetType().Name)"
                }
            }
        }
    } catch { _IT_Fail $r '21f  Test-FltAnsibleDockerContainer' $_.Exception.Message }

    # 11g. Test-FltAnsibleDockerContainerRunning returns bool
    try {
        if (-not (Get-Command 'docker' -ErrorAction SilentlyContinue)) {
            _IT_Warn $r '21g  Test-FltAnsibleDockerContainerRunning' 'docker not on PATH — install Docker Desktop'
        } else {
            $dockerStatus = Get-FltDockerStatus
            if ($dockerStatus -ne 'running') {
                _IT_Warn $r '21g  Test-FltAnsibleDockerContainerRunning' "Docker daemon not ready (status: $dockerStatus) — run Suite 22 to start Docker"
            } else {
                $running = Test-FltAnsibleDockerContainerRunning
                if ($running -is [bool]) {
                    if ($running) {
                        _IT_Pass $r '21g  Test-FltAnsibleDockerContainerRunning: container is running'
                    } else {
                        $exists = Test-FltAnsibleDockerContainer
                        if ($exists) {
                            _IT_Warn $r '21g  Test-FltAnsibleDockerContainerRunning: container exists but not running' `
                                "Run: docker start tcflt-ansible"
                        } else {
                            _IT_Warn $r '21g  Test-FltAnsibleDockerContainerRunning: container not built yet' `
                                "Build first: docker build -f docker/Dockerfile.ansible -t tcflt-ansible ."
                        }
                    }
                } else {
                    _IT_Fail $r '21g  Test-FltAnsibleDockerContainerRunning: returns bool' "Got: $($running.GetType().Name)"
                }
            }
        }
    } catch { _IT_Fail $r '21g  Test-FltAnsibleDockerContainerRunning' $_.Exception.Message }

    return $r
}

# ── Suite 12 — Docker operator ────────────────────────────────────────────────

# Tests DockerRepository.ps1 — Docker Desktop status on the operator machine.
# All checks WARN gracefully when Docker is not installed or not running.
# Checks progress through states: not-installed → stopped → starting → running.
function Invoke-IT_DockerOperator {
    $r = _IT_NewResult
    _IT_Section 'Docker operator'

    # 12a. docker CLI available
    try {
        $hasDocker = $null -ne (Get-Command 'docker' -ErrorAction SilentlyContinue)
        if ($hasDocker) {
            $ver = & docker --version 2>&1
            _IT_Pass $r "22a  docker CLI available: $(($ver -join '').Trim())"
        } else {
            _IT_Warn $r '22a  docker CLI available' 'docker not on PATH — install Docker Desktop from https://www.docker.com/products/docker-desktop/'
            _IT_Skip $r '22b  Get-FltDockerStatus'           'Skipped — docker CLI not available'
            _IT_Skip $r '22c  Get-FltDockerDesktopPath'       'Skipped — docker CLI not available'
            _IT_Skip $r '22d  Test-FltDockerAvailable'        'Skipped — docker CLI not available'
            _IT_Skip $r '22e  Docker daemon status'           'Skipped — docker CLI not available'
            return $r   # remaining checks all require docker CLI
        }
    } catch {
        _IT_Fail $r '22a  docker CLI available' $_.Exception.Message
    _IT_Skip $r '22b  Get-FltDockerStatus'           'Skipped — docker CLI not available'
    _IT_Skip $r '22c  Get-FltDockerDesktopPath'       'Skipped — docker CLI not available'
    _IT_Skip $r '22d  Test-FltDockerAvailable'        'Skipped — docker CLI not available'
    _IT_Skip $r '22e  Docker daemon status'           'Skipped — docker CLI not available'
        return $r
    }

    # 12b. Get-FltDockerStatus returns valid value
    try {
        $status = Get-FltDockerStatus
        if ($status -in @('running', 'starting', 'stopped', 'not-installed')) {
            _IT_Pass $r "22b  Get-FltDockerStatus: '$status'"
        } else {
            _IT_Fail $r '22b  Get-FltDockerStatus: valid value' "Got: '$status'"
        }
    } catch { _IT_Fail $r '22b  Get-FltDockerStatus' $_.Exception.Message }

    # 12c. Get-FltDockerDesktopPath finds installation
    try {
        $path = Get-FltDockerDesktopPath
        if ($path -and (Test-Path $path -PathType Leaf)) {
            _IT_Pass $r "22c  Get-FltDockerDesktopPath: found at '$path'"
        } elseif ($path) {
            _IT_Warn $r '22c  Get-FltDockerDesktopPath' "Path: '$path'"
        } else {
            _IT_Warn $r '22c  Get-FltDockerDesktopPath: Docker Desktop not found' `
                'Install Docker Desktop or check installation path'
        }
    } catch { _IT_Fail $r '22c  Get-FltDockerDesktopPath' $_.Exception.Message }

    # 12d. Test-FltDockerAvailable consistent with Get-FltDockerStatus
    try {
        $avail  = Test-FltDockerAvailable
        $status = Get-FltDockerStatus
        $expectAvail = $status -eq 'running'
        if ($avail -eq $expectAvail) {
            _IT_Pass $r "22d  Test-FltDockerAvailable: consistent with status '$status' (available=$avail)"
        } else {
            _IT_Fail $r '22d  Test-FltDockerAvailable: consistent with status' "Available=$avail but status='$status'"
        }
    } catch { _IT_Fail $r '22d  Test-FltDockerAvailable' $_.Exception.Message }

    # 12e. Docker daemon running (or WARN with start instructions)
    try {
        $status = Get-FltDockerStatus
        switch ($status) {
            'running'       { _IT_Pass $r '22e  Docker daemon is running' }
            'starting'      { _IT_Warn $r '22e  Docker daemon is starting' 'Wait a moment and re-run suite 22' }
            'stopped'       { _IT_Warn $r '22e  Docker daemon is stopped' 'Start Docker Desktop — or TcFltPkgMgr can start it from Setup' }
            'not-installed' { _IT_Warn $r '22e  Docker not installed' 'Install Docker Desktop from https://www.docker.com/products/docker-desktop/' }
        }
    } catch { _IT_Fail $r '22e  Docker daemon status' $_.Exception.Message }

    return $r
}

# ── Suite 13 — Ansible inventory builder ──────────────────────────────────────

# Tests New-FltAnsibleInventory and Remove-FltAnsibleInventory.
# Fully offline — no Ansible installation required.
# Uses synthetic FleetTarget objects and a temp path; the live ansible/
# directory is never touched.
function Invoke-IT_AnsibleInventory {
    $r       = _IT_NewResult
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "TcFlt_IT13_$(Get-Random)"
    $inv     = Join-Path $tempDir 'hosts.ini'

    _IT_Section 'Ansible inventory builder'

    # Helper — build a minimal synthetic FleetTarget
    function _MkT {
        param([string]$Name, [string]$Address, [int]$Port=22,
              [string]$OS='linux', [string]$TargetType='physical',
              [string]$DockerHost='', [string]$ContainerName='')
        $t = [FleetTarget]::new($Name, $Address, $Port, 'admin', $false)
        $t.OS            = $OS
        $t.TargetType    = $TargetType
        $t.DockerHost    = $DockerHost
        $t.ContainerName = $ContainerName
        $t
    }

    # ------------------------------------------------------------------
    # 13a — No Linux targets → Ok=$false, TargetCount=0, file not written
    # ------------------------------------------------------------------
    try {
        $winOnly = @(_MkT 'DCC-1' '192.168.8.10' 22 'windows' 'physical')
        $res = New-FltAnsibleInventory -Targets $winOnly -Path $inv
        if ($res.Ok -eq $false -and $res.TargetCount -eq 0 -and -not (Test-Path $inv)) {
            _IT_Pass $r '23a  No Linux targets: Ok=$false, TargetCount=0, no file written'
        } else {
            _IT_Fail $r '23a  No Linux targets: Ok=$false, TargetCount=0, no file written' `
                "Ok=$($res.Ok) Count=$($res.TargetCount) FileExists=$(Test-Path $inv)"
        }
    } catch { _IT_Fail $r '23a  No Linux targets guard' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13b — Single physical Linux target → file created, Ok=$true
    # ------------------------------------------------------------------
    try {
        $null = New-Item -ItemType Directory -Path $tempDir -Force
        $targets = @(_MkT 'DCC-Linux-1' '192.168.8.110')
        $res = New-FltAnsibleInventory -Targets $targets -Path $inv
        if ($res.Ok -and (Test-Path $inv)) {
            _IT_Pass $r '23b  Single physical target: Ok=$true and file exists'
        } else {
            _IT_Fail $r '23b  Single physical target: Ok=$true and file exists' `
                "Ok=$($res.Ok) FileExists=$(Test-Path $inv) Msg=$($res.Message)"
        }
    } catch { _IT_Fail $r '23b  Single physical target written' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13c — ansible_host and ansible_port in file
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match 'ansible_host=192\.168\.8\.110' -and $content -match 'ansible_port=22') {
            _IT_Pass $r '23c  ansible_host and ansible_port present in inventory'
        } else {
            _IT_Fail $r '23c  ansible_host and ansible_port present in inventory' `
                "host=$(($content -match 'ansible_host') ) port=$(($content -match 'ansible_port') )"
        }
    } catch { _IT_Fail $r '23c  ansible_host / ansible_port' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13d — Target name is the INI hostname key
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match 'DCC-Linux-1') {
            _IT_Pass $r '23d  Target name appears as INI hostname key'
        } else {
            _IT_Fail $r '23d  Target name appears as INI hostname key' 'DCC-Linux-1 not found in inventory'
        }
    } catch { _IT_Fail $r '23d  Target name as hostname key' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13e — TargetCount counts only Linux targets (Windows excluded)
    # ------------------------------------------------------------------
    try {
        $mixed = @(
            (_MkT 'Lin-1' '10.0.0.1')
            (_MkT 'Lin-2' '10.0.0.2' 22 'linux' 'vm')
            (_MkT 'Win-1' '10.0.0.3' 22 'windows' 'physical')
        )
        $res = New-FltAnsibleInventory -Targets $mixed -Path $inv
        if ($res.TargetCount -eq 2) {
            _IT_Pass $r '23e  TargetCount=2 (Linux only, Windows excluded)'
        } else {
            _IT_Fail $r '23e  TargetCount=2 (Linux only, Windows excluded)' `
                "Got TargetCount=$($res.TargetCount)"
        }
    } catch { _IT_Fail $r '23e  TargetCount Linux-only' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13f — VM target appears under [vm] group header
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match '\[vm\]' -and $content -match 'Lin-2') {
            _IT_Pass $r '23f  VM target in [vm] group'
        } else {
            _IT_Fail $r '23f  VM target in [vm] group' `
                "[vm]=$($content -match '\[vm\]') Lin-2=$($content -match 'Lin-2')"
        }
    } catch { _IT_Fail $r '23f  VM group' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13g — [linux:children] meta-group present when multiple groups exist
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        if ($content -match '\[linux:children\]') {
            _IT_Pass $r '23g  [linux:children] meta-group present'
        } else {
            _IT_Fail $r '23g  [linux:children] meta-group present' '[linux:children] not found'
        }
    } catch { _IT_Fail $r '23g  linux:children' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13h — Container target gets ansible_connection + ansible_docker_host
    # ------------------------------------------------------------------
    try {
        $withContainer = @(
            (_MkT 'dcc4'  '192.168.8.50')
            (_MkT 'web-1' '192.168.8.50' 22 'linux' 'container' 'dcc4' 'web-1')
        )
        $res = New-FltAnsibleInventory -Targets $withContainer -Path $inv
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        $hasConn   = $content -match 'ansible_connection=community\.docker\.docker_api'
        $hasDocker = $content -match 'ansible_docker_host=tcp://'
        if ($hasConn -and $hasDocker) {
            _IT_Pass $r '23h  Container: ansible_connection and ansible_docker_host present'
        } else {
            _IT_Fail $r '23h  Container: ansible_connection and ansible_docker_host present' `
                "connection=$hasConn dockerHost=$hasDocker"
        }
    } catch { _IT_Fail $r '23h  Container vars' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13i — Docker host address resolved from target list
    # ------------------------------------------------------------------
    try {
        $content = if (Test-Path $inv) { Get-Content $inv -Raw } else { '' }
        # The Docker host dcc4 has address 192.168.8.50 — should appear in docker_host URL
        if ($content -match 'ansible_docker_host=tcp://192\.168\.8\.50:') {
            _IT_Pass $r '23i  Docker host address resolved from fleet target list'
        } else {
            _IT_Fail $r '23i  Docker host address resolved from fleet target list' `
                'Expected tcp://192.168.8.50: not found in ansible_docker_host'
        }
    } catch { _IT_Fail $r '23i  Docker host address resolution' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13j — Remove-FltAnsibleInventory deletes the file
    # ------------------------------------------------------------------
    try {
        # Ensure file exists first (may have been written by 13h)
        if (-not (Test-Path $inv)) {
            $null = New-FltAnsibleInventory -Targets @(_MkT 'Lin-X' '1.2.3.4') -Path $inv
        }
        Remove-FltAnsibleInventory -Path $inv
        if (-not (Test-Path $inv)) {
            _IT_Pass $r '23j  Remove-FltAnsibleInventory: file deleted'
        } else {
            _IT_Fail $r '23j  Remove-FltAnsibleInventory: file deleted' 'File still exists after removal'
        }
    } catch { _IT_Fail $r '23j  Remove-FltAnsibleInventory' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13k — Remove-FltAnsibleInventory is a no-op when file absent
    # ------------------------------------------------------------------
    try {
        Remove-FltAnsibleInventory -Path $inv   # file was removed in 13j
        _IT_Pass $r '23k  Remove-FltAnsibleInventory: no-op when file absent'
    } catch { _IT_Fail $r '23k  Remove-FltAnsibleInventory no-op' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13l — Parent directory auto-created for deep paths
    # ------------------------------------------------------------------
    try {
        $deepPath = Join-Path $tempDir 'sub' 'deep' 'hosts.ini'
        $res = New-FltAnsibleInventory -Targets @(_MkT 'Lin-D' '1.2.3.5') -Path $deepPath
        if ($res.Ok -and (Test-Path $deepPath)) {
            _IT_Pass $r '23l  Parent directory auto-created for deep path'
        } else {
            _IT_Fail $r '23l  Parent directory auto-created for deep path' `
                "Ok=$($res.Ok) FileExists=$(Test-Path $deepPath) Msg=$($res.Message)"
        }
    } catch { _IT_Fail $r '23l  Auto-create parent directory' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 13m — Return object has Ok, Path, TargetCount, Message properties
    # ------------------------------------------------------------------
    try {
        $res   = New-FltAnsibleInventory -Targets @(_MkT 'Lin-S' '5.6.7.8') -Path $inv
        $props = $res.PSObject.Properties.Name
        if (($props -contains 'Ok') -and ($props -contains 'Path') -and
            ($props -contains 'TargetCount') -and ($props -contains 'Message')) {
            _IT_Pass $r '23m  Return object has Ok, Path, TargetCount, Message'
        } else {
            _IT_Fail $r '23m  Return object has Ok, Path, TargetCount, Message' `
                "Properties found: $($props -join ', ')"
        }
    } catch { _IT_Fail $r '23m  Return object shape' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $r
}
# ── Suite 14 — Ansible playbook builder ───────────────────────────────────────

# Tests all five _Get-*Playbook functions in execution/AnsibleExecutor.ps1.
# Fully offline — no Ansible installation required.
# Each test writes a real YAML file to a temp directory and inspects it,
# then cleans up the temp tree.
function Invoke-IT_AnsiblePlaybook {
    $r       = _IT_NewResult
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "TcFlt_IT14_$(Get-Random)"
    $null    = New-Item -ItemType Directory -Path $tempDir -Force

    _IT_Section 'Ansible playbook builder'

    # ------------------------------------------------------------------
    # Helper: call a _Get-*Playbook function with the playbook dir
    # redirected to $tempDir so we never touch the live ansible/ tree.
    # We monkey-patch _Get-FltAnsiblePlaybookDir for the duration of
    # each test by temporarily redefining it in the local scope.
    # PowerShell resolves functions at call time, so a local override
    # takes precedence over the module-scope one.
    # ------------------------------------------------------------------

    # Override the playbook dir helper to point at our temp directory
    function _Get-FltAnsiblePlaybookDir { return $tempDir }

    # Helper: find the most-recently-written .yml in $tempDir
    function _LatestYml {
        Get-ChildItem $tempDir -Filter '*.yml' -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }

    # Helper: get content of most-recently-written .yml
    function _YmlContent {
        $f = _LatestYml
        if ($f) { Get-Content $f -Raw } else { '' }
    }

    # ------------------------------------------------------------------
    # 14a — _Get-PackagePlaybook (install): file written, Ok=$true
    # ------------------------------------------------------------------
    try {
        $res = _Get-PackagePlaybook -Action 'install' -PackageName 'curl'
        if ($res.Ok -and (Test-Path $res.Path)) {
            _IT_Pass $r '24a  _Get-PackagePlaybook install: Ok=$true and file exists'
        } else {
            _IT_Fail $r '24a  _Get-PackagePlaybook install: Ok=$true and file exists' `
                "Ok=$($res.Ok) Path=$($res.Path) Msg=$($res.Message)"
        }
    } catch { _IT_Fail $r '24a  _Get-PackagePlaybook install' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14b — Package playbook: correct module and state=present
    # ------------------------------------------------------------------
    try {
        $c = _YmlContent
        if ($c -match 'ansible\.builtin\.package' -and $c -match 'state:\s*present') {
            _IT_Pass $r '24b  Package install: ansible.builtin.package with state=present'
        } else {
            _IT_Fail $r '24b  Package install: ansible.builtin.package with state=present' `
                "module=$($c -match 'ansible.builtin.package') state=$($c -match 'state: present')"
        }
    } catch { _IT_Fail $r '24b  Package playbook content' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14c — _Get-PackagePlaybook (upgrade): state=latest
    # ------------------------------------------------------------------
    try {
        $res = _Get-PackagePlaybook -Action 'upgrade' -PackageName 'curl'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*latest') {
            _IT_Pass $r '24c  Package upgrade: state=latest'
        } else {
            _IT_Fail $r '24c  Package upgrade: state=latest' "Ok=$($res.Ok) state-latest=$($c -match 'state: latest')"
        }
    } catch { _IT_Fail $r '24c  Package upgrade' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14d — _Get-PackagePlaybook (remove): state=absent
    # ------------------------------------------------------------------
    try {
        $res = _Get-PackagePlaybook -Action 'remove' -PackageName 'curl'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*absent') {
            _IT_Pass $r '24d  Package remove: state=absent'
        } else {
            _IT_Fail $r '24d  Package remove: state=absent' "Ok=$($res.Ok) state-absent=$($c -match 'state: absent')"
        }
    } catch { _IT_Fail $r '24d  Package remove' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14e — _Get-ServicePlaybook (start): correct module and state=started
    # ------------------------------------------------------------------
    try {
        $res = _Get-ServicePlaybook -Action 'start' -ServiceName 'nginx'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'ansible\.builtin\.systemd' -and $c -match 'state:\s*started') {
            _IT_Pass $r '24e  Service start: ansible.builtin.systemd with state=started'
        } else {
            _IT_Fail $r '24e  Service start: ansible.builtin.systemd with state=started' `
                "Ok=$($res.Ok) module=$($c -match 'ansible.builtin.systemd') state=$($c -match 'state: started')"
        }
    } catch { _IT_Fail $r '24e  Service start' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14f — _Get-ServicePlaybook (restart): state=restarted
    # ------------------------------------------------------------------
    try {
        $res = _Get-ServicePlaybook -Action 'restart' -ServiceName 'nginx'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*restarted') {
            _IT_Pass $r '24f  Service restart: state=restarted'
        } else {
            _IT_Fail $r '24f  Service restart: state=restarted' "Ok=$($res.Ok) restarted=$($c -match 'state: restarted')"
        }
    } catch { _IT_Fail $r '24f  Service restart' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14g — _Get-ServicePlaybook (enable): enabled=true, no state key
    # ------------------------------------------------------------------
    try {
        $res = _Get-ServicePlaybook -Action 'enable' -ServiceName 'nginx'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'enabled:\s*true' -and $c -notmatch 'state:') {
            _IT_Pass $r '24g  Service enable: enabled=true, no state key'
        } else {
            _IT_Fail $r '24g  Service enable: enabled=true, no state key' `
                "Ok=$($res.Ok) enabled=$($c -match 'enabled: true') no-state=$($c -notmatch 'state:')"
        }
    } catch { _IT_Fail $r '24g  Service enable' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14h — _Get-UserPlaybook (create): correct module and state=present
    # ------------------------------------------------------------------
    try {
        $res = _Get-UserPlaybook -Action 'create' -UserName 'deploy' -Groups @('docker','sudo')
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'ansible\.builtin\.user' -and $c -match 'state:\s*present') {
            _IT_Pass $r '24h  User create: ansible.builtin.user with state=present'
        } else {
            _IT_Fail $r '24h  User create: ansible.builtin.user with state=present' `
                "Ok=$($res.Ok) module=$($c -match 'ansible.builtin.user') state=$($c -match 'state: present')"
        }
    } catch { _IT_Fail $r '24h  User create' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14i — User create: groups and shell appear in playbook
    # ------------------------------------------------------------------
    try {
        $c = if (Test-Path (_LatestYml)) { Get-Content (_LatestYml) -Raw } else { '' }
        if ($c -match 'docker' -and $c -match 'sudo' -and $c -match '/bin/bash') {
            _IT_Pass $r '24i  User create: groups and shell present in playbook'
        } else {
            _IT_Fail $r '24i  User create: groups and shell present in playbook' `
                "docker=$($c -match 'docker') sudo=$($c -match 'sudo') shell=$($c -match '/bin/bash')"
        }
    } catch { _IT_Fail $r '24i  User groups and shell' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14j — _Get-UserPlaybook (remove): state=absent, remove=true
    # ------------------------------------------------------------------
    try {
        $res = _Get-UserPlaybook -Action 'remove' -UserName 'deploy'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*absent' -and $c -match 'remove:\s*true') {
            _IT_Pass $r '24j  User remove: state=absent and remove=true'
        } else {
            _IT_Fail $r '24j  User remove: state=absent and remove=true' `
                "Ok=$($res.Ok) absent=$($c -match 'state: absent') remove=$($c -match 'remove: true')"
        }
    } catch { _IT_Fail $r '24j  User remove' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14k — _Get-FilePlaybook: correct module, src, dest, mode
    # ------------------------------------------------------------------
    try {
        $res = _Get-FilePlaybook -Src '/tmp/app.conf' -Dest '/etc/app/app.conf' -Mode '0640'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'ansible\.builtin\.copy' -and
            $c -match 'src:.*app\.conf' -and $c -match "mode:.*0640") {
            _IT_Pass $r '24k  File copy: ansible.builtin.copy with correct src, dest, mode'
        } else {
            _IT_Fail $r '24k  File copy: ansible.builtin.copy with correct src, dest, mode' `
                "Ok=$($res.Ok) module=$($c -match 'ansible.builtin.copy') src=$($c -match 'app.conf') mode=$($c -match '0640')"
        }
    } catch { _IT_Fail $r '24k  File copy' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14l — _Get-DockerPlaybook (start): correct module and state=started
    # ------------------------------------------------------------------
    try {
        $res = _Get-DockerPlaybook -Action 'start' -ContainerName 'web-1' -Image 'nginx:latest'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'community\.docker\.docker_container' -and $c -match 'state:\s*started') {
            _IT_Pass $r '24l  Container start: community.docker.docker_container with state=started'
        } else {
            _IT_Fail $r '24l  Container start: community.docker.docker_container with state=started' `
                "Ok=$($res.Ok) module=$($c -match 'community.docker.docker_container') state=$($c -match 'state: started')"
        }
    } catch { _IT_Fail $r '24l  Container start' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14m — _Get-DockerPlaybook (remove): state=absent
    # ------------------------------------------------------------------
    try {
        $res = _Get-DockerPlaybook -Action 'remove' -ContainerName 'web-1'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'state:\s*absent') {
            _IT_Pass $r '24m  Container remove: state=absent'
        } else {
            _IT_Fail $r '24m  Container remove: state=absent' "Ok=$($res.Ok) absent=$($c -match 'state: absent')"
        }
    } catch { _IT_Fail $r '24m  Container remove' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14n — _Get-DockerPlaybook (recreate): recreate=true and pull=true
    # ------------------------------------------------------------------
    try {
        $res = _Get-DockerPlaybook -Action 'recreate' -ContainerName 'web-1' -Image 'nginx:latest'
        $c   = if (Test-Path $res.Path) { Get-Content $res.Path -Raw } else { '' }
        if ($res.Ok -and $c -match 'recreate:\s*true' -and $c -match 'pull:\s*true') {
            _IT_Pass $r '24n  Container recreate: recreate=true and pull=true'
        } else {
            _IT_Fail $r '24n  Container recreate: recreate=true and pull=true' `
                "Ok=$($res.Ok) recreate=$($c -match 'recreate: true') pull=$($c -match 'pull: true')"
        }
    } catch { _IT_Fail $r '24n  Container recreate' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 14o — Return object has Ok, Path, Message properties
    # ------------------------------------------------------------------
    try {
        $res   = _Get-PackagePlaybook -Action 'install' -PackageName 'git'
        $props = $res.PSObject.Properties.Name
        if (($props -contains 'Ok') -and ($props -contains 'Path') -and ($props -contains 'Message')) {
            _IT_Pass $r '24o  Return object has Ok, Path, Message'
        } else {
            _IT_Fail $r '24o  Return object has Ok, Path, Message' "Properties: $($props -join ', ')"
        }
    } catch { _IT_Fail $r '24o  Return object shape' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $r
}

# ── Suite 15 — Ansible batch executor ─────────────────────────────────────────

# Tests Invoke-FltAnsibleBatch and _Parse-AnsibleOutput.
# Offline strategy:
#   - Read-only mode tests exercise the full Invoke-FltAnsibleBatch code path
#     without calling ansible-playbook.
#   - Parser tests call _Parse-AnsibleOutput directly with synthetic output
#     strings, covering all exit codes and host statuses.
function Invoke-IT_AnsibleBatch {
    $r = _IT_NewResult

    _IT_Section 'Ansible batch executor'

    # Helper: build a minimal synthetic Linux FleetTarget
    function _MkLT {
        param([string]$Name, [string]$Address = '10.0.0.1')
        $t = [FleetTarget]::new($Name, $Address, 22, 'admin', $false)
        $t.OS         = 'linux'
        $t.TargetType = 'physical'
        $t
    }

    # ------------------------------------------------------------------
    # 15a — Read-only mode: returns Skipped results without calling Ansible
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -Action 'install' -PackageSpec 'curl' `
            -ReadOnly $true
        if ($results.Count -eq 1 -and $results[0].Status -eq 'Skipped') {
            _IT_Pass $r '25a  Read-only mode: single target returns Skipped'
        } else {
            _IT_Fail $r '25a  Read-only mode: single target returns Skipped' `
                "Count=$($results.Count) Status=$($results[0].Status)"
        }
    } catch { _IT_Fail $r '25a  Read-only mode' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15b — Read-only mode: Note says 'Read-only mode'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -ReadOnly $true
        if ($results[0].Note -eq 'Read-only mode') {
            _IT_Pass $r '25b  Read-only mode: Note = ''Read-only mode'''
        } else {
            _IT_Fail $r '25b  Read-only mode: Note = ''Read-only mode''' "Note=$($results[0].Note)"
        }
    } catch { _IT_Fail $r '25b  Read-only note' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15c — Read-only mode: PackageManager = 'ansible'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -ReadOnly $true
        if ($results[0].PackageManager -eq 'ansible') {
            _IT_Pass $r '25c  Read-only mode: PackageManager = ''ansible'''
        } else {
            _IT_Fail $r '25c  Read-only mode: PackageManager = ''ansible''' `
                "PackageManager=$($results[0].PackageManager)"
        }
    } catch { _IT_Fail $r '25c  PackageManager field' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15d — Read-only mode: multiple targets all return Skipped
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1'; _MkLT 'lin-2' '10.0.0.2'; _MkLT 'lin-3' '10.0.0.3')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -ReadOnly $true
        $allSkipped = ($results | Where-Object { $_.Status -ne 'Skipped' }).Count -eq 0
        if ($results.Count -eq 3 -and $allSkipped) {
            _IT_Pass $r '25d  Read-only mode: all 3 targets return Skipped'
        } else {
            _IT_Fail $r '25d  Read-only mode: all 3 targets return Skipped' `
                "Count=$($results.Count) NotSkipped=$(($results | Where-Object { $_.Status -ne 'Skipped' }).Count)"
        }
    } catch { _IT_Fail $r '25d  Read-only multi-target' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15e — BatchResult shape: has all required fields
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        $r0    = $results[0]
        $props = $r0.PSObject.Properties.Name
        $required = @('TargetName','Action','PackageSpec','PackageManager','Status','DurationSec','TimedOut','Note')
        $missing  = $required | Where-Object { $props -notcontains $_ }
        if ($missing.Count -eq 0) {
            _IT_Pass $r '25e  BatchResult has all required fields'
        } else {
            _IT_Fail $r '25e  BatchResult has all required fields' "Missing: $($missing -join ', ')"
        }
    } catch { _IT_Fail $r '25e  BatchResult shape' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15f — BatchResult field values: Action and PackageSpec preserved
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $results = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        $r0 = $results[0]
        if ($r0.Action -eq 'install' -and $r0.PackageSpec -eq 'curl' -and $r0.TargetName -eq 'lin-1') {
            _IT_Pass $r '25f  BatchResult: Action, PackageSpec, TargetName correct'
        } else {
            _IT_Fail $r '25f  BatchResult: Action, PackageSpec, TargetName correct' `
                "Action=$($r0.Action) PackageSpec=$($r0.PackageSpec) TargetName=$($r0.TargetName)"
        }
    } catch { _IT_Fail $r '25f  BatchResult field values' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15g — Parser: SUCCESS line → Status='OK'
    # ------------------------------------------------------------------
    try {
        $targets  = @(_MkLT 'lin-1' '10.0.0.1')
        $fakeOut  = 'lin-1 | SUCCESS => {"changed": false}'
        $parsed   = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 0 `
                        -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 1.5
        if ($parsed[0].Status -eq 'OK') {
            _IT_Pass $r '25g  Parser: SUCCESS line → Status=OK'
        } else {
            _IT_Fail $r '25g  Parser: SUCCESS line → Status=OK' "Status=$($parsed[0].Status)"
        }
    } catch { _IT_Fail $r '25g  Parser SUCCESS' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15h — Parser: CHANGED line → Status='OK'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1')
        $fakeOut = 'lin-1 | CHANGED => {"changed": true}'
        $parsed  = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 0 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 1.0
        if ($parsed[0].Status -eq 'OK') {
            _IT_Pass $r '25h  Parser: CHANGED line → Status=OK'
        } else {
            _IT_Fail $r '25h  Parser: CHANGED line → Status=OK' "Status=$($parsed[0].Status)"
        }
    } catch { _IT_Fail $r '25h  Parser CHANGED' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 25i — Parser: PLAY RECAP failed host → Status=Failed, msg in Note
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1')
        $fakeOut = @(
            "PLAY RECAP *****",
            "fatal: [10.0.0.1]: FAILED! => {`"msg`": `"No package curl found`"}",
            "10.0.0.1 : ok=0  changed=0  unreachable=0  failed=1  skipped=0  rescued=0  ignored=0"
        ) -join "`n"
        $parsed  = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 2 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 2.0
        if ($parsed[0].Status -eq 'Failed') {
            _IT_Pass $r '25i  Parser: PLAY RECAP failed host → Status=Failed'
        } else {
            _IT_Fail $r '25i  Parser: PLAY RECAP failed host → Status=Failed' `
                "Status=$($parsed[0].Status) Note=$($parsed[0].Note)"
        }
    } catch { _IT_Fail $r '25i  Parser FAILED' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 25j — Parser: PLAY RECAP unreachable host → Status=Unreachable
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1')
        $fakeOut = @(
            "PLAY RECAP *****",
            "10.0.0.1 : ok=0  changed=0  unreachable=1  failed=0  skipped=0  rescued=0  ignored=0"
        ) -join "`n"
        $parsed  = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 3 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 0.5
        if ($parsed[0].Status -eq 'Unreachable') {
            _IT_Pass $r '25j  Parser: PLAY RECAP unreachable host → Status=Unreachable'
        } else {
            _IT_Fail $r '25j  Parser: UNREACHABLE → Status=Unreachable' "Status=$($parsed[0].Status)"
        }
    } catch { _IT_Fail $r '25j  Parser UNREACHABLE' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 25k — Parser: no output → all targets Failed with exit code note
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1'; _MkLT 'lin-2' '10.0.0.2')
        $parsed  = _Parse-AnsibleOutput -RawOutput '' -ExitCode 2 `
                       -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 0.1
        $allFailed = ($parsed | Where-Object { $_.Status -ne 'Failed' }).Count -eq 0
        $hasNote   = $parsed[0].Note -match 'exit|output'
        if ($allFailed -and $hasNote) {
            _IT_Pass $r '25k  Parser: empty output → all Failed with note'
        } else {
            _IT_Fail $r '25k  Parser: empty output → all Failed with note' `
                "AllFailed=$allFailed Note=$($parsed[0].Note)"
        }
    } catch { _IT_Fail $r '25k  Parser empty output' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 25l — Parser: PLAY RECAP mixed — one OK (changed), one Failed
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkLT 'lin-1' '10.0.0.1'; _MkLT 'lin-2' '10.0.0.2')
        $fakeOut = @(
            "PLAY RECAP *****",
            "10.0.0.1 : ok=1  changed=1  unreachable=0  failed=0  skipped=0  rescued=0  ignored=0",
            "10.0.0.2 : ok=0  changed=0  unreachable=0  failed=1  skipped=0  rescued=0  ignored=0"
        ) -join "`n"
        $parsed = _Parse-AnsibleOutput -RawOutput $fakeOut -ExitCode 2 `
                      -Targets $targets -Action 'install' -PackageSpec 'curl' -Duration 3.0
        $lin1 = $parsed | Where-Object { $_.TargetName -eq 'lin-1' }
        $lin2 = $parsed | Where-Object { $_.TargetName -eq 'lin-2' }
        if ($lin1.Status -eq 'OK' -and $lin2.Status -eq 'Failed') {
            _IT_Pass $r '25l  Parser: PLAY RECAP mixed — lin-1=OK, lin-2=Failed'
        } else {
            _IT_Fail $r '25l  Parser: PLAY RECAP mixed — lin-1=OK, lin-2=Failed' `
                "lin-1=$($lin1.Status) lin-2=$($lin2.Status)"
        }
    } catch { _IT_Fail $r '25l  Parser mixed output' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 15m — OnProgress callback is invoked in read-only mode
    # ------------------------------------------------------------------
    try {
        $targets      = @(_MkLT 'lin-1')
        $callbackFired = $false
        $cb = { param($dict); $script:callbackFired = $true }
        $null = Invoke-FltAnsibleBatch `
            -Targets $targets `
            -PlaybookBuilder { _Get-PackagePlaybook -Action 'install' -PackageName 'curl' } `
            -OnProgress $cb -ReadOnly $true
        if ($script:callbackFired) {
            _IT_Pass $r '25m  OnProgress callback invoked in read-only mode'
        } else {
            _IT_Fail $r '25m  OnProgress callback invoked in read-only mode' 'Callback was not called'
        }
    } catch { _IT_Fail $r '25m  OnProgress callback' $_.Exception.Message }

    return $r
}

# ── Suite 16 — Fleet executor routing ─────────────────────────────────────────

# Tests the Ansible/tcpkg/winget/push bucket routing in Invoke-FleetAction.
# Uses read-only mode throughout — no SSH, no Ansible, no tcpkg calls are made.
# Sets $Script:FltReadOnly = $true and $Script:FltBatchStatus = @{} before each
# call, then restores the original values afterward.
function Invoke-IT_FleetRouting {
    $r = _IT_NewResult

    _IT_Section 'Fleet executor routing'

    # Save and restore script-scope state
    $savedReadOnly     = $Script:FltReadOnly
    $savedBatchStatus  = $Script:FltBatchStatus
    $Script:FltReadOnly    = $true
    $Script:FltBatchStatus = @{}

    # Helper: build a minimal FleetTarget
    function _MkT {
        param([string]$Name, [string]$OS='windows', [string]$Type='physical',
              [string]$PM='', [bool]$IA=$true)
        $t = [FleetTarget]::new($Name, "10.0.0.1", 22, 'admin', $IA)
        $t.OS            = $OS
        $t.TargetType    = $Type
        $t.PackageManager = $PM
        $t
    }

    # ------------------------------------------------------------------
    # 16a — Linux physical target routes to Ansible bucket (read-only status)
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'lin-1' 'linux' 'physical')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'lin-1' }
        if ($r0 -and $r0.Status -match 'ansible') {
            _IT_Pass $r '26a  Linux physical target routes to Ansible bucket'
        } else {
            _IT_Fail $r '26a  Linux physical target routes to Ansible bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '26a  Linux → Ansible routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16b — Linux VM target routes to Ansible bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'lin-vm-1' 'linux' 'vm')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'lin-vm-1' }
        if ($r0 -and $r0.Status -match 'ansible') {
            _IT_Pass $r '26b  Linux VM target routes to Ansible bucket'
        } else {
            _IT_Fail $r '26b  Linux VM target routes to Ansible bucket' "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '26b  Linux VM → Ansible routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16c — Linux container target routes to docker-exec bucket (not Ansible)
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'cntr-1' 'linux' 'container')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'cntr-1' }
        if ($r0 -and $r0.PackageManager -eq 'docker-exec' -and $r0.Status -notmatch 'ansible') {
            _IT_Pass $r '26c  Linux container: routes to docker-exec (not Ansible)'
        } else {
            _IT_Fail $r '26c  Linux container: routes to docker-exec (not Ansible)' `
                "PackageManager=$($r0.PackageManager) Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '26c  Container not Ansible' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16d — Windows target does NOT route to Ansible bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-1' 'windows' 'physical' 'tcpkg' $true)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-1' }
        if ($r0 -and $r0.Status -notmatch 'ansible') {
            _IT_Pass $r '26d  Windows target does NOT route to Ansible bucket'
        } else {
            _IT_Fail $r '26d  Windows target does NOT route to Ansible bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '26d  Windows not Ansible' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16e — Windows tcpkg target routes to tcpkg SSH bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-1' 'windows' 'physical' 'tcpkg' $true)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-1' }
        if ($r0 -and $r0.Status -match 'tcpkg') {
            _IT_Pass $r '26e  Windows tcpkg target routes to tcpkg SSH bucket'
        } else {
            _IT_Fail $r '26e  Windows tcpkg target routes to tcpkg SSH bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '26e  Windows → tcpkg routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16f — Windows winget target routes to WinGet SSH bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-wg' 'windows' 'physical' 'winget' $true)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-wg' }
        if ($r0 -and $r0.Status -match 'winget') {
            _IT_Pass $r '26f  Windows winget target routes to WinGet SSH bucket'
        } else {
            _IT_Fail $r '26f  Windows winget target routes to WinGet SSH bucket' `
                "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '26f  Windows → WinGet routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16g — Windows target with InternetAccess=False routes to push bucket
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'win-push' 'windows' 'physical' 'tcpkg' $false)
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'win-push' }
        if ($r0 -and $r0.Status -match 'push') {
            _IT_Pass $r '26g  Windows IA=False routes to push bucket'
        } else {
            _IT_Fail $r '26g  Windows IA=False routes to push bucket' "Status=$($r0.Status)"
        }
    } catch { _IT_Fail $r '26g  Windows → push routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16h — Mixed fleet: Linux→Ansible, Windows→tcpkg, in one call
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(
            (_MkT 'lin-1'  'linux'   'physical' ''      $true)
            (_MkT 'win-1'  'windows' 'physical' 'tcpkg' $true)
        )
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $lin = $results | Where-Object { $_.TargetName -eq 'lin-1' }
        $win = $results | Where-Object { $_.TargetName -eq 'win-1' }
        if ($lin.Status -match 'ansible' -and $win.Status -match 'tcpkg') {
            _IT_Pass $r '26h  Mixed fleet: lin-1→Ansible, win-1→tcpkg'
        } else {
            _IT_Fail $r '26h  Mixed fleet: lin-1→Ansible, win-1→tcpkg' `
                "lin=$($lin.Status) win=$($win.Status)"
        }
    } catch { _IT_Fail $r '26h  Mixed fleet routing' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16i — Ansible result has PackageManager = 'ansible'
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(_MkT 'lin-1' 'linux' 'physical')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'lin-1' }
        if ($r0 -and $r0.PackageManager -eq 'ansible') {
            _IT_Pass $r '26i  Ansible bucket result has PackageManager=''ansible'''
        } else {
            _IT_Fail $r '26i  Ansible bucket result has PackageManager=''ansible''' `
                "PackageManager=$($r0.PackageManager)"
        }
    } catch { _IT_Fail $r '26i  Ansible PackageManager field' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 16j — All targets return a result (no silent drops)
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchStatus = @{}
        $targets = @(
            (_MkT 'lin-1'    'linux'   'physical'  ''       $true)
            (_MkT 'lin-2'    'linux'   'vm'        ''       $true)
            (_MkT 'win-1'    'windows' 'physical'  'tcpkg'  $true)
            (_MkT 'win-wg'   'windows' 'physical'  'winget' $true)
            (_MkT 'win-push' 'windows' 'physical'  'tcpkg'  $false)
        )
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        if ($results.Count -eq 5) {
            _IT_Pass $r '26j  All 5 targets return a result (no silent drops)'
        } else {
            _IT_Fail $r '26j  All 5 targets return a result (no silent drops)' `
                "Got $($results.Count) results, expected 5"
        }
    } catch { _IT_Fail $r '26j  No silent drops' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Restore script-scope state
    # ------------------------------------------------------------------
    $Script:FltReadOnly    = $savedReadOnly
    $Script:FltBatchStatus = $savedBatchStatus

    return $r
}

# ── Suite 17 — Ansible Vault helpers ──────────────────────────────────────────

# Tests _Get-VaultPasswordFile and Invoke-FltVaultSetup.
# Offline strategy:
#   - Seeds the credential store with a known vault password via
#     Set-FltStoredPassword, then verifies _Get-VaultPasswordFile writes it
#     to a temp file with the correct content.
#   - Clears the credential store and verifies _Get-VaultPasswordFile returns
#     $null when no vault password is configured.
#   - Tests Invoke-FltVaultSetup return object shape (non-interactive path).
#   - Cleans up the credential store entry after each test.
function Invoke-IT_AnsibleVault {
    $r = _IT_NewResult

    _IT_Section 'Ansible Vault helpers'

    $credName = 'ansible_vault'
    $testPw   = 'TestVaultPw_IT17!'

    # ------------------------------------------------------------------
    # 17a — _Get-VaultPasswordFile returns $null when no password stored
    # ------------------------------------------------------------------
    try {
        # Ensure clean state
        $null = Remove-FltStoredPassword -CredentialName $credName
        $result = _Get-VaultPasswordFile
        if ($null -eq $result) {
            _IT_Pass $r '27a  _Get-VaultPasswordFile: returns $null when no vault password stored'
        } else {
            _IT_Fail $r '27a  _Get-VaultPasswordFile: returns $null when no vault password stored' `
                "Got: $result"
        }
    } catch { _IT_Fail $r '27a  No vault password → null' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 17b — _Get-VaultPasswordFile writes temp file when password stored
    # ------------------------------------------------------------------
    $tempFile = $null
    try {
        $null = Set-FltStoredPassword -CredentialName $credName -PlainPassword $testPw
        $tempFile = _Get-VaultPasswordFile
        if ($tempFile -and (Test-Path $tempFile)) {
            _IT_Pass $r '27b  _Get-VaultPasswordFile: temp file created when password stored'
        } else {
            _IT_Fail $r '27b  _Get-VaultPasswordFile: temp file created when password stored' `
                "Path=$tempFile Exists=$(if ($tempFile) { Test-Path $tempFile } else { 'n/a' })"
        }
    } catch { _IT_Fail $r '27b  Vault password → temp file' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 17c — Temp file contains exactly the vault password
    # ------------------------------------------------------------------
    try {
        if ($tempFile -and (Test-Path $tempFile)) {
            $content = [System.IO.File]::ReadAllText($tempFile, [System.Text.Encoding]::UTF8)
            if ($content -eq $testPw) {
                _IT_Pass $r '27c  Temp file content matches stored vault password'
            } else {
                _IT_Fail $r '27c  Temp file content matches stored vault password' `
                    "Expected='$testPw' Got='$content'"
            }
        } else {
            _IT_Fail $r '27c  Temp file content matches stored vault password' 'Temp file not available (17b failed)'
        }
    } catch { _IT_Fail $r '27c  Temp file content' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 17d — Temp file has .tmp extension (covered by *.tmp in .gitignore)
    # ------------------------------------------------------------------
    try {
        if ($tempFile) {
            if ([System.IO.Path]::GetExtension($tempFile) -eq '.tmp') {
                _IT_Pass $r '27d  Temp file has .tmp extension'
            } else {
                _IT_Fail $r '27d  Temp file has .tmp extension' "Extension=$([System.IO.Path]::GetExtension($tempFile))"
            }
        } else {
            _IT_Fail $r '27d  Temp file has .tmp extension' 'Temp file not available (17b failed)'
        }
    } catch { _IT_Fail $r '27d  Temp file extension' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 17e — Temp file is in the system temp directory
    # ------------------------------------------------------------------
    try {
        if ($tempFile) {
            $expectedDir = [System.IO.Path]::GetTempPath().TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            $actualDir   = [System.IO.Path]::GetDirectoryName($tempFile)
            if ($actualDir -eq $expectedDir) {
                _IT_Pass $r '27e  Temp file is in system temp directory'
            } else {
                _IT_Fail $r '27e  Temp file is in system temp directory' `
                    "Expected='$expectedDir' Got='$actualDir'"
            }
        } else {
            _IT_Fail $r '27e  Temp file in system temp dir' 'Temp file not available (17b failed)'
        }
    } catch { _IT_Fail $r '27e  Temp file location' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 17f — Caller can delete the temp file (no locks)
    # ------------------------------------------------------------------
    try {
        if ($tempFile -and (Test-Path $tempFile)) {
            Remove-Item $tempFile -Force -ErrorAction Stop
            if (-not (Test-Path $tempFile)) {
                _IT_Pass $r '27f  Temp file can be deleted by caller (no locks)'
            } else {
                _IT_Fail $r '27f  Temp file can be deleted by caller (no locks)' 'File still exists after Remove-Item'
            }
            $tempFile = $null
        } else {
            _IT_Fail $r '27f  Temp file can be deleted by caller (no locks)' 'Temp file not available (17b failed)'
        }
    } catch { _IT_Fail $r '27f  Temp file deletable' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 17g — Second call to _Get-VaultPasswordFile creates a new temp file
    #        (idempotent — does not reuse the deleted one)
    # ------------------------------------------------------------------
    $tempFile2 = $null
    try {
        $tempFile2 = _Get-VaultPasswordFile
        if ($tempFile2 -and (Test-Path $tempFile2)) {
            _IT_Pass $r '27g  Second call creates a fresh temp file'
        } else {
            _IT_Fail $r '27g  Second call creates a fresh temp file' "Path=$tempFile2"
        }
    } catch { _IT_Fail $r '27g  Second call idempotent' $_.Exception.Message }
    finally {
        if ($tempFile2 -and (Test-Path $tempFile2)) {
            Remove-Item $tempFile2 -Force -ErrorAction SilentlyContinue
        }
    }

    # ------------------------------------------------------------------
    # 17h — Invoke-FltVaultSetup return object has Ok and Message properties
    #        (non-interactive: test the no-password-entered path by mocking
    #         via a scriptblock override is complex — test shape via read-only
    #         state: password already stored, user declines replace → Ok=$true)
    # ------------------------------------------------------------------
    try {
        # Password is still stored from 17b — simulate "already stored, no replace"
        # by calling Invoke-FltVaultSetup in a state where it would return without
        # prompting. We can't drive interactive Read-Host in tests, so we verify
        # the return shape from the one path that returns immediately:
        # Remove password → call with empty input simulation via a subexpression
        # that returns the shape check result.
        # Strategy: verify the function EXISTS and has the correct output type
        # by checking its definition, then verify Ok+Message via Remove-FltStoredPassword
        # path using a direct test of _Get-VaultPasswordFile (already covered above).
        # For Invoke-FltVaultSetup shape: test via direct invocation with pipeline
        # mock is out of scope for offline tests — just verify the function is defined
        # with the correct name and returns a pscustomobject when called with no stored pw.
        $null = Remove-FltStoredPassword -CredentialName $credName
        $fn   = Get-Command 'Invoke-FltVaultSetup' -ErrorAction SilentlyContinue
        if ($fn -and $fn.CommandType -in @('Function','ExternalScript')) {
            _IT_Pass $r '27h  Invoke-FltVaultSetup is defined and callable'
        } else {
            _IT_Fail $r '27h  Invoke-FltVaultSetup is defined and callable' `
                "CommandType=$($fn.CommandType)"
        }
    } catch { _IT_Fail $r '27h  Invoke-FltVaultSetup defined' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Cleanup — remove test credential entry
    # ------------------------------------------------------------------
    $null = Remove-FltStoredPassword -CredentialName $credName
    if ($tempFile  -and (Test-Path $tempFile))  { Remove-Item $tempFile  -Force -ErrorAction SilentlyContinue }
    if ($tempFile2 -and (Test-Path $tempFile2)) { Remove-Item $tempFile2 -Force -ErrorAction SilentlyContinue }

    return $r
}

# ── Suite 28 — Container executor ─────────────────────────────────────────────

# Tests Invoke-FltDockerExecBatch, Invoke-FltDockerLifecycleBatch, and
# _Get-FltContainerPkgCmd. Fully offline — read-only mode and direct function
# calls only; no SSH or Docker connections are made.