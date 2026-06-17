# =============================================================================
#  TcFltPkgMgr — WinGet Repository
#  Local winget search and version listing.
#  Returns the same object shapes as PackageRepository.ps1 (tcpkg equivalents)
#  so the package menus can call either without knowing which is active.
#
#  winget must be installed on the OPERATOR machine for search/browse.
#  It does NOT need to be on the remote targets — the executor SSHes to the
#  target and runs winget there directly.
#
#  Parsing strategy:
#    winget uses a solid separator line (no column gaps) — column positions
#    are derived from the header word start positions, not separator gaps.
# =============================================================================

# Returns $true if winget is available on the operator machine.
function Test-FltWinGetAvailable {
    return $null -ne (Get-Command 'winget' -ErrorAction SilentlyContinue)
}

# Parse winget tabular output into normalised package objects.
# Returns @{ Ok; Items; Columns } — same as Get-FltPackageList.
#
# Strategy: find the header line (contains 'Name' and 'Id'), determine column
# start positions from header word positions, then extract data from each row.
function _Parse-WinGetTable {
    param([string[]]$Lines)

    $fail = [pscustomobject]@{ Ok = $false; Items = @(); Columns = @() }

    # Find the separator line — a run of dashes/unicode box chars
    $sepIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -match '^[-\u2500]{10,}$') { $sepIdx = $i; break }
    }
    if ($sepIdx -lt 1) { return $fail }

    $header = $Lines[$sepIdx - 1]

    # Column positions from header word starts
    $colMatches = [regex]::Matches($header, '\S+')
    if ($colMatches.Count -lt 2) { return $fail }

    $colStarts = @($colMatches | ForEach-Object {
        [pscustomobject]@{ Pos = $_.Index; Name = $_.Value.ToLower() }
    })

    function _GetCol($line, $idx) {
        $s = $colStarts[$idx].Pos
        $e = if ($idx + 1 -lt $colStarts.Count) { $colStarts[$idx + 1].Pos } else { $line.Length }
        if ($s -ge $line.Length) { return '' }
        return $line.Substring($s, [Math]::Min($e, $line.Length) - $s).Trim()
    }

    $idxName = ($colStarts | Where-Object { $_.Name -eq 'name'    } | Select-Object -First 1)
    $idxId   = ($colStarts | Where-Object { $_.Name -eq 'id'      } | Select-Object -First 1)
    $idxVer  = ($colStarts | Where-Object { $_.Name -eq 'version' } | Select-Object -First 1)
    $idxSrc  = ($colStarts | Where-Object { $_.Name -eq 'source'  } | Select-Object -First 1)

    $iName = if ($idxName) { [array]::IndexOf($colStarts, $idxName) } else { -1 }
    $iId   = if ($idxId)   { [array]::IndexOf($colStarts, $idxId)   } else { -1 }
    $iVer  = if ($idxVer)  { [array]::IndexOf($colStarts, $idxVer)  } else { -1 }
    $iSrc  = if ($idxSrc)  { [array]::IndexOf($colStarts, $idxSrc)  } else { -1 }

    if ($iId -lt 0) { return $fail }

    $items = @($Lines[($sepIdx + 1)..($Lines.Count - 1)] | ForEach-Object {
        $line = $_
        if ($line.Trim() -eq '') { return }
        $id   = if ($iId   -ge 0) { _GetCol $line $iId   } else { '' }
        $name = if ($iName -ge 0) { _GetCol $line $iName } else { $id }
        $ver  = if ($iVer  -ge 0) { _GetCol $line $iVer  } else { '' }
        $src  = if ($iSrc  -ge 0) { _GetCol $line $iSrc  } else { '' }
        if (-not $id) { return }
        [pscustomobject]@{
            Name             = $id      # Use Id as Name — consistent with how packages are specified
            Title            = $name    # Display name
            Version          = $ver
            InstalledVersion = ''
            Source           = $src
            IsPreview        = $false
            InstallDate      = ''
        }
    } | Where-Object { $_ })

    if ($items.Count -eq 0) {
        return [pscustomobject]@{ Ok = $true; Items = @(); Columns = @() }
    }

    $cols = @(
        @{ Header = 'Id';      Expr = { $_.Name } },
        @{ Header = 'Name';    Expr = { $_.Title } },
        @{ Header = 'Version'; Expr = { $_.Version } },
        @{ Header = 'Source';  Expr = { $_.Source } }
    )
    return [pscustomobject]@{ Ok = $true; Items = $items; Columns = $cols }
}

# Search for WinGet packages matching a search term.
function Search-FltWinGetPackage {
    param([string]$SearchTerm)

    $fail = [pscustomobject]@{ Ok = $false; Items = @(); Columns = @() }
    if (-not (Test-FltWinGetAvailable)) { return $fail }

    $entry = Start-FltCommandEntry -Command "winget search $SearchTerm" -Target 'local' -Mode 'live'

    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $raw  = & winget search $SearchTerm --accept-source-agreements 2>&1
    $Script:FltLastExit = $LASTEXITCODE
    $ErrorActionPreference = $prev

    Complete-FltCommandEntry -Entry $entry -ExitCode $Script:FltLastExit -DurationSec 0

    if (-not $raw) { return $fail }

    # Filter to string lines only — discard ErrorRecord objects from 2>&1
    $lines = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    return _Parse-WinGetTable -Lines $lines
}

# List available versions of a WinGet package by id.
function Get-FltWinGetVersions {
    param([string]$PackageId)

    if (-not (Test-FltWinGetAvailable)) { return @() }

    $entry = Start-FltCommandEntry -Command "winget show --id $PackageId --versions" -Target 'local' -Mode 'live'

    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $raw  = & winget show --id $PackageId --versions --accept-source-agreements 2>&1
    $Script:FltLastExit = $LASTEXITCODE
    $ErrorActionPreference = $prev

    Complete-FltCommandEntry -Entry $entry -ExitCode $Script:FltLastExit -DurationSec 0

    if (-not $raw) { return @() }

    $lines  = @($raw | ForEach-Object { [string]$_.Trim() } | Where-Object { $_ })
    $sepIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^[-\u2500]{5,}$') { $sepIdx = $i; break }
    }
    if ($sepIdx -lt 0) { return @() }

    return @($lines[($sepIdx + 1)..($lines.Count - 1)] | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Version = $_; Source = '' }
    })
}

# Build a name->version hashtable of WinGet packages installed locally.
function Get-FltWinGetInstalledIndex {
    if (-not (Test-FltWinGetAvailable)) { return @{} }

    $prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
    $raw  = & winget list --accept-source-agreements 2>&1
    $Script:FltLastExit = $LASTEXITCODE
    $ErrorActionPreference = $prev

    if (-not $raw) { return @{} }

    $lines  = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
    $result = _Parse-WinGetTable -Lines $lines
    $idx    = @{}
    if ($result.Ok) {
        foreach ($item in $result.Items) {
            if ($item.Name) { $idx[$item.Name.ToLower()] = $item.Version }
        }
    }
    return $idx
}

# =============================================================================
#  WinGet remote installation
#  Installs winget on a remote Windows target via SSH.
#
#  Prerequisites:
#    - SSH running as the authenticating user (not SYSTEM)
#    - Internet access on the target (downloads ~230MB)
#    - Windows Update enabled OR Windows 10 1809+ with Microsoft Store active
#
#  Limitation — Windows 11 24H2 with Windows Update disabled:
#    Microsoft.WindowsAppRuntime.1.8 is a framework package that can only be
#    installed via Windows Update or Microsoft Store. On TwinCAT engineering
#    PCs where WU is disabled, winget can be provisioned but not activated
#    headlessly because the SYSTEM account is explicitly blocked from
#    installing framework packages (error 0x80073CF9).
#
#    Resolution options:
#      1. Enable Windows Update, let it run once, disable it again
#      2. RDP or physical access: open Settings > Apps > winget once
#      3. Use tcpkg for this target (already works)
#
#  Returns [pscustomobject]@{ Ok; Message }
# =============================================================================

# Resolve the latest winget release asset URLs from the GitHub releases API.
function _Get-WinGetLatestUrls {
    try {
        $api      = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
        $headers  = @{ 'User-Agent' = 'TcFltPkgMgr' }
        $response = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30
        $version  = $response.tag_name

        $assets  = $response.assets
        $bundle  = ($assets | Where-Object { $_.name -match 'DesktopAppInstaller.*\.msixbundle$' } |
                    Select-Object -First 1).browser_download_url
        $license = ($assets | Where-Object { $_.name -match '_License.*\.xml$' } |
                    Select-Object -First 1).browser_download_url

        if (-not $bundle) { return $null }

        return [pscustomobject]@{
            Version    = $version
            BundleUrl  = $bundle
            LicenseUrl = $license
        }
    } catch {
        Write-Warning "Could not fetch winget release info: $_"
        return $null
    }
}

# Download a file on the remote target via SSH.
# Tries curl.exe first (ships with Windows 10+), falls back to Invoke-WebRequest.
# Returns @{ Ok; Error }
function _Invoke-RemoteDownload {
    param(
        [int]    $SessionId,
        [string] $Url,
        [string] $DestPath,
        [int]    $TimeoutSecs = 180
    )
    $curlCmd = "curl.exe -L -s -S -o `"$DestPath`" `"$Url`" 2>&1"
    $result  = Invoke-SSHCommand -SessionId $SessionId -Command $curlCmd -TimeOut $TimeoutSecs
    if ($result.ExitStatus -eq 0) {
        $check   = Invoke-SSHCommand -SessionId $SessionId `
                       -Command "if exist `"$DestPath`" (for %F in (`"$DestPath`") do @echo %~zF) else (echo MISSING)" `
                       -TimeOut 10
        $sizeOut = ($check.Output -join '').Trim()
        if ($sizeOut -match '^\d+$' -and [long]$sizeOut -gt 1000) { return @{ Ok = $true; Error = '' } }
        return @{ Ok = $false; Error = "curl exit=0 but file missing or empty (size=$sizeOut)" }
    }
    $iwrCmd  = "Invoke-WebRequest -Uri '$Url' -OutFile '$DestPath' -UseBasicParsing 2>&1"
    $result2 = Invoke-SSHCommand -SessionId $SessionId -Command $iwrCmd -TimeOut $TimeoutSecs
    if ($result2.ExitStatus -eq 0) { return @{ Ok = $true; Error = '' } }
    $errOut  = ($result.Output + $result2.Output | Where-Object { $_ } | Select-Object -First 3) -join ' | '
    return @{ Ok = $false; Error = "curl exit=$($result.ExitStatus), IWR exit=$($result2.ExitStatus): $errOut" }
}

function Install-FltWinGetOnTarget {
    param(
        [FleetTarget] $Target,
        [System.Management.Automation.PSCredential] $Credential = $null,
        [string]      $KeyFile    = '',
        [scriptblock] $OnProgress = $null
    )

    $fail    = { param($msg) [pscustomobject]@{ Ok = $false; Message = $msg } }
    $succeed = { param($msg) [pscustomobject]@{ Ok = $true;  Message = $msg } }

    function _Progress { param($msg)
        if ($OnProgress) { & $OnProgress $msg }
        else { Write-Host "  $msg" -ForegroundColor DarkGray }
    }

    if (-not (Ensure-FltPoshSsh)) {
        return (& $fail 'Posh-SSH not available — run: Install-Module Posh-SSH -Scope CurrentUser')
    }

    $useKey = -not [string]::IsNullOrWhiteSpace($KeyFile)
    $params = @{
        ComputerName = $Target.Address
        Port         = [int]$Target.Port
        AcceptKey    = $true
        ErrorAction  = 'Stop'
    }
    if ($useKey) { $params['Username'] = $Target.User; $params['KeyFile'] = $KeyFile }
    else          { $params['Credential'] = $Credential }

    $sid          = $null
    $tmpDirActual = ''

    try {
        # Open SSH session
        try {
            $session = New-SSHSession @params
            $sid     = $session.SessionId
        } catch {
            return (& $fail "SSH connection failed: $($_.Exception.Message)")
        }

        # Step 1: Check already installed
        _Progress 'Checking if winget is already installed...'
        $verCheck = Invoke-SSHCommand -SessionId $sid -Command 'winget --version' -TimeOut 15
        $verOut   = ($verCheck.Output -join '').Trim()
        if ($verOut -match 'v\d') {
            return (& $succeed "winget already installed: $verOut")
        }

        # Step 2: Resolve release URLs
        _Progress 'Resolving latest winget release from GitHub...'
        $urls = _Get-WinGetLatestUrls
        if (-not $urls) {
            return (& $fail 'Could not resolve winget release URLs — check internet on operator machine')
        }
        _Progress "Latest winget: $($urls.Version)"

        # Step 3: Create temp directory
        $remoteUser   = $Target.User
        $tmpDirActual = "C:\Users\$remoteUser\AppData\Local\Temp\winget-install"
        $mkOut = ($( Invoke-SSHCommand -SessionId $sid `
            -Command "cmd /c mkdir `"$tmpDirActual`" 2>&1 || echo ALREADY_EXISTS" `
            -TimeOut 15 ).Output -join '').Trim()
        if ($mkOut -notmatch 'ALREADY_EXISTS|already exists|successfully') {
            $tmpDirActual = 'C:\Windows\Temp\winget-install'
            Invoke-SSHCommand -SessionId $sid `
                -Command "cmd /c mkdir `"$tmpDirActual`" 2>&1" -TimeOut 15 | Out-Null
        }
        _Progress "Temp directory: $tmpDirActual"

        # Step 4: Download winget bundle
        _Progress "Downloading winget $($urls.Version) bundle..."
        $bundleDest = "$tmpDirActual\AppInstaller.msixbundle"
        $dlBundle   = _Invoke-RemoteDownload -SessionId $sid -Url $urls.BundleUrl `
                          -DestPath $bundleDest -TimeoutSecs 300
        if (-not $dlBundle.Ok) {
            return (& $fail "Failed to download winget bundle: $($dlBundle.Error)")
        }

        # Step 4b: Download Windows App Runtime redistributable
        # This contains the framework MSIX packages needed by winget 1.6+
        _Progress 'Downloading Windows App Runtime redistributable...'
        $redistDest = "$tmpDirActual\Redist.zip"
        $redistUrl  = 'https://aka.ms/windowsappsdk/1.8/1.8.250907003/Microsoft.WindowsAppRuntime.Redist.1.8.zip'
        $dlRedist   = _Invoke-RemoteDownload -SessionId $sid -Url $redistUrl `
                          -DestPath $redistDest -TimeoutSecs 300
        $redistAvail = $false
        if ($dlRedist.Ok) {
            $extractCmd = 'Expand-Archive -Path "' + $redistDest + '" -DestinationPath "' + $tmpDirActual + '\Redist" -Force; Write-Output OK'
            $extractB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($extractCmd))
            $extractRes = Invoke-SSHCommand -SessionId $sid `
                              -Command "pwsh -NoProfile -NonInteractive -EncodedCommand $extractB64" `
                              -TimeOut 60
            $redistAvail = ($extractRes.Output -join '') -match 'OK'
            if ($redistAvail) { _Progress 'Windows App Runtime redistributable extracted' }
        }

        # Download license
        $licenseDest = ''
        if ($urls.LicenseUrl) {
            $licenseDest = "$tmpDirActual\License.xml"
            $dlLic = _Invoke-RemoteDownload -SessionId $sid -Url $urls.LicenseUrl `
                         -DestPath $licenseDest -TimeoutSecs 30
            if (-not $dlLic.Ok) { $licenseDest = '' }
        }

        # Step 5: Provision via SYSTEM scheduled task
        # Build the PS1 script on the OPERATOR machine, encode it as base64,
        # then write it to the target in a single SSH command — no line-by-line
        # echo fragility, no quoting battles.
        _Progress 'Provisioning winget via scheduled task (SYSTEM context)...'

        $redistPath = "$tmpDirActual\Redist\MSIX\win10-x64"
        $licParam   = if ($licenseDest) { '-LicensePath "' + $licenseDest + '"' } else { '-SkipLicense' }
        $resultFile = 'C:\Windows\Temp\winget_prov_result.txt'
        $scriptFile = 'C:\Windows\Temp\winget_prov.ps1'

        # Build provisioning script as a string on the operator machine
        $provScript  = "try {`n"
        $provScript += "    `$rp = '$redistPath'`n"
        $provScript += "    if (Test-Path `"`$rp\Microsoft.WindowsAppRuntime.1.8.msix`") {`n"
        $provScript += "        Add-AppxPackage -Path `"`$rp\Microsoft.WindowsAppRuntime.1.8.msix`" -ForceUpdateFromAnyVersion -ErrorAction SilentlyContinue`n"
        $provScript += "        Add-AppxPackage -Path `"`$rp\Microsoft.WindowsAppRuntime.Main.1.8.msix`" -ForceUpdateFromAnyVersion -ErrorAction SilentlyContinue`n"
        $provScript += "        Add-AppxPackage -Path `"`$rp\Microsoft.WindowsAppRuntime.Singleton.1.8.msix`" -ForceUpdateFromAnyVersion -ErrorAction SilentlyContinue`n"
        $provScript += "        Add-AppxPackage -Path `"`$rp\Microsoft.WindowsAppRuntime.DDLM.1.8.msix`" -ForceUpdateFromAnyVersion -ErrorAction SilentlyContinue`n"
        $provScript += "    }`n"
        $provScript += "    Add-AppxProvisionedPackage -Online -PackagePath `"$bundleDest`" $licParam -ErrorAction Stop`n"
        $provScript += "    `"PROVISION_OK`" | Set-Content `"$resultFile`" -Encoding ASCII`n"
        $provScript += "} catch {`n"
        $provScript += "    `$_.Exception.Message | Set-Content `"$resultFile`" -Encoding ASCII`n"
        $provScript += "}`n"

        # Write the provisioning script to disk via certutil -decode.
        # This avoids the 8191-char Windows command line limit that breaks
        # long EncodedCommand strings. Write b64 to a text file, decode to PS1.
        # Use UTF-8 encoding — certutil writes raw bytes, powershell reads UTF-8 by default.
        $provScriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($provScript))
        $b64File    = 'C:\Windows\Temp\winget_prov.b64'
        $scriptFile = 'C:\Windows\Temp\winget_prov.ps1'

        # Write b64 in chunks of 76 chars (certutil requires line-wrapped base64)
        $chunkSize = 76
        $b64Lines  = @()
        for ($ci = 0; $ci -lt $provScriptB64.Length; $ci += $chunkSize) {
            $b64Lines += $provScriptB64.Substring($ci, [Math]::Min($chunkSize, $provScriptB64.Length - $ci))
        }

        # Write first line (overwrite), then append remaining lines
        Invoke-SSHCommand -SessionId $sid `
            -Command "cmd /c echo $($b64Lines[0]) > `"$b64File`"" -TimeOut 10 | Out-Null
        for ($ci = 1; $ci -lt $b64Lines.Count; $ci++) {
            Invoke-SSHCommand -SessionId $sid `
                -Command "cmd /c echo $($b64Lines[$ci]) >> `"$b64File`"" -TimeOut 10 | Out-Null
        }

        # Decode b64 to the PS1 script file using certutil
        $decodeRes = Invoke-SSHCommand -SessionId $sid `
                         -Command "certutil -f -decode `"$b64File`" `"$scriptFile`" 2>&1" `
                         -TimeOut 15
        $decodeOut = ($decodeRes.Output -join '').Trim()

        # Verify script was written and is non-empty
        $verifyRes = Invoke-SSHCommand -SessionId $sid `
                         -Command "cmd /c if exist `"$scriptFile`" (for %F in (`"$scriptFile`") do @echo %~zF) else (echo MISSING)" `
                         -TimeOut 10
        $scriptSize = ($verifyRes.Output -join '').Trim()
        if ($scriptSize -eq 'MISSING' -or -not ($scriptSize -match '^\d+$') -or [int]$scriptSize -lt 100) {
            return (& $fail "Could not write provisioning script (certutil: $decodeOut, size: $scriptSize)")
        }
        _Progress "Provisioning script written ($scriptSize bytes)"

        # Seed result file as 'pending'
        Invoke-SSHCommand -SessionId $sid `
            -Command "cmd /c echo pending > `"$resultFile`"" -TimeOut 10 | Out-Null

        # Create and run scheduled task as SYSTEM
        Invoke-SSHCommand -SessionId $sid -Command "schtasks /delete /tn WinGetProv /f 2>nul" -TimeOut 10 | Out-Null
        Invoke-SSHCommand -SessionId $sid `
            -Command "schtasks /create /tn WinGetProv /tr `"powershell -NonInteractive -ExecutionPolicy Bypass -File \`"$scriptFile\`"`" /sc once /st 00:00 /ru SYSTEM /f" `
            -TimeOut 15 | Out-Null
        Invoke-SSHCommand -SessionId $sid -Command 'schtasks /run /tn WinGetProv' -TimeOut 10 | Out-Null

        # Poll result file for up to 90 seconds
        _Progress 'Waiting for provisioning (up to 90 seconds)...'
        $provDeadline = [DateTime]::UtcNow.AddSeconds(90)
        $provOut = 'pending'
        while ($provOut -eq 'pending' -and [DateTime]::UtcNow -lt $provDeadline) {
            Start-Sleep -Seconds 5
            $readRes = Invoke-SSHCommand -SessionId $sid `
                           -Command "type `"$resultFile`"" -TimeOut 10
            $provOut = ($readRes.Output -join '').Trim()
        }
        Invoke-SSHCommand -SessionId $sid -Command 'schtasks /delete /tn WinGetProv /f 2>nul' -TimeOut 10 | Out-Null

        if ($provOut -notmatch 'PROVISION_OK') {
            if ($provOut -match 'WindowsAppRuntime|0x80073CF3|0x80073CF9') {
                return (& $fail ("winget requires Microsoft.WindowsAppRuntime.1.8 which cannot be installed headlessly`n" +
                    "on Windows 11 with Windows Update disabled (error: $provOut)`nheadlessly"))
            }
            if ($provOut -eq 'pending') {
                # Task may still be running — check task status
                $taskStatus = (Invoke-SSHCommand -SessionId $sid `
                    -Command "schtasks /query /tn WinGetProv /fo LIST 2>nul" -TimeOut 10).Output -join ' '
                return (& $fail "Provisioning did not complete within 90 seconds. Task status: $taskStatus")
            }
            return (& $fail "Provisioning failed: $provOut")
        }

        _Progress 'winget provisioned successfully'

        # Step 5b: Install Windows App Runtime framework and register winget.
        # 0x80073D06 = higher version already installed = treat as success.
        # 0x80070005 = access denied over SSH = runtime needs interactive install.
        # Either way, always attempt registration — if runtime exists at any version it may work.
        if ($redistAvail) {
            _Progress 'Installing Windows App Runtime framework as current user...'
            $rtCmd = "try { Add-AppxPackage -Path '$redistPath\Microsoft.WindowsAppRuntime.1.8.msix' -ForceUpdateFromAnyVersion -ErrorAction Stop; Write-Output RUNTIME_OK } catch { if (`$_.Exception.Message -match '0x80073D06|higher version') { Write-Output RUNTIME_OK } else { Write-Output `"RUNTIME_FAIL: `$(`$_.Exception.Message.Split([char]10)[0].Trim())`" } }"
            $rtB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($rtCmd))
            $rtRes = Invoke-SSHCommand -SessionId $sid `
                         -Command "pwsh -NoProfile -NonInteractive -EncodedCommand $rtB64" `
                         -TimeOut 120
            $rtOut = ($rtRes.Output -join '').Trim()

            if ($rtOut -match 'RUNTIME_OK') {
                _Progress 'Windows App Runtime framework ready'
            } else {
                # 0x80070005 over SSH — framework packages require an interactive desktop token.
                # Schedule a one-time logon task to install the runtime at next autologin.
                _Progress "Runtime install requires desktop session — scheduling logon task..."
                $logonScript  = "Add-AppxPackage -Path '$redistPath\Microsoft.WindowsAppRuntime.1.8.msix' -ForceUpdateFromAnyVersion -ErrorAction SilentlyContinue; "
                $logonScript += "`$pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller; "
                $logonScript += "if (`$pkg) { Add-AppxPackage -DisableDevelopmentMode -Register (`$pkg.InstallLocation + '\AppxManifest.xml') -ErrorAction SilentlyContinue }; "
                $logonScript += "schtasks /delete /tn WinGetActivate /f 2>`$null"

                # Write logon script via certutil approach
                $logonB64    = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($logonScript))
                $logonFile   = 'C:\Windows\Temp\winget_activate.ps1'
                $logonB64File = 'C:\Windows\Temp\winget_activate.b64'

                $logonChunks = @()
                for ($ci = 0; $ci -lt $logonB64.Length; $ci += 76) {
                    $logonChunks += $logonB64.Substring($ci, [Math]::Min(76, $logonB64.Length - $ci))
                }
                Invoke-SSHCommand -SessionId $sid `
                    -Command "cmd /c echo $($logonChunks[0]) > `"$logonB64File`"" -TimeOut 10 | Out-Null
                for ($ci = 1; $ci -lt $logonChunks.Count; $ci++) {
                    Invoke-SSHCommand -SessionId $sid `
                        -Command "cmd /c echo $($logonChunks[$ci]) >> `"$logonB64File`"" -TimeOut 10 | Out-Null
                }
                Invoke-SSHCommand -SessionId $sid `
                    -Command "certutil -f -decode `"$logonB64File`" `"$logonFile`" 2>nul" -TimeOut 15 | Out-Null

                # Create logon-triggered task for Administrator user
                Invoke-SSHCommand -SessionId $sid `
                    -Command "schtasks /delete /tn WinGetActivate /f 2>nul" -TimeOut 10 | Out-Null
                $taskRes = Invoke-SSHCommand -SessionId $sid `
                    -Command "schtasks /create /tn WinGetActivate /tr `"powershell -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$logonFile`"`" /sc onlogon /ru Administrator /f" `
                    -TimeOut 15
                $taskOut = ($taskRes.Output -join '').Trim()
                if ($taskOut -match 'SUCCESS') {
                    _Progress 'Logon activation task created — will run at next autologin'
                } else {
                    _Progress "Logon task note: $taskOut"
                }
            }

            # Always attempt registration regardless of runtime install outcome
            _Progress 'Registering winget for current user...'
            $regCmd = "`$pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller; if (`$pkg) { Add-AppxPackage -DisableDevelopmentMode -Register (`$pkg.InstallLocation + '\AppxManifest.xml') -ErrorAction Stop; Write-Output REG_OK } else { Write-Output PKG_NOT_FOUND }"
            $regB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($regCmd))
            $regRes = Invoke-SSHCommand -SessionId $sid `
                          -Command "pwsh -NoProfile -NonInteractive -EncodedCommand $regB64" `
                          -TimeOut 60
            $regOut = ($regRes.Output -join '').Trim()
            _Progress "Registration: $regOut"
        }

        # Step 6: Fresh session verification
        _Progress 'Verifying in fresh session...'
        Remove-SSHSession -SessionId $sid | Out-Null
        $sid = $null
        Start-Sleep -Seconds 5

        $session2 = New-SSHSession @params
        $ver2     = Invoke-SSHCommand -SessionId $session2.SessionId -Command 'winget --version' -TimeOut 15
        $ver2Out  = ($ver2.Output -join '').Trim()
        Remove-SSHSession -SessionId $session2.SessionId | Out-Null

        if ($ver2Out -match 'v\d') {
            return (& $succeed "winget installed and active: $ver2Out")
        }

        # Step 7: Reboot to activate via autologin
        _Progress 'winget provisioned — rebooting to activate via autologin (5 seconds)...'
        try {
            $sessionR = New-SSHSession @params
            Invoke-SSHCommand -SessionId $sessionR.SessionId `
                -Command 'shutdown /r /t 5 /c "TcFltPkgMgr: activating winget"' `
                -TimeOut 15 | Out-Null
            Remove-SSHSession -SessionId $sessionR.SessionId | Out-Null
        } catch {
            return (& $succeed 'winget provisioned — reboot target manually to activate via autologin')
        }

        # Wait for offline then online
        Start-Sleep -Seconds 15
        $online   = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(180)
        while ([DateTime]::UtcNow -lt $deadline) {
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $ar  = $tcp.BeginConnect($Target.Address, [int]$Target.Port, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(2000, $false)) { $online = $true; $tcp.Close(); break }
                $tcp.Close()
            } catch {}
            Start-Sleep -Seconds 5
        }

        if (-not $online) {
            return (& $succeed 'winget provisioned — target did not return within 3 minutes; check autologin settings')
        }

        _Progress 'Target online — waiting for autologin activation...'
        Start-Sleep -Seconds 30

        # Retry for up to 2 minutes
        $activated   = $false
        $actStr      = ''
        $actDeadline = [DateTime]::UtcNow.AddSeconds(120)
        $attempt     = 0
        while ([DateTime]::UtcNow -lt $actDeadline) {
            $attempt++
            try {
                $sessionV = New-SSHSession @params
                $actCheck = Invoke-SSHCommand -SessionId $sessionV.SessionId `
                                -Command 'winget --version' -TimeOut 10
                $actStr   = ($actCheck.Output -join '').Trim()
                Remove-SSHSession -SessionId $sessionV.SessionId | Out-Null
                if ($actStr -match 'v\d') { $activated = $true; break }
                _Progress "  Attempt $attempt — not yet active, retrying in 15 seconds..."
                Start-Sleep -Seconds 15
            } catch { Start-Sleep -Seconds 10 }
        }

        if ($activated) {
            return (& $succeed "winget installed and active after reboot: $actStr")
        }

        return (& $succeed ("winget provisioned and target rebooted — not yet active after 2 minutes.`n" +
            "If Microsoft.WindowsAppRuntime.1.8 is missing, one interactive login is required.`n" +
            "Try: RDP to $($Target.Name) and run 'winget --version' once."))

    } finally {
        if ($sid) {
            try {
                if ($tmpDirActual) {
                    Invoke-SSHCommand -SessionId $sid `
                        -Command "cmd /c rmdir /s /q `"$tmpDirActual`" 2>nul" `
                        -TimeOut 15 -ErrorAction SilentlyContinue | Out-Null
                }
            } catch {}
            Remove-SSHSession -SessionId $sid -ErrorAction SilentlyContinue | Out-Null
        }
    }
}