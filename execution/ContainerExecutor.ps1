# =============================================================================
#  TcFltPkgMgr — Container Executor
#  Two-hop execution model for Docker container fleet targets:
#    SSH to the Docker host → docker exec into the container
#
#  Phase 7.1 — Invoke-FltDockerExecBatch    (package ops inside containers)
#  Phase 7.1 — Invoke-FltDockerLifecycleBatch (docker commands on the host)
#  Phase 7.3 — Test-FltDockerHostReachable  (reachability check for containers)
# =============================================================================

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Private helper: resolve the Docker host FleetTarget for a container target
# ---------------------------------------------------------------------------

# Sentinel value for the local operator machine — no SSH needed.
$Script:FltDockerLocalHost = '__local__'

# Private helper: run a docker command locally on the operator machine.
# Returns [pscustomobject]@{ ExitStatus; Output }
function _Invoke-FltDockerLocal {
    param([string]$DockerArgs)
    try {
        $output   = & cmd /c "docker $DockerArgs 2>&1"
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitStatus = $exitCode; Output = @($output) }
    } catch {
        return [pscustomobject]@{ ExitStatus = 1; Output = @($_.Exception.Message) }
    }
}

# Private helper: returns $true when the container target uses the local Docker host.
function _Is-FltLocalDockerHost {
    param([FleetTarget]$ContainerTarget)
    return $ContainerTarget.DockerHost -eq '__local__'
}

function _Get-FltDockerHostTarget {
    param([FleetTarget] $ContainerTarget)
    $Script:FleetTargets |
        Where-Object { $_.Name -eq $ContainerTarget.DockerHost } |
        Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Private helper: build the SSH session params for a Docker host target
# ---------------------------------------------------------------------------

function _Get-FltDockerSshParams {
    param(
        [FleetTarget] $HostTarget,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string] $KeyFile = ''
    )
    $useKey = -not [string]::IsNullOrWhiteSpace($KeyFile)
    $params = @{
        ComputerName = $HostTarget.Address
        Port         = [int]$HostTarget.Port
        AcceptKey    = $true
        ErrorAction  = 'Stop'
    }
    if ($useKey) {
        $params['Username'] = $HostTarget.User
        $params['KeyFile']  = $KeyFile
    } else {
        $params['Credential'] = $Credential
    }
    $params
}

# ---------------------------------------------------------------------------
# Private helper: map PackageManager to the correct package command
# ---------------------------------------------------------------------------

function _Get-FltContainerPkgCmd {
    param([string]$PackageManager, [string]$Action, [string]$PackageName)

    $pm = if ($PackageManager) { $PackageManager } else { 'apt' }

    switch ($pm) {
        'apt' {
            switch ($Action) {
                'install' { "apt-get install -y $PackageName" }
                'upgrade' { "apt-get install --only-upgrade -y $PackageName" }
                'remove'  { "apt-get remove -y $PackageName" }
                default   { "apt-get install -y $PackageName" }
            }
        }
        'apk' {
            switch ($Action) {
                'install' { "apk add $PackageName" }
                'upgrade' { "apk upgrade $PackageName" }
                'remove'  { "apk del $PackageName" }
                default   { "apk add $PackageName" }
            }
        }
        'yum' {
            switch ($Action) {
                'install' { "yum install -y $PackageName" }
                'upgrade' { "yum update -y $PackageName" }
                'remove'  { "yum remove -y $PackageName" }
                default   { "yum install -y $PackageName" }
            }
        }
        'dnf' {
            switch ($Action) {
                'install' { "dnf install -y $PackageName" }
                'upgrade' { "dnf upgrade -y $PackageName" }
                'remove'  { "dnf remove -y $PackageName" }
                default   { "dnf install -y $PackageName" }
            }
        }
        default {
            "apt-get install -y $PackageName"
        }
    }
}

# ---------------------------------------------------------------------------
# Phase 7.1 — Docker exec batch (package operations inside containers)
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Runs a command inside Docker containers via SSH to the Docker host.

.DESCRIPTION
    Two-hop model: SSH → Docker host → docker exec -i <container> <command>
    Groups container targets by their Docker host to minimise SSH connections —
    one SSH session per host, multiple docker exec calls per session.

    Returns BatchResult[] — one per container target.

.PARAMETER Targets
    Container FleetTarget objects (TargetType = 'container').
    Non-container targets are silently skipped.

.PARAMETER Action
    Verb stored in BatchResult.Action (e.g. 'install', 'upgrade', 'remove').

.PARAMETER PackageSpec
    Package name stored in BatchResult.PackageSpec.

.PARAMETER Credential / KeyFile
    SSH credentials for the Docker host(s).

.PARAMETER TimeoutSecs
    Per-command timeout in seconds (default 300).

.PARAMETER OnProgress
    Optional scriptblock called after each container completes.
    Receives ConcurrentDictionary<string,string> keyed by target name.

.PARAMETER ReadOnly
    When $true, skips execution and returns Skipped results.
#>
function Invoke-FltDockerExecBatch {
    param(
        [Parameter(Mandatory)] [FleetTarget[]] $Targets,
        [Parameter(Mandatory)] [string]        $Action,
        [Parameter(Mandatory)] [string]        $PackageSpec,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string]      $KeyFile      = '',
        [int]         $TimeoutSecs  = 300,
        [scriptblock] $OnProgress   = $null,
        [bool]        $ReadOnly     = $false
    )

    # Filter to container targets only
    $containerTargets = @($Targets | Where-Object { $_.TargetType -eq 'container' })

    # Read-only fast path
    if ($ReadOnly) {
        $results = @($containerTargets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName     = $_.Name
            $r.Action         = $Action
            $r.PackageSpec    = $PackageSpec
            $r.PackageManager = 'docker-exec'
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

    if (-not (Ensure-FltPoshSsh)) {
        return @($containerTargets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName = $_.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
            $r.PackageManager = 'docker-exec'; $r.Status = 'Failed'
            $r.Note = 'Posh-SSH not available'; $r
        })
    }

    $started    = [datetime]::UtcNow
    $allResults = [System.Collections.Generic.List[BatchResult]]::new()
    $statusDict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()

    foreach ($t in $containerTargets) {
        [void]$statusDict.TryAdd($t.Name, "Pending|0|")
    }

    # Group container targets by Docker host to reuse SSH sessions
    $byHost = @{}
    foreach ($t in $containerTargets) {
        $hostName = $t.DockerHost
        if (-not $byHost.ContainsKey($hostName)) { $byHost[$hostName] = [System.Collections.Generic.List[FleetTarget]]::new() }
        $byHost[$hostName].Add($t)
    }

    # Process each Docker host sequentially (SSH sessions are not thread-safe in Posh-SSH)
    foreach ($hostName in $byHost.Keys) {
        $hostContainers = $byHost[$hostName]
        $isLocal        = ($hostName -eq '__local__')

        # ── Local execution path (no SSH) ──────────────────────────────────
        if ($isLocal) {
            foreach ($t in $hostContainers) {
                $pm      = Get-FltEffectivePackageManager $t
                $pkgCmd  = _Get-FltContainerPkgCmd -PackageManager $pm -Action $Action -PackageName $PackageSpec
                $execCmd = "exec -i $($t.ContainerName) $pkgCmd"

                [void]$statusDict.TryUpdate($t.Name, "Running|0|", $statusDict[$t.Name])
                if ($OnProgress) { & $OnProgress $statusDict }

                $tStart = [datetime]::UtcNow
                $r      = [BatchResult]::new()
                $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
                $r.PackageManager = 'docker-exec'; $r.Note = $t.ContainerName

                $result        = _Invoke-FltDockerLocal -DockerArgs $execCmd
                $dur           = ([datetime]::UtcNow - $tStart).TotalSeconds
                $r.DurationSec = $dur; $r.TimedOut = $false
                if ($result.ExitStatus -eq 0) {
                    $r.Status = 'OK'
                } else {
                    $r.Status = 'Failed'
                    $out = ($result.Output -join ' ').Trim()
                    if ($out.Length -gt 0) { $r.Note = "$($t.ContainerName): $($out.Substring(0, [Math]::Min(120, $out.Length)))" }
                }

                $allResults.Add($r)
                [void]$statusDict.TryUpdate($t.Name, "$($r.Status)|$([math]::Round($dur,1))|$($r.Note)", $statusDict[$t.Name])
                if ($OnProgress) { & $OnProgress $statusDict }
            }
            continue
        }

        # ── Remote SSH execution path ───────────────────────────────────────
        $hostTarget = _Get-FltDockerHostTarget -ContainerTarget $hostContainers[0]

        if ($null -eq $hostTarget) {
            foreach ($t in $hostContainers) {
                $r = [BatchResult]::new()
                $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
                $r.PackageManager = 'docker-exec'; $r.Status = 'Failed'
                $r.DurationSec = 0; $r.TimedOut = $false
                $r.Note = "Docker host '$hostName' not found in fleet"
                $allResults.Add($r)
                [void]$statusDict.TryUpdate($t.Name, "Failed|0|Host not found", $statusDict[$t.Name])
            }
            if ($OnProgress) { & $OnProgress $statusDict }
            continue
        }

        $session = $null
        try {
            $sshParams = _Get-FltDockerSshParams -HostTarget $hostTarget `
                             -Credential $Credential -KeyFile $KeyFile
            $session = New-SSHSession @sshParams
        } catch {
            foreach ($t in $hostContainers) {
                $r = [BatchResult]::new()
                $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
                $r.PackageManager = 'docker-exec'; $r.Status = 'Failed'
                $r.DurationSec = 0; $r.TimedOut = $false
                $r.Note = "SSH to '$hostName' failed: $($_.Exception.Message)"
                $allResults.Add($r)
                [void]$statusDict.TryUpdate($t.Name, "Failed|0|SSH failed", $statusDict[$t.Name])
            }
            if ($OnProgress) { & $OnProgress $statusDict }
            continue
        }

        foreach ($t in $hostContainers) {
            $pm      = Get-FltEffectivePackageManager $t
            $pkgCmd  = _Get-FltContainerPkgCmd -PackageManager $pm -Action $Action -PackageName $PackageSpec
            $execCmd = "docker exec -i $($t.ContainerName) $pkgCmd"

            [void]$statusDict.TryUpdate($t.Name, "Running|0|", $statusDict[$t.Name])
            if ($OnProgress) { & $OnProgress $statusDict }

            $tStart = [datetime]::UtcNow
            $r      = [BatchResult]::new()
            $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
            $r.PackageManager = 'docker-exec'; $r.Note = $t.ContainerName

            try {
                $result        = Invoke-SSHCommand -SessionId $session.SessionId `
                                     -Command $execCmd -TimeOut $TimeoutSecs
                $dur           = ([datetime]::UtcNow - $tStart).TotalSeconds
                $r.DurationSec = $dur; $r.TimedOut = $false
                if ($result.ExitStatus -eq 0) {
                    $r.Status = 'OK'
                } else {
                    $r.Status = 'Failed'
                    $out = ($result.Output -join ' ').Trim()
                    if ($out.Length -gt 0) { $r.Note = "$($t.ContainerName): $($out.Substring(0, [Math]::Min(120, $out.Length)))" }
                }
            } catch {
                $dur           = ([datetime]::UtcNow - $tStart).TotalSeconds
                $r.DurationSec = $dur
                $r.TimedOut    = $_.Exception.Message -match 'timed? ?out|timeout'
                $r.Status      = if ($r.TimedOut) { 'Timed out' } else { 'Failed' }
                $r.Note        = "$($t.ContainerName): $($_.Exception.Message)"
            }

            $allResults.Add($r)
            [void]$statusDict.TryUpdate($t.Name, "$($r.Status)|$([math]::Round($r.DurationSec,1))|$($r.Note)", $statusDict[$t.Name])
            if ($OnProgress) { & $OnProgress $statusDict }
        }

        if ($session) { try { Remove-SSHSession -SessionId $session.SessionId | Out-Null } catch {} }
    }

    Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $allResults.ToArray()
    return $allResults.ToArray()
}

# ---------------------------------------------------------------------------
# Phase 7.1 — Docker lifecycle batch (docker commands on the host)
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Runs Docker lifecycle commands on the Docker host for container targets.

.DESCRIPTION
    Executes `docker <Action> <ContainerName>` on each container's Docker host
    via SSH. Used for: pull, stop, start, restart, rm, run.

    Unlike DockerExecBatch this runs on the HOST, not inside the container.
    Returns BatchResult[] with PackageManager='docker-lifecycle'.

.PARAMETER Action
    Docker command verb: 'pull' | 'stop' | 'start' | 'restart' | 'rm' | 'run'

.PARAMETER PackageSpec
    For lifecycle ops this is the image name (pull) or container name (others).
    Stored in BatchResult.PackageSpec for logging.

.PARAMETER DockerArgs
    Additional arguments appended to the docker command (e.g. image tag for pull,
    run parameters for run). Optional.
#>
function Invoke-FltDockerLifecycleBatch {
    param(
        [Parameter(Mandatory)] [FleetTarget[]] $Targets,
        [Parameter(Mandatory)]
        [ValidateSet('pull','stop','start','restart','rm','run')]
        [string] $Action,
        [Parameter(Mandatory)] [string] $PackageSpec,
        [string] $DockerArgs = '',
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string]      $KeyFile     = '',
        [int]         $TimeoutSecs = 120,
        [scriptblock] $OnProgress  = $null,
        [bool]        $ReadOnly    = $false
    )

    $containerTargets = @($Targets | Where-Object { $_.TargetType -eq 'container' })

    if ($ReadOnly) {
        $results = @($containerTargets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName = $_.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
            $r.PackageManager = 'docker-lifecycle'; $r.Status = 'Skipped'
            $r.DurationSec = 0; $r.TimedOut = $false; $r.Note = 'Read-only mode'
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

    if (-not (Ensure-FltPoshSsh)) {
        return @($containerTargets | ForEach-Object {
            $r = [BatchResult]::new()
            $r.TargetName = $_.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
            $r.PackageManager = 'docker-lifecycle'; $r.Status = 'Failed'
            $r.Note = 'Posh-SSH not available'; $r
        })
    }

    $allResults = [System.Collections.Generic.List[BatchResult]]::new()
    $statusDict = [System.Collections.Concurrent.ConcurrentDictionary[string,string]]::new()
    foreach ($t in $containerTargets) { [void]$statusDict.TryAdd($t.Name, "Pending|0|") }

    # Group by Docker host
    $byHost = @{}
    foreach ($t in $containerTargets) {
        if (-not $byHost.ContainsKey($t.DockerHost)) {
            $byHost[$t.DockerHost] = [System.Collections.Generic.List[FleetTarget]]::new()
        }
        $byHost[$t.DockerHost].Add($t)
    }

    foreach ($hostName in $byHost.Keys) {
        $hostContainers = $byHost[$hostName]
        $isLocal        = ($hostName -eq '__local__')

        # ── Local execution path (no SSH) ──────────────────────────────────
        if ($isLocal) {
            foreach ($t in $hostContainers) {
                $dockerTarget = if ($Action -eq 'pull') { $PackageSpec } else { $t.ContainerName }
                $extraArgs    = if ($DockerArgs) { " $DockerArgs" } else { '' }
                $dockerArgs2  = "$Action $dockerTarget$extraArgs"

                [void]$statusDict.TryUpdate($t.Name, "Running|0|", $statusDict[$t.Name])
                if ($OnProgress) { & $OnProgress $statusDict }

                $tStart = [datetime]::UtcNow
                $r      = [BatchResult]::new()
                $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
                $r.PackageManager = 'docker-lifecycle'; $r.Note = $t.ContainerName

                $result        = _Invoke-FltDockerLocal -DockerArgs $dockerArgs2
                $dur           = ([datetime]::UtcNow - $tStart).TotalSeconds
                $r.DurationSec = $dur; $r.TimedOut = $false
                $r.Status      = if ($result.ExitStatus -eq 0) { 'OK' } else { 'Failed' }
                if ($result.ExitStatus -ne 0) {
                    $out = ($result.Output -join ' ').Trim()
                    if ($out.Length -gt 0) { $r.Note = "$($t.ContainerName): $($out.Substring(0, [Math]::Min(120, $out.Length)))" }
                }

                $allResults.Add($r)
                [void]$statusDict.TryUpdate($t.Name, "$($r.Status)|$([math]::Round($dur,1))|$($r.Note)", $statusDict[$t.Name])
                if ($OnProgress) { & $OnProgress $statusDict }
            }
            continue
        }

        # ── Remote SSH execution path ───────────────────────────────────────
        $hostTarget = _Get-FltDockerHostTarget -ContainerTarget $hostContainers[0]

        if ($null -eq $hostTarget) {
            foreach ($t in $hostContainers) {
                $r = [BatchResult]::new()
                $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
                $r.PackageManager = 'docker-lifecycle'; $r.Status = 'Failed'
                $r.Note = "Docker host '$hostName' not found in fleet"
                $allResults.Add($r)
            }
            if ($OnProgress) { & $OnProgress $statusDict }
            continue
        }

        $session = $null
        try {
            $sshParams = _Get-FltDockerSshParams -HostTarget $hostTarget `
                             -Credential $Credential -KeyFile $KeyFile
            $session = New-SSHSession @sshParams
        } catch {
            foreach ($t in $hostContainers) {
                $r = [BatchResult]::new()
                $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
                $r.PackageManager = 'docker-lifecycle'; $r.Status = 'Failed'
                $r.Note = "SSH to '$hostName' failed: $($_.Exception.Message)"
                $allResults.Add($r)
            }
            if ($OnProgress) { & $OnProgress $statusDict }
            continue
        }

        foreach ($t in $hostContainers) {
            $dockerTarget = if ($Action -eq 'pull') { $PackageSpec } else { $t.ContainerName }
            $extraArgs    = if ($DockerArgs) { " $DockerArgs" } else { '' }
            $dockerCmd    = "docker $Action $dockerTarget$extraArgs"

            [void]$statusDict.TryUpdate($t.Name, "Running|0|", $statusDict[$t.Name])
            if ($OnProgress) { & $OnProgress $statusDict }

            $tStart = [datetime]::UtcNow
            $r      = [BatchResult]::new()
            $r.TargetName = $t.Name; $r.Action = $Action; $r.PackageSpec = $PackageSpec
            $r.PackageManager = 'docker-lifecycle'; $r.Note = $t.ContainerName

            try {
                $result        = Invoke-SSHCommand -SessionId $session.SessionId `
                                     -Command $dockerCmd -TimeOut $TimeoutSecs
                $dur           = ([datetime]::UtcNow - $tStart).TotalSeconds
                $r.DurationSec = $dur; $r.TimedOut = $false
                $r.Status      = if ($result.ExitStatus -eq 0) { 'OK' } else { 'Failed' }
                if ($result.ExitStatus -ne 0) {
                    $out = ($result.Output -join ' ').Trim()
                    if ($out.Length -gt 0) { $r.Note = "$($t.ContainerName): $($out.Substring(0, [Math]::Min(120, $out.Length)))" }
                }
            } catch {
                $dur           = ([datetime]::UtcNow - $tStart).TotalSeconds
                $r.DurationSec = $dur
                $r.TimedOut    = $_.Exception.Message -match 'timed? ?out|timeout'
                $r.Status      = if ($r.TimedOut) { 'Timed out' } else { 'Failed' }
                $r.Note        = "$($t.ContainerName): $($_.Exception.Message)"
            }

            $allResults.Add($r)
            [void]$statusDict.TryUpdate($t.Name, "$($r.Status)|$([math]::Round($r.DurationSec,1))|$($r.Note)", $statusDict[$t.Name])
            if ($OnProgress) { & $OnProgress $statusDict }
        }

        if ($session) { try { Remove-SSHSession -SessionId $session.SessionId | Out-Null } catch {} }
    }

    Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $allResults.ToArray()
    return $allResults.ToArray()
}

# ---------------------------------------------------------------------------
# Phase 7.3 — Docker host reachability check
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Checks whether the Docker daemon is accessible on a Docker host target.

.DESCRIPTION
    SSHes to the Docker host and runs `docker info`. Returns:
      'online'      — SSH succeeded and docker info exit code = 0
      'docker-down' — SSH succeeded but docker info failed (daemon not running)
      'offline'     — SSH failed (host unreachable or credentials wrong)

.PARAMETER HostTarget
    The FleetTarget representing the Docker host (not the container).

.PARAMETER Credential / KeyFile
    SSH credentials for the Docker host.
#>
function Test-FltDockerHostReachable {
    param(
        [Parameter(Mandatory)] [FleetTarget] $HostTarget,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string] $KeyFile = ''
    )

    # Local machine — run docker info directly, no SSH
    if ($HostTarget.Name -eq '__local__' -or $HostTarget.Address -eq '__local__') {
        $result = _Invoke-FltDockerLocal -DockerArgs 'info --format "{{.ServerVersion}}"'
        return if ($result.ExitStatus -eq 0) { 'online' } else { 'docker-down' }
    }

    if (-not (Ensure-FltPoshSsh)) { return 'offline' }

    $session = $null
    try {
        $sshParams = _Get-FltDockerSshParams -HostTarget $HostTarget `
                         -Credential $Credential -KeyFile $KeyFile
        $session = New-SSHSession @sshParams
    } catch {
        return 'offline'
    }

    try {
        $result = Invoke-SSHCommand -SessionId $session.SessionId `
                      -Command 'docker info --format "{{.ServerVersion}}"' -TimeOut 10
        if ($result.ExitStatus -eq 0) {
            return 'online'
        } else {
            return 'docker-down'
        }
    } catch {
        return 'docker-down'
    } finally {
        if ($session) {
            try { Remove-SSHSession -SessionId $session.SessionId | Out-Null } catch {}
        }
    }
}