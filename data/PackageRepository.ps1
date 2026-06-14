# =============================================================================
#  TcFltPkgMgr — Package Repository
#  All tcpkg list / show / resolve calls.
#  Returns typed objects. No console output except via the command log.
# =============================================================================

# Parse tcpkg list --as-json output into normalised package objects.
# Handles the Icon field stripping (huge base64 blobs) and schema differences
# between regular list, -i (installed), and -o (upgradable).
function Get-FltPackageList {
    param(
        [string[]] $ListArgs,
        [string]   $RemoteName = ''    # '' = local
    )
    $fail = [pscustomobject]@{ Ok = $false; Items = @(); Columns = @() }
    $exe  = Get-FltTcpkgExe
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { return $fail }

    $fullArgs = $ListArgs + @('--as-json')
    if ($RemoteName) { $fullArgs += '-r', $RemoteName }

    $entry = Start-FltCommandEntry -Command "$exe $($fullArgs -join ' ')" `
                -Target $(if ($RemoteName) { $RemoteName } else { 'local' }) -Mode 'live'

    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $raw  = & $exe @fullArgs 2>&1
    $Script:FltLastExit = $LASTEXITCODE
    $ErrorActionPreference = $prev

    Complete-FltCommandEntry -Entry $entry -ExitCode $Script:FltLastExit -DurationSec 0

    $text = ($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
    # Strip icon blobs before parsing
    $text = [regex]::Replace($text, '"Icon"\s*:\s*"[^"]*"', '"Icon":null')
    $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
    if ($s -lt 0 -or $e -le $s) { return $fail }
    $json = $null
    try { $json = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json } catch { return $fail }

    $items = @($json)
    if ($items.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Items = @(); Columns = @() } }

    $props    = @($items[0].PSObject.Properties.Name)
    $nameProp = if ($props -contains 'Id') { 'Id' } elseif ($props -contains 'Name') { 'Name' } else { $null }
    if (-not $nameProp) { return $fail }

    # Upgradable list (-o) has a different schema
    $isUpgradable = $props -contains 'InstalledVersion' -and $props -contains 'LatestVersion'

    $normalised = @($items | ForEach-Object {
        $obj = $_
        [pscustomobject]@{
            Name             = [string]$obj.$nameProp
            Version          = if ($isUpgradable) { [string]$obj.LatestVersion }
                               elseif ($props -contains 'Version') { [string]$obj.Version }
                               else { '' }
            InstalledVersion = if ($isUpgradable) { [string]$obj.InstalledVersion }
                               elseif ($props -contains 'InstallDate' -and $obj.InstallDate) { [string]$obj.Version }
                               else { '' }
            Source           = if ($props -contains 'Source') { [string]$obj.Source } else { '' }
            IsPreview        = if ($props -contains 'IsPreview') { [bool]$obj.IsPreview } else { $false }
            InstallDate      = if ($props -contains 'InstallDate') { [string]$obj.InstallDate } else { '' }
            Title            = if ($props -contains 'Title') { [string]$obj.Title } else { '' }
        }
    })

    # Build display columns (only include non-empty ones)
    $cols = [System.Collections.Generic.List[hashtable]]::new()
    $cols.Add(@{ Header = 'Name';    Expr = { $_.Name } })
    if ($isUpgradable) {
        $cols.Add(@{ Header = 'Installed'; Expr = { $_.InstalledVersion } })
        $cols.Add(@{ Header = 'Latest';    Expr = { $_.Version } })
    } else {
        if ($normalised | Where-Object { $_.Version }) {
            $cols.Add(@{ Header = 'Version'; Expr = { $_.Version } })
        }
    }
    if ($normalised | Where-Object { $_.Source }) {
        $cols.Add(@{ Header = 'Feed'; Expr = { $_.Source } })
    }

    return [pscustomobject]@{ Ok = $true; Items = $normalised; Columns = $cols.ToArray() }
}

# Build a name→version hashtable of packages installed on a target.
# Used for install-status checks in the cross-target fleet query.
function Get-FltInstalledIndex {
    param([string]$RemoteName = '')
    $args = @('list', '-i')
    $res  = Get-FltPackageList -ListArgs $args -RemoteName $RemoteName
    $idx  = @{}
    if ($res.Ok) {
        foreach ($p in $res.Items) {
            $idx[$p.Name.ToLower()] = $p.Version
        }
    }
    return $idx
}

# Determine install status for one package given its installed index.
function Get-FltPackageStatus {
    param(
        [string]    $PackageName,
        [hashtable] $InstalledIndex,
        [string]    $FeedVersion = ''
    )
    $key  = $PackageName.ToLower()
    $inst = $InstalledIndex[$key]

    if (-not $inst) { return 'not-installed' }
    if (-not $FeedVersion) { return 'up-to-date' }

    try {
        $iv = [System.Version]$inst
        $fv = [System.Version]$FeedVersion
        if     ($iv -eq $fv) { return 'up-to-date' }
        elseif ($iv -lt $fv) { return 'upgradable' }
        else                  { return 'newer-than-feed' }
    } catch {
        return if ($inst -eq $FeedVersion) { 'up-to-date' } else { 'upgradable' }
    }
}

# Fetch all available versions of a package from a feed.
function Get-FltPackageVersions {
    param([string]$PackageName, [string]$FeedFilter = '')
    $exe      = Get-FltTcpkgExe
    $listArgs = @('list', '-a', $PackageName)
    if ($FeedFilter) { $listArgs += '-n', $FeedFilter }
    $listArgs += '--as-json'

    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $raw  = & $exe @listArgs 2>&1
    $ErrorActionPreference = $prev

    $text = ($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
    $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
    if ($s -lt 0 -or $e -le $s) { return @() }
    try {
        $json = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json
        $seen = @{}
        foreach ($j in @($json | Where-Object { $null -ne $_.Version })) {
            $v = [string]$j.Version
            if (-not $seen.ContainsKey($v)) {
                $seen[$v] = if ($j.Source) { [string]$j.Source } else { '' }
            }
        }
        $versions = @($seen.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Version = $_.Key; Source = $_.Value }
        })
        try   { return @($versions | Sort-Object { [System.Version]$_.Version } -Descending) }
        catch { return @($versions | Sort-Object Version -Descending) }
    } catch { return @() }
}