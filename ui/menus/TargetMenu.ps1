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
    $name = Read-FltValue 'Name (blank to cancel):' -CancelOnBlank; if (-not $name) { return }
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

    $ok = Add-FleetTarget -Name $name -HostAddress $hostAddr -Port ([int]$port) -User $user `
              -PlainPassword $plainPwd -KeyFile $keyFile -InternetAccess $ia

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
                $result = "No source at position $choice"
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

function Invoke-SetupMenu {
    $result  = ''
    $lastCmd = ''
    $mode    = 'targets'   # 'targets' or 'sources'

    while ($true) {
        # Fetch fresh data for the dashboard
        $items = if ($mode -eq 'sources') {
            @(Get-FltSources)
        } else {
            @($Script:FleetTargets)
        }

        Show-SetupDashboard -Mode $mode -Items $items -Result $result -LastCmd $lastCmd
        $result  = ''
        $lastCmd = ''

        $choice = (Read-Host '  Choice').Trim()
        if ($choice -eq '0') { return }

        # 1/2/3 → target mode
        if ($choice -in @('1','2','3')) { $mode = 'targets' }
        # 4 → source mode
        if ($choice -eq '4') { $mode = 'sources' }

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
    }
}