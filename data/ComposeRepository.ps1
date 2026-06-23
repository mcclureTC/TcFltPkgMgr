# =============================================================================
#  TcFltPkgMgr — Compose Repository
#  Docker Compose file generation, template management, and compose operations.
#
#  Phase 8.8 — compose infrastructure
# =============================================================================

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

function Get-FltComposeDir {
    $rel = Get-FltCfgValue 'compose' 'dir' 'compose'
    Join-Path $Script:FltScriptRoot $rel
}

function Get-FltComposeTemplateDir {
    Join-Path (Get-FltComposeDir) 'templates'
}

function Get-FltComposeBuildDir {
    # Dockerfile.debian-ssh lives in docker/ alongside Dockerfile.ansible
    Join-Path $Script:FltScriptRoot 'docker'
}

# ---------------------------------------------------------------------------
# Template discovery
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Lists available compose templates.
.OUTPUTS
    Array of [pscustomobject]@{ Name; Path; Description }
#>
function Get-FltComposeTemplates {
    $dir = Get-FltComposeTemplateDir
    if (-not (Test-Path $dir)) { return @() }

    $descriptions = @{
        'twincat-xar'  = 'TwinCAT XAR runtime (Beckhoff tcbsd-twincat-xar)'
        'mosquitto'    = 'Eclipse Mosquitto MQTT broker'
        'debian-ssh'   = 'Debian Bookworm SSH management target (Python 3, root login)'
    }

    @(Get-ChildItem -Path $dir -Filter '*.template' -ErrorAction SilentlyContinue |
        Sort-Object Name |
        ForEach-Object {
            $key  = $_.BaseName -replace '\.yml$', ''
            $desc = if ($descriptions.ContainsKey($key)) { $descriptions[$key] } else { $key }
            [pscustomobject]@{
                Name        = $key
                Path        = $_.FullName
                Description = $desc
            }
        })
}

# ---------------------------------------------------------------------------
# Compose file parsing
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Parses a compose file and returns the service names it defines.
.OUTPUTS
    [string[]] service names
#>
function Get-FltComposeServices {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return @() }

    $services = [System.Collections.Generic.List[string]]::new()
    $inServices = $false

    foreach ($line in Get-Content $Path) {
        if ($line -match '^services\s*:') {
            $inServices = $true
            continue
        }
        if ($inServices) {
            # Top-level key under services (2 spaces + name + colon)
            if ($line -match '^  ([a-zA-Z0-9_\-]+)\s*:') {
                $services.Add($Matches[1])
            }
            # Another top-level section ends the services block
            elseif ($line -match '^[a-zA-Z]' -and $line -notmatch '^\s') {
                $inServices = $false
            }
        }
    }

    return $services.ToArray()
}

# ---------------------------------------------------------------------------
# Network definition helper
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Builds the YAML network definition block for a compose file.
    Either defines the network inline or marks it as external.
#>
function _Get-FltNetworkDefinition {
    param(
        [string] $NetworkName,
        [string] $Subnet,
        [string] $Gateway,
        [bool]   $External
    )

    if ($External) {
        return "external: true"
    }

    return "name: $NetworkName`n    ipam:`n      driver: default`n      config:`n        - subnet: $Subnet`n          gateway: $Gateway"
}

# ---------------------------------------------------------------------------
# Template generation
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Generates a compose file from a template with variable substitution.
    Returns [pscustomobject]@{ Ok; Path; Services; Message }
#>
function New-FltComposeFromTemplate {
    param(
        [Parameter(Mandatory)][string] $TemplateName,
        [Parameter(Mandatory)][string] $OutputName,    # filename without extension
        [Parameter(Mandatory)][hashtable] $Variables   # key=value substitution map
    )

    $templateDir = Get-FltComposeTemplateDir
    $templatePath = Join-Path $templateDir "$TemplateName.yml.template"

    if (-not (Test-Path $templatePath)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Services = @()
            Message = "Template '$TemplateName' not found at: $templatePath" }
    }

    $composeDir = Get-FltComposeDir
    if (-not (Test-Path $composeDir)) { New-Item -ItemType Directory -Path $composeDir | Out-Null }

    $outPath = Join-Path $composeDir "$OutputName.yml"

    try {
        $content = Get-Content $templatePath -Raw -Encoding UTF8

        # Remove template header comment block
        $content = $content -replace '(?s)^# =+.*?# =+\n', ''

        # Substitute all {{VARIABLE}} placeholders
        foreach ($key in $Variables.Keys) {
            $content = $content -replace [regex]::Escape("{{$key}}"), $Variables[$key]
        }

        # Check for unreplaced placeholders
        $unreplaced = [regex]::Matches($content, '\{\{[A-Z_]+\}\}') |
                      ForEach-Object { $_.Value } | Sort-Object -Unique
        if ($unreplaced.Count -gt 0) {
            return [pscustomobject]@{ Ok = $false; Path = ''; Services = @()
                Message = "Unreplaced variables: $($unreplaced -join ', ')" }
        }

        $content | Set-Content -Path $outPath -Encoding UTF8 -NoNewline

        $services = @(Get-FltComposeServices -Path $outPath)
        return [pscustomobject]@{ Ok = $true; Path = $outPath; Services = $services
            Message = "Compose file created: $outPath ($($services.Count) service(s))" }

    } catch {
        return [pscustomobject]@{ Ok = $false; Path = ''; Services = @()
            Message = "Error generating compose file: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# CSV import/export for batch container deployment
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Exports container fleet targets to a CSV for editing and re-import.
    Columns: Name, ComposeFile, ComposeService, ComposeProject,
             DockerHost, AmsNetId, IpAddress, SshPort
#>
function Export-FltContainerCsv {
    param([Parameter(Mandatory)][string]$Path)

    $containers = @($Script:FleetTargets | Where-Object { $_.TargetType -eq 'container' })
    if ($containers.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Message = 'No container targets to export.' }
    }

    try {
        $rows = $containers | ForEach-Object {
            [ordered]@{
                Name           = $_.Name
                ComposeFile    = $_.ComposeFile
                ComposeService = $_.ComposeService
                ComposeProject = $_.ComposeProject
                DockerHost     = $_.DockerHost
                PackageManager = $_.PackageManager
                AmsNetId       = ''     # user fills in for TwinCAT targets
                IpAddress      = ''     # user fills in
                SshPort        = '22'
            }
        }
        $rows | ForEach-Object { [pscustomobject]$_ } |
            Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
        return [pscustomobject]@{ Ok = $true
            Message = "Exported $($containers.Count) container(s) to: $Path" }
    } catch {
        return [pscustomobject]@{ Ok = $false
            Message = "Export failed: $($_.Exception.Message)" }
    }
}

<#
.SYNOPSIS
    Imports container definitions from CSV and generates a single compose file
    with one service per row. Returns the generated compose file path and
    a list of service definitions for fleet target registration.

.DESCRIPTION
    CSV columns (case-insensitive):
      Name           — container name and compose service name
      AmsNetId       — TwinCAT AMS Net ID (TwinCAT rows only)
      IpAddress      — static IP on container-network
      SshPort        — SSH port mapping (debian-ssh rows only)
      PackageManager — apt / apk / yum / dnf (default: apt)
      Template       — twincat-xar | mosquitto | debian-ssh

.OUTPUTS
    [pscustomobject]@{ Ok; ComposeFile; Services; Message }
    Services = array of @{ Name; Template; SshPort }
#>
function Import-FltContainerCsv {
    param(
        [Parameter(Mandatory)][string] $CsvPath,
        [Parameter(Mandatory)][string] $OutputName,
        [Parameter(Mandatory)][string] $NetworkName,
        [bool]   $NetworkExternal = $false,
        [string] $Subnet  = '',
        [string] $Gateway = ''
    )

    if (-not (Test-Path $CsvPath)) {
        return [pscustomobject]@{ Ok = $false; ComposeFile = ''; Services = @()
            Message = "CSV not found: $CsvPath" }
    }

    try {
        $rows = Import-Csv -Path $CsvPath -Encoding UTF8
    } catch {
        return [pscustomobject]@{ Ok = $false; ComposeFile = ''; Services = @()
            Message = "CSV read failed: $($_.Exception.Message)" }
    }

    if ($rows.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; ComposeFile = ''; Services = @()
            Message = "CSV is empty." }
    }

    # Get network defaults from settings if not supplied
    if (-not $Subnet)  { $Subnet  = Get-FltCfgValue 'compose' 'subnet'  '192.168.20.0/24' }
    if (-not $Gateway) { $Gateway = Get-FltCfgValue 'compose' 'gateway' '192.168.20.1'    }

    $netDef = _Get-FltNetworkDefinition -NetworkName $NetworkName `
                  -Subnet $Subnet -Gateway $Gateway -External $NetworkExternal

    $buildDir   = (Get-FltComposeBuildDir) -replace '\\', '/'
    $serviceBlocks = [System.Collections.Generic.List[string]]::new()
    $serviceList   = [System.Collections.Generic.List[object]]::new()

    foreach ($row in $rows) {
        $name     = $row.Name.Trim()
        $template = if ($row.PSObject.Properties['Template']) { $row.Template.Trim() } else { 'twincat-xar' }
        $ip       = if ($row.PSObject.Properties['IpAddress']) { $row.IpAddress.Trim() } else { '' }
        $amsNetId = if ($row.PSObject.Properties['AmsNetId'])  { $row.AmsNetId.Trim()  } else { '' }
        $sshPort  = if ($row.PSObject.Properties['SshPort'])   { $row.SshPort.Trim()   } else { '22' }
        $pm       = if ($row.PSObject.Properties['PackageManager'] -and $row.PackageManager.Trim()) {
                        $row.PackageManager.Trim() } else { 'apt' }

        $block = switch ($template) {
            'twincat-xar' {
"  ${name}:
    image: ghcr.io/beckhoff/tcbsd-twincat-xar:latest
    container_name: ${name}
    hostname: ${name}
    restart: unless-stopped
    privileged: true
    volumes:
      - /dev/hugepages:/dev/hugepages:rw
    environment:
      - AMS_NETID=${amsNetId}
      - PCI_DEVICES=NONE
    networks:
      ${NetworkName}:
        ipv4_address: ${ip}"
            }
            'mosquitto' {
"  ${name}:
    image: eclipse-mosquitto:latest
    container_name: ${name}
    hostname: ${name}
    restart: unless-stopped
    ports:
      - `"1883:1883`"
    networks:
      ${NetworkName}:
        ipv4_address: ${ip}"
            }
            'debian-ssh' {
"  ${name}:
    build:
      context: ${buildDir}
      dockerfile: Dockerfile.debian-ssh
      args:
        ROOT_PASSWORD: `${DEBIAN_SSH_ROOT_PASSWORD}
    image: tcflt-debian-ssh:latest
    container_name: ${name}
    hostname: ${name}
    restart: unless-stopped
    ports:
      - `"${sshPort}:22`"
    networks:
      ${NetworkName}:
        ipv4_address: ${ip}"
            }
            default {
                Write-Warning "Unknown template '$template' for row '$name' — skipping"
                $null
            }
        }

        if ($block) {
            $serviceBlocks.Add($block)
            $serviceList.Add([pscustomobject]@{
                Name     = $name
                Template = $template
                SshPort  = $sshPort
                Pm       = $pm
                Ip       = $ip
            })
        }
    }

    if ($serviceBlocks.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; ComposeFile = ''; Services = @()
            Message = "No valid service blocks generated from CSV." }
    }

    $composeDir = Get-FltComposeDir
    if (-not (Test-Path $composeDir)) { New-Item -ItemType Directory -Path $composeDir | Out-Null }
    $outPath = Join-Path $composeDir "$OutputName.yml"

    $yaml = "# Generated by TcFltPkgMgr from CSV: $(Split-Path $CsvPath -Leaf)`n"
    $yaml += "# $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n`n"
    $yaml += "networks:`n  ${NetworkName}:`n    $netDef`n`n"
    $yaml += "services:`n"
    $yaml += ($serviceBlocks -join "`n`n") + "`n"

    try {
        $yaml | Set-Content -Path $outPath -Encoding UTF8 -NoNewline
        return [pscustomobject]@{ Ok = $true; ComposeFile = $outPath
            Services = $serviceList.ToArray()
            Message = "Compose file created: $outPath ($($serviceList.Count) service(s))" }
    } catch {
        return [pscustomobject]@{ Ok = $false; ComposeFile = ''; Services = @()
            Message = "Write failed: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Docker Compose execution
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Runs a docker compose command against a compose file.

.PARAMETER ComposeFile  Absolute or relative path to the compose file.
.PARAMETER ProjectName  --project-name value (derived from filename if empty).
.PARAMETER Verb         compose subcommand: up, down, start, stop, restart, pull, build
.PARAMETER Services     Optional list of service names to scope the command.
.PARAMETER ExtraArgs    Additional arguments appended to the command.
.PARAMETER TimeoutSecs  Command timeout in seconds (default 300).

.OUTPUTS
    [pscustomobject]@{ Ok; ExitCode; Output; Command }
#>
function Invoke-FltComposeCommand {
    param(
        [Parameter(Mandatory)][string]   $ComposeFile,
        [string]   $ProjectName  = '',
        [Parameter(Mandatory)][string]   $Verb,
        [string[]] $Services     = @(),
        [string]   $ExtraArgs    = '',
        [int]      $TimeoutSecs  = 300
    )

    if (-not (Test-Path $ComposeFile)) {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; Output = ''
            Command = ''; Message = "Compose file not found: $ComposeFile" }
    }

    # Derive project name from filename if not supplied
    if ([string]::IsNullOrEmpty($ProjectName)) {
        $ProjectName = [System.IO.Path]::GetFileNameWithoutExtension($ComposeFile).ToLower() `
                       -replace '[^a-z0-9]', ''
    }

    $svcArgs  = if ($Services.Count -gt 0) { ' ' + ($Services -join ' ') } else { '' }
    $extraStr = if ($ExtraArgs) { " $ExtraArgs" } else { '' }
    $cmd      = "docker compose -f `"$ComposeFile`" -p `"$ProjectName`" $Verb$extraStr$svcArgs 2>&1"

    try {
        $output   = (& cmd /c $cmd) -join "`n"
        $exitCode = $LASTEXITCODE
        return [pscustomobject]@{
            Ok       = ($exitCode -eq 0)
            ExitCode = $exitCode
            Output   = $output
            Command  = $cmd
            Message  = if ($exitCode -eq 0) { 'OK' } else { "Exit $exitCode" }
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1
            Output = $_.Exception.Message; Command = $cmd
            Message = $_.Exception.Message }
    }
}

<#
.SYNOPSIS
    Pulls images for services in a compose file.
#>
function Invoke-FltComposePull {
    param(
        [Parameter(Mandatory)][string] $ComposeFile,
        [string]   $ProjectName = '',
        [string[]] $Services    = @()
    )
    Invoke-FltComposeCommand -ComposeFile $ComposeFile -ProjectName $ProjectName `
        -Verb 'pull' -Services $Services
}

<#
.SYNOPSIS
    Starts containers (docker compose up -d). Builds if needed.
#>
function Invoke-FltComposeUp {
    param(
        [Parameter(Mandatory)][string] $ComposeFile,
        [string]   $ProjectName  = '',
        [string[]] $Services     = @(),
        [bool]     $Build        = $false,
        [bool]     $ForceRecreate = $false
    )
    $extra = '-d'
    if ($Build)         { $extra += ' --build' }
    if ($ForceRecreate) { $extra += ' --force-recreate' }
    Invoke-FltComposeCommand -ComposeFile $ComposeFile -ProjectName $ProjectName `
        -Verb 'up' -Services $Services -ExtraArgs $extra -TimeoutSecs 600
}

<#
.SYNOPSIS
    Stops containers.
#>
function Invoke-FltComposeStop {
    param(
        [Parameter(Mandatory)][string] $ComposeFile,
        [string]   $ProjectName = '',
        [string[]] $Services    = @()
    )
    Invoke-FltComposeCommand -ComposeFile $ComposeFile -ProjectName $ProjectName `
        -Verb 'stop' -Services $Services
}