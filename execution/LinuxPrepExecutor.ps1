# =============================================================================
#  TcFltPkgMgr — Linux Target Preparation
#  Bootstraps a fresh Linux VM into a managed fleet node via direct SSH.
#  Uses Posh-SSH (not Ansible) so it works before Python is installed.
#
#  Entry point: Invoke-FltLinuxPrepMenu
#  Called from: Setup > select Linux target > 4. Prepare target
# =============================================================================

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function _FltPrep_OpenSession {
    param([FleetTarget]$Target, [pscredential]$Credential)
    $params = @{
        ComputerName = $Target.Address
        Port         = [int]$Target.Port
        Credential   = $Credential
        AcceptKey    = $true
        ErrorAction  = 'Stop'
    }
    return New-SSHSession @params
}

function _FltPrep_SetupSudoAskPass {
    # Write a tiny askpass script to the remote host and configure SUDO_ASKPASS
    # This avoids stdin conflicts when sudo and other commands both need stdin
    param([int]$SessionId, [string]$SudoPass)
    $escaped = $SudoPass -replace "'", "'\'''"
    $cmd = "echo '#!/bin/sh' > /tmp/.tcflt_askpass && echo 'echo ''" + "'" + $escaped + "'" + "''' >> /tmp/.tcflt_askpass && chmod 700 /tmp/.tcflt_askpass"
    $r = Invoke-SSHCommand -SessionId $SessionId -Command $cmd -TimeOut 10
    return ($r.ExitStatus -eq 0)
}

function _FltPrep_CleanupSudoAskPass {
    param([int]$SessionId)
    Invoke-SSHCommand -SessionId $SessionId `
        -Command 'rm -f /tmp/.tcflt_askpass' -TimeOut 10 | Out-Null
}

function _FltPrep_Run {
    param(
        [int]    $SessionId,
        [string] $Command,
        [int]    $TimeoutSecs = 300,
        [string] $SudoPass   = ''
    )
    # When a sudo password is provided, use SUDO_ASKPASS so stdin stays free
    $finalCmd = if ($SudoPass -and $Command -match '\bsudo\b') {
        $cmd = $Command -replace '\bsudo\b', 'sudo -A'
        "SUDO_ASKPASS=/tmp/.tcflt_askpass $cmd"
    } else {
        $Command
    }
    $r = Invoke-SSHCommand -SessionId $SessionId -Command $finalCmd -TimeOut $TimeoutSecs
    return [pscustomobject]@{
        Ok     = ($r.ExitStatus -eq 0)
        Exit   = $r.ExitStatus
        Output = ($r.Output -join "`n")
    }
}

function _FltPrep_Step {
    param(
        [string] $Label,
        [int]    $SessionId,
        [string] $Command,
        [int]    $TimeoutSecs = 300,
        [string] $SudoPass   = ''
    )
    Write-Host -NoNewline "  $Label... "
    $r = _FltPrep_Run -SessionId $SessionId -Command $Command -TimeoutSecs $TimeoutSecs -SudoPass $SudoPass
    if ($r.Ok) {
        Write-Host 'OK' -ForegroundColor Green
    } else {
        Write-Host "FAILED (exit $($r.Exit))" -ForegroundColor Red
        if ($r.Output) {
            $r.Output -split "`n" | Select-Object -Last 5 |
                ForEach-Object { if ($_.Trim()) { Write-Host "    $_" -ForegroundColor DarkGray } }
        }
    }
    return $r
}

# ---------------------------------------------------------------------------
# Preparation steps
# ---------------------------------------------------------------------------

function _FltPrep_Python {
    param([int]$SessionId, [string]$SudoPass = '')
    Write-Host ''
    Write-Host '  ── Python 3 ────────────────────────────────────────────' -ForegroundColor Cyan

    # Ensure standard Debian repo is available (Beckhoff mirrors require credentials)
    $r = _FltPrep_Step 'Add standard Debian repo' $SessionId `
        'sudo sh -c "echo ''deb http://deb.debian.org/debian trixie main'' > /etc/apt/sources.list.d/debian-main.list"' `
        -SudoPass $SudoPass
    if (-not $r.Ok) { return $false }

    $r = _FltPrep_Step 'Update apt cache' $SessionId `
        'sudo apt-get update -qq 2>&1 | grep -v "^W:" | grep -v "401" || true; exit 0' `
        -SudoPass $SudoPass
    # apt update returns non-zero if some repos fail — that's OK if main repo works
    # Run a quick check that we can find python3
    $check = _FltPrep_Run -SessionId $SessionId `
        'apt-cache show python3 2>/dev/null | grep -c "^Package"'
    if (-not $check.Ok -and $check.Output.Trim() -eq '0') {
        Write-Host '  apt cache update failed — cannot find python3 package' -ForegroundColor Red
        return $false
    }
    $r = _FltPrep_Step 'Install python3' $SessionId `
        'sudo apt-get install -y python3' -SudoPass $SudoPass
    if (-not $r.Ok) { return $false }
    $r = _FltPrep_Step 'Install python3-apt' $SessionId `
        'sudo apt-get install -y python3-apt' -SudoPass $SudoPass
    return $r.Ok
}

function _FltPrep_Docker {
    param([int]$SessionId, [string]$SudoPass = '')
    Write-Host ''
    Write-Host '  ── Docker Engine ───────────────────────────────────────' -ForegroundColor Cyan

    # Check if already installed
    $check = _FltPrep_Run -SessionId $SessionId -Command 'docker --version 2>/dev/null'
    if ($check.Ok) {
        Write-Host "  Docker already installed: $($check.Output.Trim())" -ForegroundColor Green
        return $true
    }

    $r = _FltPrep_Step 'Install prerequisites' $SessionId `
        'sudo apt-get install -y ca-certificates curl' -SudoPass $SudoPass
    if (-not $r.Ok) { return $false }

    $r = _FltPrep_Step 'Add Docker GPG key' $SessionId `
        'sudo install -m 0755 -d /etc/apt/keyrings && sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc' `
        -SudoPass $SudoPass
    if (-not $r.Ok) { return $false }

    # Build the docker apt repo line — avoid complex quoting issues by writing a script
    $repoCmd = 'sudo sh -c "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list"'
    $r = _FltPrep_Step 'Add Docker apt repo' $SessionId $repoCmd -SudoPass $SudoPass
    if (-not $r.Ok) { return $false }

    # apt-get update may return non-zero due to unauthorized Beckhoff repos — ignore
    $r = _FltPrep_Step 'Update apt cache' $SessionId `
        'sudo apt-get update -qq 2>&1; exit 0' -SudoPass $SudoPass

    $r = _FltPrep_Step 'Install Docker Engine' $SessionId `
        'sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' `
        -TimeoutSecs 600 -SudoPass $SudoPass
    if (-not $r.Ok) { return $false }

    $r = _FltPrep_Step 'Add user to docker group' $SessionId `
        'sudo usermod -aG docker $USER' -SudoPass $SudoPass
    return $r.Ok
}

function _FltPrep_NopasswdSudo {
    param([int]$SessionId, [string]$User, [string]$SudoPass = '')
    Write-Host ''
    Write-Host '  ── Passwordless sudo ───────────────────────────────────' -ForegroundColor Cyan

    # Write sudoers entry
    $r = _FltPrep_Step "Write sudoers.d/tcflt-nopasswd" $SessionId `
        "SUDO_ASKPASS=/tmp/.tcflt_askpass sudo -A tee /etc/sudoers.d/tcflt-nopasswd > /dev/null <<< '$User ALL=(ALL) NOPASSWD: ALL' && SUDO_ASKPASS=/tmp/.tcflt_askpass sudo -A chmod 440 /etc/sudoers.d/tcflt-nopasswd" `
        -SudoPass $SudoPass
    return $r.Ok
}

function _FltPrep_SshKey {
    param([int]$SessionId)
    Write-Host ''
    Write-Host '  ── Ansible SSH key ─────────────────────────────────────' -ForegroundColor Cyan

    # Get public key from ansible/tcflt-ansible.pub or directly from container
    $pubKeyPath = Join-Path $Script:FltScriptRoot 'ansible' |
                  Join-Path -ChildPath 'tcflt-ansible.pub'
    $pubKey = ''
    if (Test-Path $pubKeyPath) {
        $pubKey = (Get-Content $pubKeyPath -Raw).Trim()
    } else {
        $containerName = Get-FltCfgValue 'ansible' 'dockerContainer' 'tcflt-ansible'
        $pubKey = (& cmd /c "docker exec $containerName cat /root/.ssh/id_ed25519.pub 2>&1") -join ''
        if ($LASTEXITCODE -ne 0 -or -not $pubKey) {
            Write-Host '  FAILED — tcflt-ansible container not running or key not found.' -ForegroundColor Red
            Write-Host "  Start the container and ensure $pubKeyPath exists." -ForegroundColor DarkGray
            return $false
        }
        $pubKey = $pubKey.Trim()
    }

    # Write key directly via heredoc to avoid quoting issues
    $r = _FltPrep_Step 'Create ~/.ssh directory' $SessionId 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
    if (-not $r.Ok) { return $false }

    # Use printf to avoid echo interpretation issues
    $escaped = $pubKey -replace "'", "'\'''"
    $r = _FltPrep_Step 'Install tcflt-ansible public key' $SessionId `
        "printf '%s\n' '$escaped' >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    return $r.Ok
}

function _FltPrep_Verify {
    param([int]$SessionId)
    Write-Host ''
    Write-Host '  ── Verification ────────────────────────────────────────' -ForegroundColor Cyan
    $checks = @(
        @{ Label = 'python3 available';     Cmd = 'python3 --version 2>&1' },
        @{ Label = 'python3-apt available'; Cmd = 'python3 -c "import apt; print(\"ok\")" 2>&1' },
        @{ Label = 'docker available';      Cmd = 'docker --version 2>&1' },
        @{ Label = 'sudo NOPASSWD works';   Cmd = 'sudo -n true 2>&1' }
    )
    $allOk = $true
    foreach ($c in $checks) {
        $r = _FltPrep_Step $c.Label $SessionId $c.Cmd
        if (-not $r.Ok) { $allOk = $false }
    }
    return $allOk
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

function Invoke-FltLinuxPrepMenu {
    param(
        [FleetTarget]  $Target,
        [pscredential] $Credential
    )

    Clear-Host
    Write-Host "  Prepare Linux target: $($Target.Name)" -ForegroundColor Cyan
    Write-Host "  $($Target.Address):$($Target.Port)  user=$($Target.User)" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Select items to install/configure (space-separated, e.g. 1 2 3):' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   1. Python 3 + python3-apt  (required for Ansible)'
    Write-Host '   2. Docker Engine           (required for container targets)'
    Write-Host '   3. Passwordless sudo       (required for Ansible become)'
    Write-Host '   4. Install Ansible SSH key (required for key-based Ansible auth)'
    Write-Host '   5. All of the above'
    Write-Host '   6. Verify current state only'
    Write-Host '   0. Cancel'
    Write-Host ''
    Write-Host '  Select: 1,2,3 or 1-4 or 1..4  (comma, dash, or dot-dot range)' -ForegroundColor DarkGray
    Write-Host ''
    $raw = (Read-Host '  Selection').Trim()
    if ($raw -eq '0' -or [string]::IsNullOrEmpty($raw)) { return }

    $doPython   = $false
    $doDocker   = $false
    $doSudo     = $false
    $doSshKey   = $false
    $verifyOnly = $false

    # Expand range notation: 1-4 or 1..4 → individual numbers
    $expanded = $raw `
        -replace '(\d+)\s*\.\.\s*(\d+)', { 
            $a = [int]$_.Groups[1].Value; $b = [int]$_.Groups[2].Value
            ($a..$b) -join ','
        } `
        -replace '(\d+)\s*-\s*(\d+)', {
            $a = [int]$_.Groups[1].Value; $b = [int]$_.Groups[2].Value
            ($a..$b) -join ','
        }
    $choices = ($expanded -split '[,\s]+') |
               Where-Object { $_ -match '^\d+$' } |
               ForEach-Object { [int]$_ } |
               Select-Object -Unique

    if (6 -in $choices) {
        $verifyOnly = $true
    } elseif (5 -in $choices) {
        $doPython = $doDocker = $doSudo = $doSshKey = $true
    } else {
        $doPython = 1 -in $choices
        $doDocker = 2 -in $choices
        $doSudo   = 3 -in $choices
        $doSshKey = 4 -in $choices
    }

    if (-not $doPython -and -not $doDocker -and -not $doSudo -and -not $doSshKey -and -not $verifyOnly) {
        Write-Host '  Nothing selected.' -ForegroundColor Yellow
        Read-Host '  Press Enter'
        return
    }

    # Open SSH session
    Write-Host ''
    Write-Host '  Connecting...' -ForegroundColor DarkGray
    $session = $null
    try {
        $session = _FltPrep_OpenSession -Target $Target -Credential $Credential
    } catch {
        Write-Host "  SSH connection failed: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host '  Press Enter'
        return
    }
    $sid = $session.SessionId
    Write-Host "  Connected (session $sid)" -ForegroundColor DarkGray

    # Extract plain password and set up SUDO_ASKPASS helper on remote host
    $sudoPass = ''
    try { $sudoPass = $Credential.GetNetworkCredential().Password } catch {}
    if ($sudoPass) {
        $askOk = _FltPrep_SetupSudoAskPass -SessionId $sid -SudoPass $sudoPass
        if (-not $askOk) {
            Write-Host '  Warning: could not write sudo askpass helper — sudo steps may fail.' -ForegroundColor Yellow
        }
    }

    $allOk = $true
    try {
        if ($verifyOnly) {
            $allOk = _FltPrep_Verify -SessionId $sid
        } else {
            if ($doPython)  { if (-not (_FltPrep_Python        -SessionId $sid -SudoPass $sudoPass))               { $allOk = $false } }
            if ($doDocker)  { if (-not (_FltPrep_Docker        -SessionId $sid -SudoPass $sudoPass))               { $allOk = $false } }
            if ($doSudo)    { if (-not (_FltPrep_NopasswdSudo  -SessionId $sid -User $Target.User -SudoPass $sudoPass)) { $allOk = $false } }
            if ($doSshKey)  { if (-not (_FltPrep_SshKey        -SessionId $sid))                                   { $allOk = $false } }
            # Always verify at end
            if (-not (_FltPrep_Verify -SessionId $sid)) { $allOk = $false }
        }
    } finally {
        if ($sudoPass) { _FltPrep_CleanupSudoAskPass -SessionId $sid }
        Remove-SSHSession -SessionId $sid | Out-Null
    }

    Write-Host ''
    Write-Host ('  ' + ('-' * 54)) -ForegroundColor DarkGray
    if ($allOk) {
        Write-Host '  Target is ready for Ansible management.' -ForegroundColor Green
    } else {
        Write-Host '  One or more steps failed — review output above.' -ForegroundColor Yellow
    }
    Write-Host ''
    Read-Host '  Press Enter'
}