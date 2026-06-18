# =============================================================================
#  WinGet menu flows
#  Install / Upgrade / Uninstall / Status for Windows targets via winget.
#
#  Mirrors PackageMenu.ps1 in structure — substitutes:
#    Search-FltWinGetPackage   for  Get-FltPackageList
#    Get-FltWinGetVersions     for  Get-FltPackageVersions
#    _Invoke-WinGetBatchAction for  _Invoke-FleetBatchAction
#
#  Target filter: only Windows targets with PackageManager = 'winget' or 'both'.
# =============================================================================

# Return the subset of fleet targets that have winget as their effective PM.
function _Get-WinGetTargets {
    $winget = @($Script:FleetTargets | Where-Object {
        (Get-FltEffectivePackageManager $_) -in @('winget', 'both')
    })
    if ($winget.Count -gt 0) { return $winget }

    # Fallback: no targets explicitly configured for winget — offer all Windows targets.
    # Operator can set PackageManager=winget in Setup > target > Edit to suppress this message.
    $windows = @($Script:FleetTargets | Where-Object { $_.OS -eq 'windows' -or $_.OS -eq '' })
    return $windows
}

# ── Batch action orchestration ────────────────────────────────────────────────
# Mirrors _Invoke-FleetBatchAction from PackageMenu.ps1 but routes through
# Invoke-FltWinGetBatch and shows only winget-eligible targets.

function _Invoke-WinGetBatchAction {
    param(
        [string]   $Action,
        [string]   $PackageSpec,
        [object[]] $PreSelected = @()   # if provided, skip target selection
    )

    $wingetTargets = @(_Get-WinGetTargets)
    if ($wingetTargets.Count -eq 0) {
        Write-Host '  No targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    if ($PreSelected.Count -gt 0) {
        $selected = $PreSelected
    } else {
        Show-FleetDashboard -Targets $wingetTargets -LastCommand '' -ResultLines @(
            "Action: $($Action.ToUpper())   Package: $PackageSpec",
            "Select targets — enter numbers separated by commas or spaces, e.g: 11,12  or  11-13"
        )
        $selected = @(Read-FltMultiSelect -Items $wingetTargets -Prompt 'Targets (11+)')
        if ($selected.Count -eq 0) { return }
    }

    $sshCreds = Get-FleetSshCredential -Targets $selected
    if (-not $sshCreds) { return }

    $timeout = Read-FltTimeout -Default ([int]((Get-FltCfgValue 'ssh' 'timeoutSeconds' 1800)))

    Write-Host ''
    Write-Host ("  $($Action.ToUpper()) '$PackageSpec' on $($selected.Count) target(s) via winget.") -ForegroundColor Cyan
    if (-not (Read-FltYesNo -Prompt 'Proceed?')) { return }

    Show-FleetBatchDashboard -Targets $selected -Action $Action -PackageSpec $PackageSpec `
        -Mode 'WinGet SSH' -TimeoutSecs $timeout

    $onProgress = {
        param($dict)
        foreach ($key in @($dict.Keys)) {
            $parts = ($dict[$key]) -split '\|', 3
            $st    = $parts[0]
            $dur   = [double]$parts[1]
            $note  = if ($parts.Count -gt 2) { $parts[2] } else { '' }
            if ($Script:FltBatchStatus.ContainsKey($key)) {
                $cur     = $Script:FltBatchStatus[$key].Status
                $curNote = $Script:FltBatchStatus[$key].Note
                if ($st -ne $cur -or $note -ne $curNote) {
                    Update-FltBatchRow $key $st $dur $note
                }
            }
        }
    }

    $results = Invoke-FltWinGetBatch -Action $Action -PackageSpec $PackageSpec `
                   -Targets $selected -Credential $sshCreds.Credential `
                   -KeyFile $sshCreds.KeyFile -TimeoutSecs $timeout `
                   -OnProgress $onProgress

    foreach ($r in $results) {
        Update-FltBatchRow $r.TargetName $r.Status $r.DurationSec $r.Note
    }

    Write-FltBatchEntry -Action $Action -PackageSpec $PackageSpec -Results $results

    $ok   = @($results | Where-Object { $_.Status -like 'OK*' }).Count
    $skip = @($results | Where-Object { $_.Status -like 'Skipped*' }).Count
    $fail = @($results | Where-Object { $_.Status -like 'Failed*' -or $_.Status -eq 'Timed out' }).Count
    $sumRow = $Script:FltBatchDashHeight - 1
    $sumClr = if ($fail -gt 0) { "`e[91m" } else { "`e[92m" }
    $sumStr = "  Complete: $ok OK  |  $skip skipped  |  $fail failed"
    Write-Host -NoNewline "`e[${sumRow};1H${sumClr}${sumStr}`e[0m`e[K"
    Write-Host -NoNewline "`e[$($Script:FltBatchScrollStart);1H"
    Write-Host ''
    [void](Read-Host '  Batch complete. Press Enter to continue')
}

# ── Install ───────────────────────────────────────────────────────────────────
# Search (winget) → pick package → pick version → select targets → batch.

function Invoke-WinGetInstallMenu {
    Clear-Host
    Write-Host '  WinGet Install' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-FltWinGetAvailable)) {
        Write-Host '  winget is not available on this machine.' -ForegroundColor Yellow
        Write-Host '  Install App Installer from the Microsoft Store to use WinGet search.' -ForegroundColor DarkGray
        Read-Host '  Press Enter'; return
    }

    $term = Read-FltPackageSearch -Prompt 'Package name to install (blank to cancel):'
    if (-not $term) { return }

    Write-Host '  Searching winget...' -ForegroundColor DarkGray
    $res = Search-FltWinGetPackage -SearchTerm $term
    if (-not $res.Ok -or $res.Items.Count -eq 0) {
        Write-Host "  No packages found matching '$term'." -ForegroundColor Yellow
        Read-Host '  Press Enter to continue'; return
    }

    # Filter out Microsoft Store apps — they require an interactive user session
    # with a Microsoft account and cannot be installed headlessly via SSH.
    $wingetOnly = @($res.Items | Where-Object { $_.Source -ne 'msstore' })
    if ($wingetOnly.Count -eq 0) {
        Write-Host "  Only Microsoft Store apps found for '$term'." -ForegroundColor Yellow
        Write-Host '  Store apps cannot be installed via SSH (require interactive login + MS account).' -ForegroundColor DarkGray
        Read-Host '  Press Enter to continue'; return
    }
    if ($wingetOnly.Count -lt $res.Items.Count) {
        $storeCount = $res.Items.Count - $wingetOnly.Count
        Write-Host "  ($storeCount Microsoft Store result(s) hidden — not installable via SSH)" -ForegroundColor DarkGray
    }
    $res = [pscustomobject]@{ Ok = $true; Items = $wingetOnly; Columns = $res.Columns }

    Write-Host '  Results:' -ForegroundColor Cyan
    Show-FltTable -Items $res.Items -Columns $res.Columns -Base 1
    Write-Host '     0. Cancel'; Write-Host ''
    $pkg = Read-FltNumberedChoice -Items $res.Items -Prompt 'Package number' -Base 1
    if (-not $pkg) { return }

    # Pick version — filter out Unknown placeholders
    Write-Host '  Checking versions...' -ForegroundColor DarkGray
    $allVersions = @(Get-FltWinGetVersions -PackageId $pkg.Name)
    $versions    = @($allVersions | Where-Object { $_.Version -and $_.Version -ne 'Unknown' })
    $pkgSpec     = $null

    if ($versions.Count -gt 0) {
        Write-Host ''
        Write-Host "  Versions of $($pkg.Name):" -ForegroundColor Cyan
        Show-FltTable -Items $versions -Columns @(
            @{ Header = 'Version'; Expr = { $_.Version } }
            @{ Header = 'Source';  Expr = { $_.Source  } }
        ) -Base 1
        $latestNum = $versions.Count + 1
        Write-Host ("  {0,4}. Latest (let winget decide)" -f $latestNum)
        Write-Host '     0. Cancel'
        Write-Host ''
        $vChoice = (Read-Host '  Choice').Trim()
        if ($vChoice -eq '0' -or [string]::IsNullOrWhiteSpace($vChoice)) { return }
        if ($vChoice -match '^\d+$') {
            $vn = [int]$vChoice
            if      ($vn -ge 1 -and $vn -le $versions.Count) { $pkgSpec = "$($pkg.Name) --version $($versions[$vn-1].Version)" }
            elseif  ($vn -eq $latestNum)                      { $pkgSpec = $pkg.Name }
            else    { return }
        } else { return }
    } else {
        # No enumerable versions (Store apps or package without version listing)
        # Skip version picker — use Latest directly
        Write-Host "  (No version list available — will install latest)" -ForegroundColor DarkGray
        $pkgSpec = $pkg.Name
    }

    _Invoke-WinGetBatchAction -Action 'install' -PackageSpec $pkgSpec
}

# ── Upgrade ───────────────────────────────────────────────────────────────────
# Search → pick package → select targets → batch.

function Invoke-WinGetUpgradeMenu {
    Clear-Host
    Write-Host '  WinGet Upgrade' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-FltWinGetAvailable)) {
        Write-Host '  winget is not available on this machine.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    $term = Read-FltPackageSearch -Prompt 'Package name to upgrade (blank to cancel):'
    if (-not $term) { return }

    Write-Host '  Searching winget...' -ForegroundColor DarkGray
    $res = Search-FltWinGetPackage -SearchTerm $term
    if (-not $res.Ok -or $res.Items.Count -eq 0) {
        Write-Host "  No packages found matching '$term'." -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }
    $wingetOnly = @($res.Items | Where-Object { $_.Source -ne 'msstore' })
    if ($wingetOnly.Count -eq 0) {
        Write-Host "  Only Microsoft Store apps found — not upgradeable via SSH." -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }
    $res = [pscustomobject]@{ Ok = $true; Items = $wingetOnly; Columns = $res.Columns }

    Show-FltTable -Items $res.Items -Columns $res.Columns -Base 1
    Write-Host '     0. Cancel'; Write-Host ''
    $pkg = Read-FltNumberedChoice -Items $res.Items -Prompt 'Package number' -Base 1
    if (-not $pkg) { return }

    _Invoke-WinGetBatchAction -Action 'upgrade' -PackageSpec $pkg.Name
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
# Select target first → query what's installed → pick from installed list → batch.

function Invoke-WinGetUninstallMenu {
    Clear-Host
    Write-Host '  WinGet Uninstall' -ForegroundColor Cyan
    Write-Host ''

    $wingetTargets = @(_Get-WinGetTargets)
    if ($wingetTargets.Count -eq 0) {
        Write-Host '  No targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    # Select a single target to query installed packages from
    Show-FleetDashboard -Targets $wingetTargets -LastCommand '' -ResultLines @(
        'Uninstall — select ONE target to query installed packages:'
    )
    $selected = @(Read-FltMultiSelect -Items $wingetTargets -Prompt 'Target (11+)')
    if ($selected.Count -eq 0) { return }
    $queryTarget = $selected[0]

    # Get SSH credentials for the query target
    $sshCreds = Get-FleetSshCredential -Targets @($queryTarget)
    if (-not $sshCreds) { return }

    # Query installed packages on target via winget list
    Clear-Host
    Write-Host "  WinGet Uninstall — querying installed packages on $($queryTarget.Name)..." -ForegroundColor Cyan
    Write-Host ''

    $installed = @()
    try {
        $useKey = -not [string]::IsNullOrWhiteSpace($sshCreds.KeyFile)
        $sParams = @{
            ComputerName = $queryTarget.Address
            Port         = [int]$queryTarget.Port
            AcceptKey    = $true
            ErrorAction  = 'Stop'
        }
        if ($useKey) { $sParams['Username'] = $queryTarget.User; $sParams['KeyFile'] = $sshCreds.KeyFile }
        else          { $sParams['Credential'] = $sshCreds.Credential }

        $session = New-SSHSession @sParams
        $listRes = Invoke-SSHCommand -SessionId $session.SessionId `
                       -Command 'pwsh -NoProfile -NonInteractive -Command "winget list --accept-source-agreements --disable-interactivity | Out-String -Width 300" 2>&1' `
                       -TimeOut 60
        Remove-SSHSession -SessionId $session.SessionId | Out-Null

        $lines = @($listRes.Output | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
        $parsed = _Parse-WinGetTable -Lines $lines
        if ($parsed.Ok) {
            # Filter to manageable packages only:
            # - Exclude ARP registry entries (not winget-managed)
            # - Exclude MSIX system entries
            # - Exclude rows where Name was truncated and Id is a version number
            #   (winget truncates long names with … causing Id/Version columns to shift)
            $installed = @($parsed.Items | Where-Object {
                $_.Name -and
                $_.Name.Trim() -ne '' -and
                $_.Name -notmatch '^ARP\\' -and
                $_.Name -notmatch '^MSIX\\' -and
                $_.Name -notmatch '^\d' -and        # Id starting with digit = version number, not a real Id
                $_.Name -notmatch '^>'              # Id starting with > = truncated version comparison
            })
        }
    } catch {
        Write-Host "  SSH error: $($_.Exception.Message)" -ForegroundColor Red
        Read-Host '  Press Enter'; return
    }

    if ($installed.Count -eq 0) {
        Write-Host "  No packages found on $($queryTarget.Name)." -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    # Optional filter
    Write-Host "  $($installed.Count) installed packages. Filter (blank = show all):" -ForegroundColor Cyan
    $filter = (Read-Host '  Filter').Trim()
    if ($filter) {
        $installed = @($installed | Where-Object {
            $_.Name -match [regex]::Escape($filter) -or $_.Title -match [regex]::Escape($filter)
        })
        if ($installed.Count -eq 0) {
            Write-Host "  No packages matching '$filter'." -ForegroundColor Yellow
            Read-Host '  Press Enter'; return
        }
    }

    Write-Host ''
    Show-FltTable -Items $installed -Columns @(
        @{ Header = 'Name';    Expr = { $_.Title } }
        @{ Header = 'Id';      Expr = { $_.Name } }
        @{ Header = 'Version'; Expr = { $_.Version } }
    ) -Base 1
    Write-Host '     0. Cancel'; Write-Host ''
    $pkg = Read-FltNumberedChoice -Items $installed -Prompt 'Package number' -Base 1
    if (-not $pkg) { return }

    # Now select all targets to uninstall from (default to same target, but allow more)
    Write-Host ''
    Write-Host "  Uninstall '$($pkg.Name)' from which targets?" -ForegroundColor Cyan
    Show-FleetDashboard -Targets $wingetTargets -LastCommand '' -ResultLines @(
        "Uninstall: $($pkg.Name)   (queried from $($queryTarget.Name))",
        'Select targets to uninstall from:'
    )
    $uninstTargets = @(Read-FltMultiSelect -Items $wingetTargets -Prompt 'Targets (11+)')
    if ($uninstTargets.Count -eq 0) { return }

    _Invoke-WinGetBatchAction -Action 'uninstall' -PackageSpec $pkg.Name -PreSelected $uninstTargets
}

# ── Status ────────────────────────────────────────────────────────────────────
# Show whether a package is installed on each WinGet target.

function Invoke-WinGetStatusMenu {
    Clear-Host
    Write-Host '  WinGet Package Status' -ForegroundColor Cyan
    Write-Host ''

    $wingetTargets = @(_Get-WinGetTargets)
    if ($wingetTargets.Count -eq 0) {
        Write-Host '  No targets configured.' -ForegroundColor Yellow
        Read-Host '  Press Enter'; return
    }

    $pkgId = Read-FltPackageSearch -Prompt 'Package id (exact winget id, blank to cancel):'
    if (-not $pkgId) { return }

    # Get credentials before launching parallel jobs
    $sshCreds = Get-FleetSshCredential -Targets $wingetTargets
    if (-not $sshCreds) { return }

    Write-Host '  Querying targets...' -ForegroundColor DarkGray
    Write-Host ''

    # Query each target in parallel using SSH
    $jobs = foreach ($tgt in $wingetTargets) {
        $t    = $tgt
        $cred = $sshCreds.Credential
        $kf   = $sshCreds.KeyFile
        Start-ThreadJob -ScriptBlock {
            param($target, $id, $credential, $keyFile)
            $ErrorActionPreference = 'SilentlyContinue'
            try {
                Import-Module Posh-SSH -ErrorAction Stop
                $useKey = -not [string]::IsNullOrWhiteSpace($keyFile)
                $sParams = @{
                    ComputerName = $target.Address
                    Port         = [int]$target.Port
                    AcceptKey    = $true
                    ErrorAction  = 'Stop'
                }
                if ($useKey) { $sParams['Username'] = $target.User; $sParams['KeyFile'] = $keyFile }
                else          { $sParams['Credential'] = $credential }

                $session = New-SSHSession @sParams
                # Wrap in pwsh to suppress PTY-triggered progress animation
                $cmd = "pwsh -NoProfile -NonInteractive -Command `"winget list --id '$id' --accept-source-agreements --disable-interactivity | Out-String -Width 200`""
                $r   = Invoke-SSHCommand -SessionId $session.SessionId -Command $cmd -TimeOut 30
                $out = ($r.Output -join ' ')
                Remove-SSHSession -SessionId $session.SessionId | Out-Null

                if ($out -match [regex]::Escape($id)) {
                    # Extract version — use -split for thread safety (avoid $Matches)
                    $parts = $out -split '\s+' | Where-Object { $_ -match '^\d+\.\d+[\.\d]*$' }
                    $ver   = if ($parts) { $parts[0] } else { '?' }
                    [pscustomobject]@{ Name = $target.Name; Status = 'Installed'; Version = $ver }
                } else {
                    [pscustomobject]@{ Name = $target.Name; Status = 'Not installed'; Version = '' }
                }
            } catch {
                [pscustomobject]@{ Name = $target.Name; Status = 'SSH error'; Version = $_.Exception.Message.Split("`n")[0] }
            }
        } -ArgumentList $t, $pkgId, $cred, $kf
    }

    $results = @($jobs | Wait-Job | Receive-Job)
    $jobs | Remove-Job

    # Display results
    $w = [Math]::Max([Console]::WindowWidth, 60) - 1
    Write-Host ('  {0,-30} {1,-16} {2}' -f 'Target', 'Status', 'Version') -ForegroundColor DarkGray
    Write-Host ('  ' + '-' * ($w - 2)) -ForegroundColor DarkGray

    foreach ($r in $results | Sort-Object Name) {
        $clr = switch ($r.Status) {
            'Installed'     { 'Green'  }
            'Not installed' { 'DarkGray' }
            default         { 'Red'    }
        }
        Write-Host ('  {0,-30} ' -f $r.Name) -NoNewline
        Write-Host ('{0,-16} ' -f $r.Status) -ForegroundColor $clr -NoNewline
        Write-Host $r.Version -ForegroundColor DarkGray
    }

    Write-Host ''
    Read-Host '  Press Enter'
}