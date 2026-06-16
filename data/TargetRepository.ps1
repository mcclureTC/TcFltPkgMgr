# =============================================================================
#  TcFltPkgMgr — Target Repository
#  Primary target store: config/targets.local.json (all target types)
#  tcpkg is kept in sync for Windows/tcpkg targets (needed for push-from-local)
#  but is no longer the source of truth.
#
#  Migration: on first run with this version, existing tcpkg targets are read
#  via 'tcpkg remote list' and written to targets.local.json automatically.
# =============================================================================

# ── Utility functions (unchanged) ─────────────────────────────────────────────

function Repair-FltSourcePriorities {
    param([object[]]$Sources)
    $sorted = @($Sources | Sort-Object Pri)
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $newPri = $i + 1
        if ($sorted[$i].Pri -ne $newPri) {
            Invoke-FltTcpkg -ArgList @('source','edit',$sorted[$i].Name,
                '--priority',$newPri,'-y') -Silent | Out-Null
        }
    }
}

# Spawn a process with stdin piped from a string. Used for tcpkg commands that
# require password input. Returns the process exit code. Sets $Script:FltLastCmd.
function Invoke-FltWithStdin {
    param(
        [string]   $Exe,
        [string[]] $ArgList,
        [string]   $StdinText
    )
    $Script:FltLastCmd = "$Exe $($ArgList -join ' ')"

    $psi                        = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $Exe
    $psi.Arguments              = ($ArgList | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($StdinText)
    $proc.StandardInput.Close()
    $proc.WaitForExit()

    $stderr = $proc.StandardError.ReadToEnd()
    if ($stderr) { $Script:FltLastStdinErr = ($stderr -replace 'TcPkg \d+\.\d+\.\d+\s*','').Trim() }
    $Script:FltLastExit = $proc.ExitCode

    return $proc.ExitCode
}

# Run a local tcpkg command and log it. In read-only mode, prints the command
# without executing it. Returns the raw output ($null in read-only mode).
function Invoke-FltTcpkg {
    param(
        [string[]] $ArgList,
        [switch]   $Silent
    )
    $exe     = Get-FltTcpkgExe
    $display = "$exe $($ArgList -join ' ')"
    $mode    = if ($Script:FltReadOnly) { 'read-only' } else { 'live' }

    $entry = Start-FltCommandEntry -Command $display -Target 'local' -Mode $mode
    $Script:FltLastCmd = $display

    if ($Script:FltReadOnly) {
        if (-not $Silent) { Write-Host "  [read-only] $display" -ForegroundColor DarkYellow }
        $Script:FltLastExit = 0
        Complete-FltCommandEntry -Entry $entry -ExitCode 0 -DurationSec 0
        return $null
    }

    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $raw  = & $exe @ArgList 2>&1
    $Script:FltLastExit = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $sw.Stop()

    $outputText = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    Complete-FltCommandEntry -Entry $entry -ExitCode $Script:FltLastExit `
        -DurationSec $sw.Elapsed.TotalSeconds -Output $outputText

    return $raw
}

# Parse JSON from tcpkg output. Handles the version banner that tcpkg writes to
# stderr (which appears as ErrorRecord objects in the pipeline) by filtering them out
# before locating and parsing the JSON array.
function ConvertFrom-FltTcpkgJson {
    param([object[]]$Raw)
    $text  = ($Raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
              ForEach-Object { [string]$_ }) -join "`n"
    $start = $text.IndexOf('[')
    $end   = $text.LastIndexOf(']')
    if ($start -lt 0 -or $end -le $start) { return $null }
    try { return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json }
    catch { return $null }
}

# ── Target store ──────────────────────────────────────────────────────────────

function Get-FltTargetStorePath {
    return Join-Path $Script:FltConfigDir 'targets.local.json'
}

# Serialize a FleetTarget to a plain hashtable for JSON storage.
function _Target-ToHashtable {
    param([FleetTarget]$Target)
    return [ordered]@{
        Name           = $Target.Name
        Address        = $Target.Address
        Port           = $Target.Port
        User           = $Target.User
        InternetAccess = $Target.InternetAccess
        OS             = $Target.OS
        TargetType     = $Target.TargetType
        PackageManager = $Target.PackageManager
        DockerHost     = $Target.DockerHost
        ContainerName  = $Target.ContainerName
    }
}

# Deserialize a hashtable/pscustomobject from JSON into a FleetTarget.
function _Target-FromHashtable {
    param([object]$Ht)
    $t = [FleetTarget]::new(
        [string]$Ht.Name,
        [string]$Ht.Address,
        $(if ($Ht.Port) { [int]$Ht.Port } else { 22 }),
        [string]$Ht.User,
        [bool]($Ht.InternetAccess -eq $true)
    )
    if ($Ht.OS)             { $t.OS             = [string]$Ht.OS }
    if ($Ht.TargetType)     { $t.TargetType     = [string]$Ht.TargetType }
    if ($Ht.PackageManager) { $t.PackageManager = [string]$Ht.PackageManager }
    if ($Ht.DockerHost)     { $t.DockerHost     = [string]$Ht.DockerHost }
    if ($Ht.ContainerName)  { $t.ContainerName  = [string]$Ht.ContainerName }
    return $t
}

# Write the full target list to targets.local.json.
function Save-FltTargets {
    param([FleetTarget[]]$Targets)
    $path = Get-FltTargetStorePath
    $data = @($Targets | ForEach-Object { _Target-ToHashtable $_ })
    try {
        $data | ConvertTo-Json -Depth 5 |
            Set-Content -Path $path -Encoding UTF8 -Force
        return $true
    } catch {
        Write-Warning "TcFltPkgMgr: Could not save targets — $($_.Exception.Message)"
        return $false
    }
}

# ── Migration ─────────────────────────────────────────────────────────────────

# One-time migration: reads existing targets from tcpkg and writes them to
# targets.local.json. Called automatically by Get-FleetTargets on first run.
function Invoke-FltTargetStoreMigration {
    Write-Verbose "TcFltPkgMgr: Migrating targets from tcpkg to targets.local.json"

    $raw  = Invoke-FltTcpkg -ArgList @('remote','list','--as-json') -Silent
    $json = ConvertFrom-FltTcpkgJson $raw
    if ($null -eq $json) { return @() }

    $targets = @($json | ForEach-Object {
        $ht = @{}
        foreach ($prop in $_.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        $t = [FleetTarget]::new(
            [string]$ht['Name'],
            [string]$ht['Host'],
            $(if ($ht['Port']) { [int]$ht['Port'] } else { 22 }),
            [string]$ht['User'],
            [bool]($ht['InternetAccess'] -eq $true)
        )
        # Default OS/type for migrated targets — all existing are Windows/physical
        $t.OS         = 'windows'
        $t.TargetType = 'physical'
        $t
    })

    Save-FltTargets -Targets $targets | Out-Null
    Write-Verbose "TcFltPkgMgr: Migrated $($targets.Count) target(s) to targets.local.json"
    return $targets
}

# ── Read ──────────────────────────────────────────────────────────────────────

function Get-FleetTargets {
    [OutputType([FleetTarget[]])]
    param([switch]$Silent)

    $path = Get-FltTargetStorePath
    if (-not (Test-Path $path)) {
        if (-not $Silent) {
            Write-Host '  First run: migrating targets from tcpkg to local store...' `
                -ForegroundColor DarkGray
        }
        return Invoke-FltTargetStoreMigration
    }

    # Normal read from JSON store
    try {
        $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $json) { return @() }
        return @($json | ForEach-Object { _Target-FromHashtable $_ })
    } catch {
        Write-Warning "TcFltPkgMgr: Could not read targets.local.json — $($_.Exception.Message)"
        return @()
    }
}

# Quick TCP port check to determine if a target is reachable. Used by the
# reachability background job. Returns $true if port accepts a connection.
function Test-FleetTargetReachable {
    param([FleetTarget]$Target, [int]$TimeoutMs = 2000)
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $ar  = $tcp.BeginConnect($Target.Address, $Target.Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $tcp.Close()
        return $ok
    } catch { return $false }
}

# Update Reachable status on a list of FleetTarget objects using parallel TCP checks.
# Modifies targets in place. Used internally by the reachability subsystem.
function Update-FleetReachability {
    param([FleetTarget[]]$Targets)
    $results = $Targets | ForEach-Object -Parallel {
        $t = $_
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $ar  = $tcp.BeginConnect($t.Address, $t.Port, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
            $tcp.Close()
            [pscustomobject]@{ Name = $t.Name; Reachable = $ok }
        } catch {
            [pscustomobject]@{ Name = $t.Name; Reachable = $false }
        }
    } -ThrottleLimit 20

    foreach ($r in $results) {
        $t = $Targets | Where-Object { $_.Name -eq $r.Name } | Select-Object -First 1
        if ($t) { $t.Reachable = if ($r.Reachable) { 'online' } else { 'offline' } }
    }
}

# ── Write ─────────────────────────────────────────────────────────────────────

function Add-FleetTarget {
    param(
        [string] $Name,
        [string] $HostAddress,
        [int]    $Port           = 22,
        [string] $User,
        [string] $PlainPassword  = '',
        [string] $KeyFile        = '',
        [bool]   $InternetAccess = $true,
        [string] $OS             = 'windows',
        [string] $TargetType     = 'physical',
        [string] $PackageManager = '',
        [string] $DockerHost     = '',
        [string] $ContainerName  = ''
    )

    # For Windows/tcpkg targets: also register with tcpkg (needed for push-from-local)
    $needsTcpkg = $OS -eq 'windows' -and
                  ($PackageManager -eq '' -or $PackageManager -eq 'tcpkg' -or
                   $PackageManager -eq 'both')
    if ($needsTcpkg) {
        $argList = @('remote','add','-n',$Name,'--host',$HostAddress,'--port',$Port,'-u',$User)
        if ($PlainPassword)  { $argList += '--password-stdin' }
        if ($KeyFile)        { $argList += '-k',$KeyFile }
        if ($InternetAccess) { $argList += '--internet-access' }
        $argList += '-y'

        if ($PlainPassword) {
            $PlainPassword | & (Get-FltTcpkgExe) @argList 2>&1 | Out-Null
            $Script:FltLastExit = $LASTEXITCODE
        } else {
            Invoke-FltTcpkg -ArgList $argList | Out-Null
        }
        # If tcpkg reports failure, try edit as a fallback
        if ($Script:FltLastExit -ne 0) {
            $addOut = $Script:FltLastStdinErr
            $editList = @('remote','edit',$Name,'--host',$HostAddress,'--port',$Port,'-u',$User)
            if ($PlainPassword)   { $editList += '--password-stdin' }
            if ($null -ne $InternetAccess) {
                $editList += '--internet-access', $(if ($InternetAccess) { 'True' } else { 'False' })
            }
            $editList += '-y'
            if ($PlainPassword) {
                $PlainPassword | & (Get-FltTcpkgExe) @editList 2>&1 | Out-Null
                $Script:FltLastExit = $LASTEXITCODE
            } else {
                Invoke-FltTcpkg -ArgList $editList | Out-Null
            }
            $editOut = $Script:FltLastStdinErr
            if ($Script:FltLastExit -ne 0) {
                # Don't return false — still write to JSON store even if tcpkg sync fails
                # The target can be re-synced to tcpkg manually via Setup > Edit target
            }
        }
    }

    # Write to local JSON store — add if not present, update if already there
    $targets  = @(Get-FleetTargets -Silent)
    $existing = $targets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1

    if ($existing) {
        # Update existing entry (target was already in JSON, just update fields)
        $existing.Address        = $HostAddress
        $existing.Port           = $Port
        $existing.User           = $User
        $existing.InternetAccess = $InternetAccess
        $existing.OS             = $OS
        $existing.TargetType     = $TargetType
        $existing.PackageManager = $PackageManager
        $existing.DockerHost     = $DockerHost
        $existing.ContainerName  = $ContainerName
    } else {
        # Add new entry
        $t = [FleetTarget]::new($Name, $HostAddress, $Port, $User, $InternetAccess)
        $t.OS             = $OS
        $t.TargetType     = $TargetType
        $t.PackageManager = $PackageManager
        $t.DockerHost     = $DockerHost
        $t.ContainerName  = $ContainerName
        $targets += $t
    }

    return Save-FltTargets -Targets $targets
}

# Update an existing target in targets.local.json and (for Windows/tcpkg targets)
# sync the change to tcpkg remote config. Pass only the fields to change.
function Edit-FleetTarget {
    param(
        [string] $Name,
        [string] $NewName        = '',
        [string] $NewHost        = '',
        [int]    $NewPort        = 0,
        [string] $NewUser        = '',
        [string] $PlainPassword  = '',
        [object] $InternetAccess = $null,
        [string] $OS             = '',
        [string] $TargetType     = '',
        [string] $PackageManager = ''
    )

    $targets  = @(Get-FleetTargets -Silent)
    $existing = $targets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $existing) { return $false }

    # For Windows/tcpkg targets: sync change to tcpkg
    $needsTcpkg = $existing.OS -eq 'windows' -and
                  ($existing.PackageManager -eq '' -or $existing.PackageManager -eq 'tcpkg' -or
                   $existing.PackageManager -eq 'both')
    if ($needsTcpkg) {
        $argList = @('remote','edit',$Name)
        if ($NewName)       { $argList += '--new-name',$NewName }
        if ($NewHost)       { $argList += '--host',$NewHost }
        if ($NewPort)       { $argList += '--port',$NewPort }
        if ($NewUser)       { $argList += '-u',$NewUser }
        if ($PlainPassword) { $argList += '--password-stdin' }
        if ($null -ne $InternetAccess) {
            $argList += '--internet-access', $(if ($InternetAccess) { 'True' } else { 'False' })
        }
        $argList += '-y'

        if ($PlainPassword) {
            $PlainPassword | & (Get-FltTcpkgExe) @argList 2>&1 | Out-Null
            $Script:FltLastExit = $LASTEXITCODE
        } else {
            Invoke-FltTcpkg -ArgList $argList | Out-Null
        }
        if ($Script:FltLastExit -ne 0) { return $false }
    }

    # Update JSON store
    if ($NewName)             { $existing.Name          = $NewName }
    if ($NewHost)             { $existing.Address       = $NewHost }
    if ($NewPort -gt 0)       { $existing.Port          = $NewPort }
    if ($NewUser)             { $existing.User          = $NewUser }
    if ($null -ne $InternetAccess) { $existing.InternetAccess = [bool]$InternetAccess }
    if ($OS)                  { $existing.OS            = $OS }
    if ($TargetType)          { $existing.TargetType    = $TargetType }
    if ($PackageManager)      { $existing.PackageManager = $PackageManager }

    return Save-FltTargets -Targets $targets
}

# Remove a target from targets.local.json and (for Windows/tcpkg targets)
# remove it from tcpkg remote config. Non-tcpkg targets are only removed from JSON.
function Remove-FleetTarget {
    param([string]$Name)

    $targets  = @(Get-FleetTargets -Silent)
    $existing = $targets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $existing) { return $false }

    # For Windows/tcpkg targets: remove from tcpkg too
    $needsTcpkg = $existing.OS -eq 'windows' -and
                  ($existing.PackageManager -eq '' -or $existing.PackageManager -eq 'tcpkg' -or
                   $existing.PackageManager -eq 'both')
    if ($needsTcpkg) {
        Invoke-FltTcpkg -ArgList @('remote','remove',$Name) | Out-Null
        # Don't fail if tcpkg remove fails — still remove from local store
    }

    $remaining = @($targets | Where-Object { $_.Name -ne $Name })
    return Save-FltTargets -Targets $remaining
}

# Toggle the InternetAccess flag on a target — both in tcpkg (for push-from-local
# routing) and in targets.local.json. Called by the executor before/after pushing.
function Set-FleetTargetInternetAccess {
    param([string]$Name, [bool]$Value)
    # Update tcpkg first (used by push-from-local path)
    Invoke-FltTcpkg -ArgList @('remote','edit',$Name,
        '--internet-access', $(if ($Value) { 'True' } else { 'False' }), '-y') | Out-Null
    if ($Script:FltLastExit -ne 0) { return $false }

    # Update JSON store
    $targets  = @(Get-FleetTargets -Silent)
    $existing = $targets | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($existing) {
        $existing.InternetAccess = $Value
        Save-FltTargets -Targets $targets | Out-Null
    }
    return $true
}

# Ask tcpkg to verify a target's config registration. Tests that the stored
# connection details are valid in tcpkg's database, NOT a live network check.
# For live connectivity, use the TCP reachability check in FleetMenu.
function Test-FleetTargetVerify {
    param([string]$Name)
    $raw = Invoke-FltTcpkg -ArgList @('remote','verify',$Name)
    return $Script:FltLastExit -eq 0
}

# ── CSV Import / Export ───────────────────────────────────────────────────────

function Export-FleetTargetsCsv {
    param([string]$Path, [bool]$IncludePasswords = $false)
    $targets = Get-FleetTargets -Silent
    $rows    = @($targets | ForEach-Object {
        $t = $_
        [ordered]@{
            Name           = $t.Name
            Address        = $t.Address
            Port           = $t.Port
            User           = $t.User
            InternetAccess = if ($t.InternetAccess) { 'True' } else { 'False' }
            OS             = $t.OS
            TargetType     = $t.TargetType
            PackageManager = $t.PackageManager
            DockerHost     = $t.DockerHost
            ContainerName  = $t.ContainerName
            Password       = ''   # never exported
        }
    })
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $targets.Count
}

# Import targets from a CSV file. New targets are added; existing targets are
# updated if any fields changed. Windows/tcpkg targets also sync to tcpkg remote.
# Returns a summary object with Added, Updated, Skipped, and Errors counts.
function Import-FleetTargetsCsv {
    param(
        [string] $Path,
        [string] $SharedPassword  = '',
        [switch] $SkipUnreachable
    )
    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{ Added=0; Updated=0; Skipped=0; Errors=@() }
    }

    $rows    = Import-Csv -Path $Path -Encoding UTF8
    $current = @(Get-FleetTargets -Silent)
    $added   = 0; $updated = 0; $skipped = 0; $errors = @()

    foreach ($row in $rows) {
        $name    = $row.Name.Trim()
        $hostAddr = if ($row.Address) { $row.Address.Trim() } elseif ($row.Host) { $row.Host.Trim() } else { '' }
        $port    = if ($row.Port)    { [int]$row.Port }    else { 22 }
        $user    = $row.User.Trim()
        $ia      = $row.InternetAccess.Trim() -eq 'True'
        $pwd     = if ($row.Password) { $row.Password } else { $SharedPassword }
        $os      = if ($row.OS)             { $row.OS.Trim() }             else { 'windows' }
        $type    = if ($row.TargetType)     { $row.TargetType.Trim() }     else { 'physical' }
        $pm      = if ($row.PackageManager) { $row.PackageManager.Trim() } else { '' }
        $dhost   = if ($row.DockerHost)     { $row.DockerHost.Trim() }     else { '' }
        $cname   = if ($row.ContainerName)  { $row.ContainerName.Trim() }  else { '' }

        if ($SkipUnreachable) {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $ar  = $tcp.BeginConnect($hostAddr, $port, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
            $tcp.Close()
            if (-not $ok) { $skipped++; continue }
        }

        $existing = $current | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($existing) {
            $changed = $existing.Address -ne $hostAddr -or $existing.Port -ne $port -or
                       $existing.User -ne $user -or $existing.InternetAccess -ne $ia -or
                       $existing.OS -ne $os -or $existing.TargetType -ne $type
            if ($changed -or $pwd) {
                $ok = Edit-FleetTarget -Name $name -NewHost $hostAddr -NewPort $port `
                          -NewUser $user -PlainPassword $pwd -InternetAccess $ia `
                          -OS $os -TargetType $type -PackageManager $pm
                if ($ok) { $updated++ } else { $errors += "Failed to update: $name" }
            }
        } else {
            if (-not $pwd -and $os -eq 'windows' -and ($pm -eq '' -or $pm -eq 'tcpkg')) {
                $errors += "Skipped ${name}: no password for new Windows/tcpkg target"
                $skipped++
                continue
            }
            $ok = Add-FleetTarget -Name $name -HostAddress $hostAddr -Port $port `
                      -User $user -PlainPassword $pwd -InternetAccess $ia `
                      -OS $os -TargetType $type -PackageManager $pm `
                      -DockerHost $dhost -ContainerName $cname
            if ($ok) { $added++ } else { $errors += "Failed to add: $name" }
        }
    }

    return [pscustomobject]@{ Added=$added; Updated=$updated; Skipped=$skipped; Errors=$errors }
}