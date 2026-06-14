# =============================================================================
#  TcFltPkgMgr — Fleet Query
#  Cross-target queries that run in parallel via ForEach-Object -Parallel.
#  Returns [FleetPackageSummary] objects. The fleet home screen and
#  package status view both call these functions.
# =============================================================================

# Query the install status of one package across all fleet targets in parallel.
# This is the core fleet query — the answer to "what version is on each machine?"
function Get-FleetPackageStatus {
    param(
        [string]        $PackageName,
        [FleetTarget[]] $Targets,
        [string]        $FeedVersion = '',  # from the feed; '' means skip feed comparison
        [string]        $FeedSource  = ''
    )
    $exe        = Get-FltTcpkgExe
    $pkgLower   = $PackageName.ToLower()
    $throttle   = [int]((Get-FltCfgValue 'ssh' 'throttleLimit' 10))

    $rawStates = @($Targets | ForEach-Object -Parallel {
        $target    = $_
        $exe       = $using:exe
        $pkgLower  = $using:pkgLower
        $feedVer   = $using:FeedVersion

        $instVer = ''
        $status  = 'unknown'

        try {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            $raw  = & $exe list '-i', $pkgLower, '--exact', '-r', $target.Name, '--as-json' 2>&1
            $ErrorActionPreference = $prev

            $text = ($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
            $text = [regex]::Replace($text, '"Icon"\s*:\s*"[^"]*"', '"Icon":null')
            $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
            if ($s -ge 0 -and $e -gt $s) {
                $json = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json
                $match = @($json) | Where-Object {
                    $_.Id -like "*$pkgLower*" -or $_.Name -like "*$pkgLower*"
                } | Select-Object -First 1
                if ($match) {
                    $instVer = [string]$match.Version
                }
            }
        } catch {}

        if (-not $instVer) {
            $status = 'not-installed'
        } elseif (-not $feedVer) {
            $status = 'up-to-date'
        } else {
            try {
                $iv = [System.Version]$instVer
                $fv = [System.Version]$feedVer
                $status = if ($iv -eq $fv) { 'up-to-date' }
                          elseif ($iv -lt $fv) { 'upgradable' }
                          else { 'newer-than-feed' }
            } catch {
                $status = if ($instVer -eq $feedVer) { 'up-to-date' } else { 'upgradable' }
            }
        }

        [pscustomobject]@{
            TargetName       = $target.Name
            InstalledVersion = $instVer
            Status           = $status
        }
    } -ThrottleLimit $throttle)

    # Build [FleetPackageSummary] preserving the original target order
    $summary = [FleetPackageSummary]::new()
    $summary.PackageName = $PackageName
    $summary.FeedVersion = $FeedVersion
    $summary.FeedSource  = $FeedSource

    $stateMap = @{}
    foreach ($r in $rawStates) { $stateMap[$r.TargetName] = $r }

    $summary.States = @($Targets | ForEach-Object {
        $t  = $_
        $r  = $stateMap[$t.Name]
        $ps = [PackageState]::new($t.Name, $PackageName)
        if ($r) {
            $ps.InstalledVersion = $r.InstalledVersion
            $ps.FeedVersion      = $FeedVersion
            $ps.Status           = $r.Status
        } else {
            $ps.Status = 'unknown'
        }
        $ps
    })

    # Log the fleet query result
    Write-FltFleetQueryEntry -Summary $summary

    return $summary
}

# Check which packages on a fleet of targets are outdated (upgradable).
# Returns a hashtable: PackageName -> FleetPackageSummary
function Get-FleetOutdated {
    param([FleetTarget[]]$Targets)
    $exe      = Get-FltTcpkgExe
    $throttle = [int]((Get-FltCfgValue 'ssh' 'throttleLimit' 10))

    # Fetch upgradable list from each target in parallel
    $perTarget = @($Targets | ForEach-Object -Parallel {
        $target = $_
        $exe    = $using:exe
        $items  = @()
        try {
            $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            $raw  = & $exe list '-o', '-r', $target.Name, '--as-json' 2>&1
            $ErrorActionPreference = $prev
            $text = ($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
            $s = $text.IndexOf('['); $e = $text.LastIndexOf(']')
            if ($s -ge 0 -and $e -gt $s) {
                $json = $text.Substring($s, $e - $s + 1) | ConvertFrom-Json
                $items = @($json | ForEach-Object {
                    [pscustomobject]@{
                        Name      = [string]$_.Id
                        Installed = [string]$_.InstalledVersion
                        Latest    = [string]$_.LatestVersion
                        Source    = [string]$_.Source
                    }
                })
            }
        } catch {}
        [pscustomobject]@{ Target = $target.Name; Items = $items }
    } -ThrottleLimit $throttle)

    # Aggregate by package name
    $byPackage = @{}
    foreach ($result in $perTarget) {
        foreach ($item in $result.Items) {
            if (-not $byPackage.ContainsKey($item.Name)) {
                $summary = [FleetPackageSummary]::new()
                $summary.PackageName = $item.Name
                $summary.FeedVersion = $item.Latest
                $summary.FeedSource  = $item.Source
                $summary.States      = @()
                $byPackage[$item.Name] = $summary
            }
            $ps = [PackageState]::new($result.Target, $item.Name)
            $ps.InstalledVersion = $item.Installed
            $ps.FeedVersion      = $item.Latest
            $ps.Status           = 'upgradable'
            $byPackage[$item.Name].States += $ps
        }
    }

    return $byPackage
}

# Compare a fleet profile's expected packages against actual installed versions.
# Returns an array of pscustomobject @{ Package; Target; Expected; Installed; Status }
function Compare-FleetProfile {
    param(
        [FleetProfile]  $Profile,
        [FleetTarget[]] $AllTargets
    )
    $targets = @($AllTargets | Where-Object { $Profile.TargetNames -contains $_.Name })
    $diffs   = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($pkg in $Profile.ExpectedPackages) {
        $summary = Get-FleetPackageStatus -PackageName $pkg.Name -Targets $targets `
                       -FeedVersion $pkg.Version

        foreach ($state in $summary.States) {
            if ($state.Status -ne 'up-to-date') {
                $diffs.Add([pscustomobject]@{
                    Package   = $pkg.Name
                    Target    = $state.TargetName
                    Expected  = $pkg.Version
                    Installed = $state.InstalledVersion
                    Status    = $state.Status
                })
            }
        }
    }
    return $diffs.ToArray()
}