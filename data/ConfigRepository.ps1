# =============================================================================
#  TcFltPkgMgr — Configuration Repository
#  Loads, merges, and exposes config from .default.json + .local.json files.
#  Provides sample-file generation and import/export.
# =============================================================================

# Merge two hashtables recursively — $override values win over $base values.
function Merge-Hashtable {
    param([hashtable]$Base, [hashtable]$Override)
    $result = @{}
    foreach ($key in $Base.Keys) { $result[$key] = $Base[$key] }
    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and
            $result[$key] -is [hashtable] -and
            $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-Hashtable $result[$key] $Override[$key]
        } else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}

# Convert a PSCustomObject graph (from ConvertFrom-Json) to a nested hashtable.
function ConvertTo-Hashtable {
    param($Obj)
    if ($null -eq $Obj)                          { return $null }
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        return @($Obj | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    if ($Obj -is [pscustomobject]) {
        $ht = @{}
        foreach ($prop in $Obj.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $ht
    }
    return $Obj
}

# Load and merge a default JSON file with an optional local override.
function Read-FltJsonConfig {
    param([string]$DefaultPath, [string]$LocalPath)
    $base = @{}
    if (Test-Path $DefaultPath) {
        try { $base = ConvertTo-Hashtable (Get-Content $DefaultPath -Raw | ConvertFrom-Json) }
        catch { Write-Warning "Could not parse $DefaultPath : $_" }
    }
    if (Test-Path $LocalPath) {
        try {
            $local = ConvertTo-Hashtable (Get-Content $LocalPath -Raw | ConvertFrom-Json)
            $base  = Merge-Hashtable $base $local
        }
        catch { Write-Warning "Could not parse $LocalPath : $_" }
    }
    return $base
}

# Safe config value accessor — never throws even if key path doesn't exist.
# Usage: Get-FltCfgValue 'log' 'captureOutput' $false
function Get-FltCfgValue {
    param([string]$Section, [string]$Key, $Default)
    try {
        if ($Script:FltCfg -and
            $Script:FltCfg.ContainsKey($Section) -and
            $Script:FltCfg[$Section].ContainsKey($Key)) {
            return $Script:FltCfg[$Section][$Key]
        }
    } catch {}
    return $Default
}

# Safe tcpkg executable path
function Get-FltTcpkgExe {
    $path = Get-FltCfgValue 'tcpkg' 'executablePath' 'tcpkg'
    if ([string]::IsNullOrWhiteSpace($path)) { return 'tcpkg' }
    return $path
}

# Initialise $Script:FltCfg and $Script:FltFeeds from the config directory.
function Initialize-FltConfig {
    param([string]$ConfigDir)

    # Settings
    $Script:FltCfg = Read-FltJsonConfig `
        (Join-Path $ConfigDir 'settings.default.json') `
        (Join-Path $ConfigDir 'settings.local.json')

    # Feeds — build [FeedDefinition[]] from merged config
    $feedsCfg = Read-FltJsonConfig `
        (Join-Path $ConfigDir 'feeds.default.json') `
        (Join-Path $ConfigDir 'feeds.local.json')

    $Script:FltFeeds = [System.Collections.Generic.List[object]]::new()

    # Beckhoff presets
    if ($feedsCfg.ContainsKey('beckhoff')) {
        foreach ($name in $feedsCfg['beckhoff'].Keys) {
            $f = $feedsCfg['beckhoff'][$name]
            $Script:FltFeeds.Add([FeedDefinition]::new(
                $name, $f['url'], [int]$f['priority'], '', $false))
        }
    }

    # Custom / authenticated feeds
    if ($feedsCfg.ContainsKey('custom')) {
        foreach ($name in $feedsCfg['custom'].Keys) {
            $f   = $feedsCfg['custom'][$name]
            $usr = if ($f.ContainsKey('username')) { $f['username'] } else { '' }
            $Script:FltFeeds.Add([FeedDefinition]::new(
                $name, $f['url'], [int]$f['priority'], $usr, $true))
        }
    }

    $Script:FltConfigDir = $ConfigDir
}

# ── Profile persistence ───────────────────────────────────────────────────────

function Get-FltProfilePath {
    return Join-Path $Script:FltConfigDir 'profiles.json'
}

function Read-FltProfiles {
    $path = Get-FltProfilePath
    if (-not (Test-Path $path)) { return @() }
    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json
        return @($json | ForEach-Object {
            $p = [FleetProfile]::new()
            $p.Name          = $_.Name
            $p.TargetNames   = @($_.TargetNames)
            $p.ExpectedPackages = @($_.ExpectedPackages | ForEach-Object {
                [ProfilePackage]::new($_.Name, $_.Version)
            })
            $p
        })
    } catch {
        Write-Warning "Could not read profiles.json: $_"
        return @()
    }
}

function Save-FltProfiles {
    param([FleetProfile[]]$Profiles)
    $path = Get-FltProfilePath
    $json = @($Profiles | ForEach-Object {
        [pscustomobject]@{
            Name             = $_.Name
            TargetNames      = $_.TargetNames
            ExpectedPackages = @($_.ExpectedPackages | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Version = $_.Version }
            })
        }
    }) | ConvertTo-Json -Depth 5
    Set-Content $path $json -Encoding UTF8
}

# ── Sample file generation ────────────────────────────────────────────────────

function New-FltLocalConfig {
    param([string]$ConfigDir)

    $created = @()

    $feedsLocal    = Join-Path $ConfigDir 'feeds.local.json'
    $settingsLocal = Join-Path $ConfigDir 'settings.local.json'
    $feedsTemplate = Join-Path $ConfigDir 'feeds.default.jsonc'
    $settingsTemplate = Join-Path $ConfigDir 'settings.default.jsonc'

    if (-not (Test-Path $feedsLocal)) {
        if (Test-Path $feedsTemplate) {
            # Strip // comments and write as plain JSON
            $stripped = (Get-Content $feedsTemplate) |
                Where-Object { $_ -notmatch '^\s*//' } |
                Where-Object { $_ -notmatch '^\s*$' }
            Set-Content $feedsLocal ($stripped -join "`n") -Encoding UTF8
        } else {
            Set-Content $feedsLocal '{ "custom": {} }' -Encoding UTF8
        }
        $created += 'feeds.local.json'
    }

    if (-not (Test-Path $settingsLocal)) {
        if (Test-Path $settingsTemplate) {
            $stripped = (Get-Content $settingsTemplate) |
                Where-Object { $_ -notmatch '^\s*//' } |
                Where-Object { $_ -notmatch '^\s*$' }
            Set-Content $settingsLocal ($stripped -join "`n") -Encoding UTF8
        } else {
            Set-Content $settingsLocal '{}' -Encoding UTF8
        }
        $created += 'settings.local.json'
    }

    return $created
}

# ── Import / Export ───────────────────────────────────────────────────────────

# Export local config (no credentials) to a zip archive.
function Export-FltConfig {
    param([string]$DestinationPath)

    $tmpDir  = Join-Path ([System.IO.Path]::GetTempPath()) "TcFltExport_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    try {
        # feeds.local.json — strip username passwords (they stay in Cred Manager)
        $feedsLocal = Join-Path $Script:FltConfigDir 'feeds.local.json'
        if (Test-Path $feedsLocal) {
            $feedsJson = Get-Content $feedsLocal -Raw | ConvertFrom-Json
            # Replace any password fields with a placeholder
            $feedsJson | ConvertTo-Json -Depth 5 |
                Set-Content (Join-Path $tmpDir 'feeds.local.json') -Encoding UTF8
        }

        # settings.local.json — safe to copy as-is
        $settingsLocal = Join-Path $Script:FltConfigDir 'settings.local.json'
        if (Test-Path $settingsLocal) {
            Copy-Item $settingsLocal (Join-Path $tmpDir 'settings.local.json')
        }

        # profiles.json — safe to copy (contains target names, not credentials)
        $profilesPath = Join-Path $Script:FltConfigDir 'profiles.json'
        if (Test-Path $profilesPath) {
            Copy-Item $profilesPath (Join-Path $tmpDir 'profiles.json')
        }

        # Add a README note
        Set-Content (Join-Path $tmpDir 'IMPORT_NOTE.txt') @"
TcFltPkgMgr configuration export
Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')

This archive contains local configuration files (no passwords).
Feed passwords must be re-entered on import and will be stored
in Windows Credential Manager on the target machine.

To import: use TcFltPkgMgr > Config & Setup > Import config.
"@ -Encoding UTF8

        Compress-Archive -Path "$tmpDir\*" -DestinationPath $DestinationPath -Force
        return $true
    } catch {
        Write-Warning "Export failed: $_"
        return $false
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Import config from an exported zip archive, merging with existing local config.
function Import-FltConfig {
    param([string]$ArchivePath)

    if (-not (Test-Path $ArchivePath)) {
        Write-Warning "Archive not found: $ArchivePath"
        return $false
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "TcFltImport_$(Get-Random)"
    try {
        Expand-Archive -Path $ArchivePath -DestinationPath $tmpDir -Force

        $imported = @()
        foreach ($file in @('feeds.local.json','settings.local.json','profiles.json')) {
            $src  = Join-Path $tmpDir $file
            $dest = Join-Path $Script:FltConfigDir $file
            if (Test-Path $src) {
                Copy-Item $src $dest -Force
                $imported += $file
            }
        }
        return $imported
    } catch {
        Write-Warning "Import failed: $_"
        return @()
    } finally {
        Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
