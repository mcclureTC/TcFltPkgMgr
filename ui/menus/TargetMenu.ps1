# =============================================================================
#  TcFltPkgMgr — Target / Source / Profile / Setup Menus
# =============================================================================

# ── Target Menu ───────────────────────────────────────────────────────────────

function Invoke-TargetMenu {
    param([FleetTarget]$Target = $null)

    if ($Target) {
        # Edit an existing target
        Clear-Host
        Write-Host ("  Editing '$($Target.Name)' — blank keeps current value.") -ForegroundColor Cyan
        Write-Host ''
        $newName = Read-FltValue "  Name   ($($Target.Name)):"   -AllowEmpty
        $newHost = Read-FltValue "  Host   ($($Target.Address)):"   -AllowEmpty
        $newPort = Read-FltValue "  Port   ($($Target.Port)):"   -AllowEmpty
        $newUser = Read-FltValue "  User   ($($Target.User)):"   -AllowEmpty

        $plainPwd = ''
        if (Read-FltYesNo -Prompt 'Update password?') {
            $plainPwd = (Read-Host '  New password').Trim()
        }

        $newIA = $null
        if (Read-FltYesNo -Prompt 'Update Internet Access setting?') {
            $newIA = Read-FltYesNo -Prompt 'Does this target have its own Internet Access?'
        }

        $ok = Edit-FleetTarget -Name $Target.Name `
                  -NewName   $newName -NewHost $newHost `
                  -NewPort   (if ($newPort -match '^\d+$') { [int]$newPort } else { 0 }) `
                  -NewUser   $newUser -PlainPassword $plainPwd -InternetAccess $newIA
        Write-Host $(if ($ok) { "  Updated '$($Target.Name)'." } else { "  Update failed." }) `
            -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
        Read-Host '  Press Enter'
        return
    }

    # Add new target
    Clear-Host
    Write-Host '  Add New Target' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Target type:' -ForegroundColor Cyan
    Write-Host '   1. Physical machine'
    Write-Host '   2. Virtual machine'
    Write-Host '   3. Docker container'
    Write-Host '   0. Cancel'
    Write-Host ''
    $typeChoice = (Read-Host '  Type').Trim()
    if ($typeChoice -eq '0' -or [string]::IsNullOrEmpty($typeChoice)) { return }

    $targetType = switch ($typeChoice) {
        '1' { 'physical' }
        '2' { 'vm'       }
        '3' { 'container' }
        default { 'physical' }
    }

    $name = Read-FltValue 'Name (blank to cancel):' -CancelOnBlank; if (-not $name) { return }

    # ── Container target flow ──────────────────────────────────────────────────
    if ($targetType -eq 'container') {
        Clear-Host
        Write-Host '  Add New Target  >  Docker Container' -ForegroundColor Cyan
        Write-Host ''

        # Show existing non-container targets as Docker host candidates
        $hostCandidates = @($Script:FleetTargets | Where-Object { $_.TargetType -ne 'container' })
        if ($hostCandidates.Count -gt 0) {
            Write-Host '  Available Docker hosts:' -ForegroundColor DarkGray
            foreach ($h in $hostCandidates) {
                Write-Host "    $($h.Name)  ($($h.Address))" -ForegroundColor DarkGray
            }
            Write-Host ''
        }

        $dockerHostName = Read-FltValue 'Docker host target name (blank to cancel):' -CancelOnBlank
        if (-not $dockerHostName) { return }

        # Validate Docker host exists in fleet
        $hostTarget = $Script:FleetTargets | Where-Object { $_.Name -eq $dockerHostName } | Select-Object -First 1
        if (-not $hostTarget) {
            Write-Host "  Target '$dockerHostName' not found in fleet." -ForegroundColor Red
            Write-Host '  Add the Docker host target first via Setup > Add target.' -ForegroundColor DarkGray
            Read-Host '  Press Enter'
            return
        }
        if ($hostTarget.TargetType -eq 'container') {
            Write-Host "  '$dockerHostName' is itself a container — Docker hosts must be physical or VM targets." -ForegroundColor Red
            Read-Host '  Press Enter'
            return
        }

        $containerName = Read-FltValue 'Container name (e.g. web_app, blank to cancel):' -CancelOnBlank
        if (-not $containerName) { return }

        Write-Host ''
        Write-Host '  Package manager:' -ForegroundColor Cyan
        Write-Host '   1. apt  (Debian/Ubuntu — default)'
        Write-Host '   2. apk  (Alpine)'
        Write-Host '   3. yum  (RHEL/CentOS)'
        Write-Host '   4. dnf  (Fedora/RHEL 8+)'
        Write-Host ''
        $pmChoice = (Read-Host '  Choice (blank = apt)').Trim()
        $pm = switch ($pmChoice) {
            '2' { 'apk' }
            '3' { 'yum' }
            '4' { 'dnf' }
            default { 'apt' }
        }

        # Container inherits address/port/user from Docker host
        $t = [FleetTarget]::new($name, $hostTarget.Address, $hostTarget.Port, $hostTarget.User, $false)
        $t.OS             = 'linux'
        $t.TargetType     = 'container'
        $t.PackageManager = $pm
        $t.DockerHost     = $dockerHostName
        $t.ContainerName  = $containerName
        $t.InternetAccess = $false   # containers don't get their own internet access flag
        $t.Reachable      = 'unknown'

        $existing = $Script:FleetTargets | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($existing) {
            Write-Host "  A target named '$name' already exists." -ForegroundColor Red
            Read-Host '  Press Enter'
            return
        }

        $Script:FleetTargets += $t
        $ok = Save-FltTargets -Targets $Script:FleetTargets
        if ($ok) {
            Write-Host "  Added container '$name' on '$dockerHostName' ($containerName) using $pm." -ForegroundColor Green
        } else {
            Write-Host "  Failed to save target." -ForegroundColor Red
        }
        Read-Host '  Press Enter'
        return
    }

    # ── Physical / VM target flow ──────────────────────────────────────────────
    $hostAddr = Read-FltValue 'Host address (blank to cancel):' -CancelOnBlank; if (-not $hostAddr) { return }
    $port = Read-FltValue 'Port (blank = 22):' -AllowEmpty
    if (-not $port) { $port = '22' }
    $user = Read-FltValue 'User (blank to cancel):' -CancelOnBlank; if (-not $user) { return }

    Write-Host ''
    Write-Host '  Auth method:' -ForegroundColor Cyan
    Write-Host '   1. Password'
    Write-Host '   2. Private key file'
    Write-Host '   0. Cancel'
    Write-Host ''
    $authChoice = (Read-Host '  Choice').Trim()
    if ($authChoice -eq '0') { return }

    $plainPwd = ''; $keyFile = ''
    if ($authChoice -eq '1') {
        $plainPwd = (Read-Host '  Password').Trim()
    } elseif ($authChoice -eq '2') {
        $keyFile = Read-FltValue 'Key file path (blank to cancel):' -CancelOnBlank
        if (-not $keyFile) { return }
    }

    $ia = Read-FltYesNo -Prompt 'Does this target have its own Internet Access?'

    # Set OS based on target type
    $os = if ($targetType -in @('physical','vm')) { 'windows' } else { 'linux' }

    $ok = Add-FleetTarget -Name $name -HostAddress $hostAddr -Port ([int]$port) -User $user `
              -PlainPassword $plainPwd -KeyFile $keyFile -InternetAccess $ia

    if ($ok) {
        # Update OS and TargetType on the newly added target
        $newTgt = $Script:FleetTargets | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($newTgt) {
            $newTgt.TargetType = $targetType
            Save-FltTargets -Targets $Script:FleetTargets | Out-Null
        }
    }

    Write-Host $(if ($ok) { "  Added '$name'." } else { "  Add failed (exit $Script:FltLastExit)." }) `
        -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    Write-Host "  Command: $Script:FltLastCmd" -ForegroundColor DarkGray
    Read-Host '  Press Enter'
}

# ── Source Menu ───────────────────────────────────────────────────────────────

function Get-FltSources {
    $raw  = Invoke-FltTcpkg -ArgList @('source','list','--as-json') -Silent
    $json = ConvertFrom-FltTcpkgJson $raw
    if (-not $json) { return @() }
    return @($json | ForEach-Object {
        [pscustomobject]@{
            Pri   = if ($null -ne $_.Priority) { [int]$_.Priority }  else { 0  }
            Name  = if ($null -ne $_.Name)     { [string]$_.Name }   else { '' }
            State = if ($_.Enabled)            { 'enabled' }         else { 'disabled' }
            Auth  = if ($_.User)               { [string]$_.User }   else { 'none' }
            Url   = if ($null -ne $_.Source)   { [string]$_.Source } else { '' }
        }
    } | Sort-Object Pri)
}

# Standalone Sources/Feeds screen. Shows all tcpkg sources with live state.
# Allows enabling/disabling sources and adding Beckhoff presets or custom feeds.
function Invoke-FleetSourceMenu {
    $sources = Get-FltSources
    $lastCmd = ''
    $result  = ''

    while ($true) {
        Show-SourcesDashboard -Sources $sources -LastCommand $lastCmd -ResultLine $result
        $result = ''

        $choice = (Read-Host '  Choice').Trim()

        if ($choice -eq '0') { return }

        # 11+ toggles enable/disable by row number
        if ($choice -match '^\d+$' -and [int]$choice -ge 11) {
            $idx = [int]$choice - 11
            if ($idx -lt $sources.Count) {
                $s      = $sources[$idx]
                $enable = $s.State -ne 'enabled'
                $val    = if ($enable) { 'true' } else { 'false' }
                Invoke-FltTcpkg -ArgList @('source','edit',$s.Name,'--enabled',$val,'-y') | Out-Null
                $lastCmd = $Script:FltLastCmd
                $result  = if ($Script:FltLastExit -eq 0) {
                    "$($s.Name) $(if ($enable) { 'enabled' } else { 'disabled' })"
                } else { "Failed (exit $Script:FltLastExit)" }
                $sources = Get-FltSources
            } else {
                $result = "No source at position $choice (idx=$idx count=$($sources.Count))"
            }
            continue
        }

        if ($choice -eq '1') {
            # Add Beckhoff preset — show numbered list, pick by number
            $feeds = @($Script:FltFeeds | Where-Object { -not $_.IsCustom } | Sort-Object Priority)
            if ($feeds.Count -eq 0) {
                $result = 'No Beckhoff presets found in feeds config'
                continue
            }
            Show-SourcesDashboard -Sources $sources -LastCommand $lastCmd -ResultLine 'Select a Beckhoff preset feed:'
            for ($fi = 0; $fi -lt $feeds.Count; $fi++) {
                Write-Host ('  {0,3}. {1}' -f (21 + $fi), $feeds[$fi].Name) -ForegroundColor Cyan
            }
            Write-Host '    0. Cancel' -ForegroundColor DarkGray
            $pick = (Read-Host '  Feed number').Trim()
            if ($pick -eq '0' -or -not $pick) { continue }
            if (-not ($pick -match '^\d+$') -or [int]$pick -lt 21 -or [int]$pick -gt (20 + $feeds.Count)) {
                $result = "Invalid selection '$pick'"; continue
            }
            $feed = $feeds[[int]$pick - 21]
            Show-SourcesDashboard -Sources $sources -LastCommand $lastCmd -ResultLine "Username for '$($feed.Name)' (blank to cancel):"
            $user = (Read-Host '  Username').Trim()
            if (-not $user) { continue }
            $exe = Get-FltTcpkgExe

            # Step 1: run tcpkg interactively — it handles password prompt + disclaimer in console
            Clear-Host
            Write-Host "  Adding '$($feed.Name)' — tcpkg will prompt for password then disclaimer." -ForegroundColor Cyan
            Write-Host ''
            $addArgs = @('source','add','-n',$feed.Name,'-s',$feed.Url,'--priority','99','-u',$user)
            & $exe @addArgs
            $exitCode = $LASTEXITCODE
            $lastCmd  = "tcpkg source add -n $($feed.Name) --priority 99 -u $user"
            Write-Host ''

            if ($exitCode -ne 0) {
                $result  = "Add failed (exit $exitCode)"
                $sources = Get-FltSources
                continue
            }

            # Step 2: set password non-interactively via source edit --password-stdin
            # (no disclaimer re-prompt after acceptance in step 1)
            $pwd = Resolve-FltPassword -CredentialName "feed_$($feed.Name)" `
                       -PromptLabel "Password for '$($feed.Name)' (to store encrypted):" -OfferToSave
            $editArgs = @('source','edit',$feed.Name,'-u',$user,'-s',$feed.Url,'--password-stdin')
            $exitCode = Invoke-FltWithStdin -Exe $exe -ArgList $editArgs -StdinText "$pwd`n"
            $lastCmd  = "tcpkg source edit $($feed.Name) -u $user --password-stdin"

            if ($exitCode -eq 0) {
                $sources = Get-FltSources
                Repair-FltSourcePriorities -Sources $sources
                $sources = Get-FltSources
                $result  = "Added: $($feed.Name) — priorities renumbered"
            } else {
                $result  = "Source added but credential update failed (exit $exitCode)"
                if ($Script:FltLastStdinErr) { $result += " — $Script:FltLastStdinErr" }
                $sources = Get-FltSources
            }
            continue
        }

        if ($choice -eq '2') {
            Show-SourcesDashboard -Sources $sources -LastCommand $lastCmd -ResultLine 'Source name (blank to cancel):'
            $name = (Read-Host '  Name').Trim(); if (-not $name) { continue }
            Show-SourcesDashboard -Sources $sources -LastCommand $lastCmd -ResultLine 'Feed URL (blank to cancel):'
            $url  = (Read-Host '  URL').Trim();  if (-not $url)  { continue }
            Show-SourcesDashboard -Sources $sources -LastCommand $lastCmd -ResultLine 'Username (blank = unauthenticated):'
            $user = (Read-Host '  Username').Trim()
            $exe2 = Get-FltTcpkgExe

            # Step 1: run tcpkg interactively — handles password prompt + disclaimer in console
            $addArgs = @('source','add','-n',$name,'-s',$url,'--priority','99')
            if ($user) { $addArgs += '-u',$user }
            Clear-Host
            Write-Host "  Adding '$name' — tcpkg will prompt for password$(if ($user) {' and'} else {' or'}) disclaimer." -ForegroundColor Cyan
            Write-Host ''
            & $exe2 @addArgs
            $Script:FltLastExit = $LASTEXITCODE
            $lastCmd = "tcpkg source add -n $name --priority 99$(if ($user) { " -u $user" } else { '' })"
            Write-Host ''

            if ($Script:FltLastExit -ne 0) {
                $result  = "Add failed (exit $Script:FltLastExit)"
                $sources = Get-FltSources
                continue
            }

            # Step 2: store password non-interactively if authenticated
            if ($user) {
                $pwd = Resolve-FltPassword -CredentialName "feed_$name" `
                           -PromptLabel "Password for '$name' (to store encrypted):" -OfferToSave
                $editArgs = @('source','edit',$name,'-u',$user,'-s',$url,'--password-stdin')
                $Script:FltLastExit = Invoke-FltWithStdin -Exe $exe2 -ArgList $editArgs -StdinText "$pwd`n"
                if ($Script:FltLastExit -ne 0) {
                    $result  = "Source added but credential update failed (exit $Script:FltLastExit)"
                    if ($Script:FltLastStdinErr) { $result += " — $Script:FltLastStdinErr" }
                    $sources = Get-FltSources
                    continue
                }
            }

            $sources = Get-FltSources
            Repair-FltSourcePriorities -Sources $sources
            $sources = Get-FltSources
            $result  = "Added: $name — priorities renumbered"
            continue
        }

        $result = 'Enter 11+ to toggle a source, 1 to add Beckhoff preset, 2 to add custom, 0 to go back.'
    }
}

# ── Profile Menu ──────────────────────────────────────────────────────────────

function Invoke-ProfileMenu {
    while ($true) {
        Clear-Host
        Write-Host '  Fleet Profiles' -ForegroundColor Cyan
        Write-Host ''
        $profiles = @(Read-FltProfiles)
        if ($profiles.Count -gt 0) {
            Show-FltTable -Items $profiles -Columns @(
                @{ Header = 'Profile'; Expr = { $_.Name } },
                @{ Header = 'Targets'; Expr = { $_.TargetNames -join ', ' } },
                @{ Header = 'Packages'; Expr = { $_.ExpectedPackages.Count } }
            )
        } else {
            Write-Host '  No profiles configured.' -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-Host '   1. New profile'
        Write-Host '   2. Compare profile to fleet'
        Write-Host '   3. Apply profile to fleet'
        Write-Host '   4. Delete profile'
        Write-Host '   0. Back'
        Write-Host ''
        $choice = (Read-Host '  Choice').Trim()
        if ($choice -eq '0') { return }

        if ($choice -eq '1') {
            Write-Host ''
            $name = Read-FltValue 'Profile name (blank to cancel):' -CancelOnBlank
            if (-not $name) { continue }

            Write-Host '  Targets for this profile (names, comma-separated):'
            $Script:FleetTargets | ForEach-Object { Write-Host "    $($_.Name)" }
            $tRaw    = (Read-Host '  Target names').Trim()
            $tNames  = @($tRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

            $pkgs = [System.Collections.Generic.List[object]]::new()
            Write-Host '  Add expected packages (name=version, blank to finish):'
            while ($true) {
                $p = (Read-Host '  Package (blank to finish)').Trim()
                if (-not $p) { break }
                if ($p -match '^(.+)=(.+)$') {
                    $pkgs.Add([ProfilePackage]::new($Matches[1].Trim(), $Matches[2].Trim()))
                } else {
                    $pkgs.Add([ProfilePackage]::new($p, ''))
                }
            }

            $prof = [FleetProfile]::new()
            $prof.Name             = $name
            $prof.TargetNames      = $tNames
            $prof.ExpectedPackages = $pkgs.ToArray()

            $profiles += $prof
            Save-FltProfiles $profiles
            Write-Host "  Profile '$name' saved." -ForegroundColor Green
            Read-Host '  Press Enter'; continue
        }

        if ($choice -in @('2','3')) {
            if ($profiles.Count -eq 0) {
                Write-Host '  No profiles to compare.' -ForegroundColor Yellow
                Read-Host '  Press Enter'; continue
            }
            $prof = Read-FltNumberedChoice -Items $profiles -Prompt 'Profile number'
            if (-not $prof) { continue }

            Write-Host "  Comparing '$($prof.Name)' against fleet..." -ForegroundColor Cyan
            $diffs = Compare-FleetProfile -Profile $prof -AllTargets $Script:FleetTargets

            if ($diffs.Count -eq 0) {
                Write-Host '  All targets match the profile.' -ForegroundColor Green
            } else {
                Show-FltTable -Items $diffs -Columns @(
                    @{ Header = 'Package';   Expr = { $_.Package   } },
                    @{ Header = 'Target';    Expr = { $_.Target    } },
                    @{ Header = 'Expected';  Expr = { $_.Expected  } },
                    @{ Header = 'Installed'; Expr = { $_.Installed } },
                    @{ Header = 'Status';    Expr = { $_.Status    } }
                ) -NoNumber
                if ($choice -eq '3') {
                    if (Read-FltYesNo -Prompt 'Apply profile (install/upgrade all diffs)?') {
                        foreach ($pkg in $prof.ExpectedPackages) {
                            $spec    = if ($pkg.Version) { "$($pkg.Name.ToLower())=$($pkg.Version)" } else { $pkg.Name.ToLower() }
                            $targets = @($diffs | Where-Object { $_.Package -eq $pkg.Name } |
                                         ForEach-Object { $tn = $_.Target;
                                             $Script:FleetTargets | Where-Object { $_.Name -eq $tn } } |
                                         Where-Object { $_ } | Select-Object -Unique)
                            if ($targets.Count -gt 0) {
                                _Invoke-FleetBatchAction -Action 'install' -PackageSpec $spec
                            }
                        }
                    }
                }
            }
            Read-Host '  Press Enter'; continue
        }

        if ($choice -eq '4') {
            if ($profiles.Count -eq 0) { continue }
            $prof = Read-FltNumberedChoice -Items $profiles -Prompt 'Profile to delete'
            if (-not $prof) { continue }
            if (Read-FltYesNo -Prompt "Delete '$($prof.Name)'?") {
                $profiles = @($profiles | Where-Object { $_.Name -ne $prof.Name })
                Save-FltProfiles $profiles
                Write-Host "  Deleted '$($prof.Name)'." -ForegroundColor Green
            }
            Read-Host '  Press Enter'; continue
        }
    }
}

# ── Setup Menu ────────────────────────────────────────────────────────────────

# =============================================================================
#  Internal diagnostics — Setup > 10. Diagnostics
#  Verifies that the adapter abstractions and key subsystems are correctly
#  wired and functional. No external calls (no tcpkg, no SSH, no network).
# =============================================================================

function Invoke-SetupMenu {
    $result      = ''
    $lastCmd     = ''
    $mode        = 'targets'

    # Column definitions vary by mode
    $targetCols  = @('Name','OS','Type','Address','Port','Internet Access')
    $targetProps = @('Name','OS','TargetType','Address','Port','InternetAccess')
    $sourceCols  = @('Priority','Name','State')
    $sourceProps = @('Pri','Name','State')

    $repaint = {
        # Use persistent script-scope sort/filter state
        $sortState   = if ($mode -eq 'sources') { $Script:FltSourcesSort   } else { $Script:FltTargetSort   }
        $filterState = if ($mode -eq 'sources') { $Script:FltSourcesFilter } else { $Script:FltTargetFilter }
        Show-SetupDashboard -Mode $mode -Items $items -Result $result -LastCmd $lastCmd `
            -SortState $sortState -FilterState $filterState
    }

    while ($true) {
        # Fetch fresh data
        $items = if ($mode -eq 'sources') {
            @(Get-FltSources)
        } else {
            @($Script:FleetTargets)
        }

        & $repaint
        $result  = ''
        $lastCmd = ''

        $choice = (Read-Host '  Choice').Trim()
        if ($choice -eq '0') { return }

        # Sort/filter
        if ($choice -eq '*') {
            $cols  = if ($mode -eq 'sources') { $sourceCols }  else { $targetCols }
            $props = if ($mode -eq 'sources') { $sourceProps } else { $targetProps }
            $activeSortState = if ($mode -eq 'sources') { $Script:FltSourcesSort } else { $Script:FltTargetSort }
            Invoke-FltSortPicker -Columns $cols -Properties $props -State $activeSortState | Out-Null
            # Persist new sort order to targets.local.json (targets only — sources managed by tcpkg)
            if ($mode -ne 'sources' -and $Script:FltTargetSort.SortColumn) {
                $sorted = @(Invoke-FltSort -Items $Script:FleetTargets `
                    -Column $Script:FltTargetSort.SortColumn -Descending $Script:FltTargetSort.SortDesc)
                Save-FltTargets -Targets $sorted | Out-Null
                $Script:FleetTargets = $sorted
            }
            continue
        }
        if ($choice -eq '/') {
            $cols  = if ($mode -eq 'sources') { $sourceCols }  else { $targetCols }
            $props = if ($mode -eq 'sources') { $sourceProps } else { $targetProps }
            $activeFilterState = if ($mode -eq 'sources') { $Script:FltSourcesFilter } else { $Script:FltTargetFilter }
            Invoke-FltFilterPicker -Columns $cols -Properties $props -State $activeFilterState | Out-Null
            continue
        }

        # 1/2/3 → target mode; 4 → source mode
        if ($choice -in @('1','2','3') -or ($choice -match '^\d+$' -and [int]$choice -ge 11)) {
            $mode = 'targets'
        }
        if ($choice -eq '4') { $mode = 'sources' }

        # 11+ → select a target for Verify/Edit/Remove (from sorted/filtered display)
        if ($choice -match '^\d+$' -and [int]$choice -ge 11) {
            # Build sorted/filtered display to get correct target
            $activeSortState   = if ($mode -eq 'sources') { $Script:FltSourcesSort   } else { $Script:FltTargetSort   }
            $activeFilterState = if ($mode -eq 'sources') { $Script:FltSourcesFilter } else { $Script:FltTargetFilter }
            $display = if ($activeFilterState.FilterColumn) {
                @(Invoke-FltFilter -Items $items -Column $activeFilterState.FilterColumn -Value $activeFilterState.FilterValue)
            } else { @($items) }
            if ($activeSortState.SortColumn) {
                $display = @(Invoke-FltSort -Items $display -Column $activeSortState.SortColumn -Descending $activeSortState.SortDesc)
            }
            $idx = [int]$choice - 11
            if ($idx -ge 0 -and $idx -lt $display.Count) {
                $tgt = $display[$idx]
                $result = "$($tgt.Name)  ($($tgt.Address))  — enter action for Config:"
                Show-SetupDashboard -Mode 'targets' -Items $items -Result $result `
                    -SortState $activeSortState -FilterState $activeFilterState
                Write-Host '  1. Verify   2. Edit   3. Remove   4. Prepare target (install WinGet)   0. Cancel' -ForegroundColor Cyan
                $verb = (Read-Host '  Action').Trim()

                if ($verb -eq '1') {
                    $ok = Test-FleetTargetVerify -Name $tgt.Name
                    $result = if ($ok) { "Verified: $($tgt.Name) — OK" } else { "Verify FAILED: $($tgt.Name)" }
                } elseif ($verb -eq '2') {
                    Invoke-TargetMenu -Target $tgt
                    $Script:FleetTargets = @(Get-FleetTargets -Silent)
                    $result = "Updated: $($tgt.Name)"
                } elseif ($verb -eq '3') {
                    Show-SetupDashboard -Mode 'targets' -Items $targetItems `
                        -Result "Remove '$($tgt.Name)'?"
                    Write-Host '  1. Yes   0. No' -ForegroundColor Cyan
                    $confirm = (Read-Host '  Confirm').Trim()
                    if ($confirm -eq '1') {
                        $ok = Remove-FleetTarget -Name $tgt.Name
                        $Script:FleetTargets = @(Get-FleetTargets -Silent)
                        $result = if ($ok) { "Removed: $($tgt.Name)" } else { "Remove failed: $($tgt.Name)" }
                    } else {
                        $result = 'Remove cancelled.'
                    }
                } elseif ($verb -eq '4') {
                    # Prepare target — install WinGet via SSH
                    $cred = $null
                    $pwd  = Resolve-FltPassword -CredentialName $tgt.Name -PromptLabel '' -Silent
                    if ($pwd) {
                        $sec  = ConvertTo-SecureString $pwd -AsPlainText -Force
                        $cred = [System.Management.Automation.PSCredential]::new($tgt.User, $sec)
                    } else {
                        Clear-Host
                        Write-Host "  Prepare target: $($tgt.Name)" -ForegroundColor Cyan
                        Write-Host '  No stored credential found.' -ForegroundColor Yellow
                        $pwdIn = (Read-Host "  Password for $($tgt.User)").Trim()
                        if ($pwdIn) {
                            $sec  = ConvertTo-SecureString $pwdIn -AsPlainText -Force
                            $cred = [System.Management.Automation.PSCredential]::new($tgt.User, $sec)
                        }
                    }
                    if ($cred) {
                        Clear-Host
                        Write-Host "  Installing WinGet on $($tgt.Name)..." -ForegroundColor Cyan
                        Write-Host ''
                        $prep = Install-FltWinGetOnTarget -Target $tgt -Credential $cred `
                                    -OnProgress { param($msg) Write-Host "  $msg" -ForegroundColor DarkGray }
                        Write-Host ''
                        if ($prep.Ok) {
                            Write-Host "  $($prep.Message)" -ForegroundColor Green
                            $result = "WinGet installed on $($tgt.Name)"
                        } else {
                            $isHardWall = $prep.Message -match 'WindowsAppRuntime|headlessly'

                            if ($isHardWall) {
                                # Hard-wall: Microsoft.WindowsAppRuntime.1.8 cannot be installed headlessly
                                Write-Host '  FAILED — Windows App Runtime dependency cannot be installed headlessly' -ForegroundColor Red
                                Write-Host ''
                                Write-Host '  Microsoft.WindowsAppRuntime.1.8 is a framework package delivered by' -ForegroundColor Yellow
                                Write-Host '  Windows Update or Microsoft Store. On this machine (Windows Update' -ForegroundColor Yellow
                                Write-Host '  disabled), it cannot be installed via SSH. Choose one option:' -ForegroundColor Yellow
                                Write-Host ''
                                Write-Host '  ── Option 1 — Enable Windows Update temporarily (recommended) ──────' -ForegroundColor Cyan
                                Write-Host "     On $($tgt.Name): Settings > Windows Update > Check for updates" -ForegroundColor White
                                Write-Host '     WindowsAppRuntime.1.8 installs automatically.' -ForegroundColor DarkGray
                                Write-Host '     Then run Prepare target again — it will succeed.' -ForegroundColor DarkGray
                                Write-Host ''
                                Write-Host '  ── Option 2 — One interactive login (fastest) ──────────────────────' -ForegroundColor Cyan
                                Write-Host "     RDP or physically log in to $($tgt.Name)." -ForegroundColor White
                                Write-Host '     The Start menu loading activates the provisioned package.' -ForegroundColor DarkGray
                                Write-Host '     Then run Prepare target again to verify.' -ForegroundColor DarkGray
                                Write-Host ''
                                Write-Host '  ── Option 3 — Use tcpkg instead (no action needed) ─────────────────' -ForegroundColor Cyan
                                Write-Host "     $($tgt.Name) already works with tcpkg." -ForegroundColor White
                                Write-Host '     Edit target > set PackageManager = tcpkg to skip WinGet.' -ForegroundColor DarkGray
                                Write-Host ''
                                Write-Host '  Note: winget has been provisioned on the target. Option 2 is the' -ForegroundColor DarkGray
                                Write-Host '  fastest path — one login is all that is needed.' -ForegroundColor DarkGray
                            } else {
                                # Other failure — show raw message
                                Write-Host '  FAILED' -ForegroundColor Red
                                Write-Host ''
                                foreach ($line in ($prep.Message -split "`n")) {
                                    if ($line.Trim()) {
                                        Write-Host "  $line" -ForegroundColor Yellow
                                    }
                                }
                            }
                            Write-Host ''
                            $result = "WinGet install failed on $($tgt.Name) — see instructions above"
                        }
                        Read-Host '  Press Enter'
                    } else {
                        $result = 'Prepare cancelled — no credentials'
                    }
                } else {
                    $result = ''
                }
            } else {
                $result = "No target at position $choice — $($display.Count) targets shown"
            }
            continue
        }

        if ($choice -eq '1') {
            Invoke-TargetMenu
            $Script:FleetTargets = @(Get-FleetTargets -Silent)
            $result = "Targets updated ($($Script:FleetTargets.Count) configured)"
            continue
        }

        if ($choice -eq '2') {
            Write-Host '  CSV file path (blank to cancel):' -ForegroundColor Cyan
            $path = (Read-Host '  Path').Trim()
            if (-not $path) { continue }
            if (-not (Test-Path $path -PathType Leaf)) {
                $result = "File not found: $path"; continue
            }
            $csvRows   = Import-Csv -Path $path -Encoding UTF8 -ErrorAction SilentlyContinue
            $needsPwd  = $csvRows -and ($csvRows | Where-Object { -not $_.Password })
            $sharedPwd = ''
            if ($needsPwd) {
                Write-Host '  CSV has no passwords — shared SSH password (blank to skip):' -ForegroundColor Cyan
                $sharedPwd = (Read-Host '  Password').Trim()
            }
            $skip = Read-FltYesNo -Prompt 'Skip unreachable targets?'
            $res  = Import-FleetTargetsCsv -Path $path -SharedPassword $sharedPwd -SkipUnreachable:$skip
            $Script:FleetTargets = @(Get-FleetTargets -Silent)
            $result = "Added: $($res.Added)  Updated: $($res.Updated)  Skipped: $($res.Skipped)"
            if ($res.Errors.Count -gt 0) { $result += "  Errors: $($res.Errors -join '; ')" }
            continue
        }

        if ($choice -eq '3') {
            Write-Host '  Save CSV to (blank to cancel):' -ForegroundColor Cyan
            $path = (Read-Host '  Path').Trim()
            if (-not $path) { continue }
            if ($path.EndsWith('\') -or $path.EndsWith('/') -or (Test-Path $path -PathType Container)) {
                $path = Join-Path $path "fleet-targets-$(Get-Date -Format 'yyyy-MM-dd').csv"
            }
            $dir = Split-Path $path -Parent
            if ($dir -and -not (Test-Path $dir)) {
                $result = "Directory not found: $dir"; continue
            }
            $n = Export-FleetTargetsCsv -Path $path
            $result = "Exported $n target(s) to $path"
            continue
        }

        if ($choice -eq '4') {
            Invoke-FleetSourceMenu
            continue
        }

        if ($choice -eq '5') {
            $created = New-FltLocalConfig -ConfigDir $Script:FltConfigDir
            $result  = if ($created.Count -gt 0) { "Created: $($created -join ', ')" } `
                       else { 'Local config files already exist.' }
            continue
        }

        if ($choice -eq '6') {
            Write-Host '  Save archive to (e.g. TcFltConfig.zip, blank to cancel):' -ForegroundColor Cyan
            $path = (Read-Host '  Path').Trim()
            if (-not $path) { continue }
            $ok     = Export-FltConfig -DestinationPath $path
            $result = if ($ok) { "Exported to $path" } else { 'Export failed.' }
            continue
        }

        if ($choice -eq '7') {
            Write-Host '  Archive path (blank to cancel):' -ForegroundColor Cyan
            $path = (Read-Host '  Path').Trim()
            if (-not $path) { continue }
            $imported = Import-FltConfig -ArchivePath $path
            if ($imported -and $imported.Count -gt 0) {
                Initialize-FltConfig -ConfigDir $Script:FltConfigDir | Out-Null
                $result = "Imported: $($imported -join ', ')"
            } else {
                $result = 'Import failed or nothing to import.'
            }
            continue
        }

        if ($choice -eq '8') {
            Clear-Host
            Write-Host '  Command Log' -ForegroundColor Cyan
            Write-Host '  Filters: blank = last 7 days, all targets, all commands.' -ForegroundColor DarkGray
            Write-Host ''
            $days = Read-FltValue 'Days back (blank = 7):' -AllowEmpty
            $tgt  = Read-FltValue 'Target name filter (blank = all):' -AllowEmpty
            $verb = Read-FltValue 'Command verb filter (blank = all):' -AllowEmpty
            Show-FltCommandLog `
                -LastDays $(if ($days -match '^\d+$') { [int]$days } else { 7 }) `
                -Target   $tgt `
                -CmdVerb  $verb
            Read-Host '  Press Enter'; continue
        }

        if ($choice -eq '9') {
            $Script:FltReadOnly = -not $Script:FltReadOnly
            $result = "Read-only mode $(if ($Script:FltReadOnly) { 'ON' } else { 'OFF' })."
            continue
        }

        if ($choice -eq '10') {
            Invoke-FltTestRunner
            continue
        }
    }
}