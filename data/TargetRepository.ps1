# =============================================================================
#  TcFltPkgMgr — Target Repository
#  All tcpkg remote list/add/edit/remove/verify calls.
#  Returns [FleetTarget[]] objects. Never writes to the console except through
#  Write-FltCommandEntry (the command log) and $Script:FltLastExit.
# =============================================================================

# The only place in this file that calls tcpkg. All other functions call this.
# Run an external executable with text fed to its stdin.
# Returns the process exit code. Works in PS5 and PS7.
# Renumber all sources 1..n in their current order to close priority gaps.
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

function Invoke-FltTcpkg {
    param(
        [string[]] $ArgList,
        [switch]   $Silent     # suppress console output (used by background queries)
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

# Parse tcpkg's JSON output safely — strips banner lines and ErrorRecord objects,
# extracts the first JSON array found in the output.
function ConvertFrom-FltTcpkgJson {
    param([object[]]$Raw)
    # 2>&1 mixes stdout strings with ErrorRecord objects; keep only strings
    $text  = ($Raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } |
              ForEach-Object { [string]$_ }) -join "`n"
    $start = $text.IndexOf('[')
    $end   = $text.LastIndexOf(']')
    if ($start -lt 0 -or $end -le $start) { return $null }
    try { return $text.Substring($start, $end - $start + 1) | ConvertFrom-Json }
    catch { return $null }
}

# ── Read ─────────────────────────────────────────────────────────────────────

function Get-FleetTargets {
    [OutputType([FleetTarget[]])]
    param([switch]$Silent)

    $raw  = Invoke-FltTcpkg -ArgList @('remote','list','--as-json') -Silent:$Silent
    $json = ConvertFrom-FltTcpkgJson $raw
    if ($null -eq $json) { return @() }

    return @($json | ForEach-Object {
        $ht = @{}
        foreach ($prop in $_.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        $jName = [string]$ht['Name']
        $jAddr = [string]$ht['Host']
        $jPort = if ($ht['Port']) { [int]$ht['Port'] } else { 22 }
        $jUser = [string]$ht['User']
        $jIA   = [bool]($ht['InternetAccess'] -eq $true)
        [FleetTarget]::new($jName, $jAddr, $jPort, $jUser, $jIA)
    })
}

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

# Test all targets in parallel; updates $Script:FleetTargets Reachable field.
function Update-FleetReachability {
    param([FleetTarget[]]$Targets)
    $results = $Targets | ForEach-Object -Parallel {
        $t    = $_
        $tcp  = $null
        $ok   = $false
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $ar  = $tcp.BeginConnect($t.Address, $t.Port, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
            $tcp.Close()
        } catch {}
        [pscustomobject]@{ Name = $t.Name; Reachable = $ok }
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
        [bool]   $InternetAccess = $true
    )
    $argList = @('remote','add','-n',$Name,'--host',$HostAddress,'--port',$Port,'-u',$User)
    if ($PlainPassword) { $argList += '--password-stdin' }
    if ($KeyFile)       { $argList += '-k',$KeyFile }
    if ($InternetAccess) { $argList += '--internet-access' }
    $argList += '-y'

    if ($PlainPassword) {
        $PlainPassword | & (Get-FltTcpkgExe) @argList 2>&1 | Out-Null
        $Script:FltLastExit = $LASTEXITCODE
    } else {
        Invoke-FltTcpkg -ArgList $argList | Out-Null
    }
    return $Script:FltLastExit -eq 0
}

function Edit-FleetTarget {
    param(
        [string] $Name,
        [string] $NewName        = '',
        [string] $NewHost        = '',
        [int]    $NewPort        = 0,
        [string] $NewUser        = '',
        [string] $PlainPassword  = '',
        [object]  $InternetAccess = $null   # pass $true/$false to update, $null to leave unchanged
    )
    $argList = @('remote','edit',$Name)
    if ($NewName)         { $argList += '--new-name',$NewName }
    if ($NewHost)         { $argList += '--host',$NewHost }
    if ($NewPort)         { $argList += '--port',$NewPort }
    if ($NewUser)         { $argList += '-u',$NewUser }
    if ($PlainPassword)   { $argList += '--password-stdin' }
    if ($null -ne $InternetAccess) {
        # --internet-access is a boolean flag: presence=true, absence=false
        # To explicitly set false we must pass the value
        $argList += '--internet-access', $(if ($InternetAccess) { 'True' } else { 'False' })
    }
    $argList += '-y'

    if ($PlainPassword) {
        $PlainPassword | & (Get-FltTcpkgExe) @argList 2>&1 | Out-Null
        $Script:FltLastExit = $LASTEXITCODE
    } else {
        Invoke-FltTcpkg -ArgList $argList | Out-Null
    }
    return $Script:FltLastExit -eq 0
}

function Remove-FleetTarget {
    param([string]$Name)
    # tcpkg remote remove does NOT accept -y
    Invoke-FltTcpkg -ArgList @('remote','remove',$Name) | Out-Null
    return $Script:FltLastExit -eq 0
}

function Set-FleetTargetInternetAccess {
    param([string]$Name, [bool]$Value)
    Invoke-FltTcpkg -ArgList @('remote','edit',$Name,
        '--internet-access', $(if ($Value) { 'True' } else { 'False' }), '-y') | Out-Null
    return $Script:FltLastExit -eq 0
}

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
            Password       = ''   # passwords are never exported to CSV
        }
    })
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    return $targets.Count
}

function Import-FleetTargetsCsv {
    param(
        [string] $Path,
        [string] $SharedPassword  = '',
        [switch] $SkipUnreachable
    )
    if (-not (Test-Path $Path)) { return [pscustomobject]@{ Added=0; Updated=0; Skipped=0; Errors=@() } }

    $rows    = Import-Csv -Path $Path -Encoding UTF8
    $current = @(Get-FleetTargets -Silent)
    $added   = 0; $updated = 0; $skipped = 0; $errors = @()

    foreach ($row in $rows) {
        $name     = $row.Name.Trim()
        $hostAddr = if ($row.Address) { $row.Address.Trim() } elseif ($row.Host) { $row.Host.Trim() } else { '' }
        $port     = if ($row.Port) { [int]$row.Port } else { 22 }
        $user     = $row.User.Trim()
        $ia       = $row.InternetAccess.Trim() -eq 'True'
        $pwd      = if ($row.Password) { $row.Password } else { $SharedPassword }

        # Connectivity check
        if ($SkipUnreachable) {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $ar  = $tcp.BeginConnect($hostAddr, $port, $null, $null)
            $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
            $tcp.Close()
            if (-not $ok) { $skipped++; continue }
        }

        $existing = $current | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($existing) {
            # Only update changed fields
            $changed = $existing.Address -ne $hostAddr -or $existing.Port -ne $port -or
                       $existing.User -ne $user -or $existing.InternetAccess -ne $ia
            if ($changed -or $pwd) {
                if ($changed -and -not $pwd) {
                    # Can update without password if only non-credential fields changed
                    $ok = Edit-FleetTarget -Name $name -NewHost $hostAddr -NewPort $port `
                              -NewUser $user -InternetAccess $ia
                } else {
                    $ok = Edit-FleetTarget -Name $name -NewHost $hostAddr -NewPort $port `
                              -NewUser $user -PlainPassword $pwd -InternetAccess $ia
                }
                if ($ok) { $updated++ } else { $errors += "Failed to update: $name" }
            }
        } else {
            if (-not $pwd) {
                $errors += "Skipped $name`: no password provided for new target"
                $skipped++
                continue
            }
            $ok = Add-FleetTarget -Name $name -HostAddress $hostAddr -Port $port -User $user `
                      -PlainPassword $pwd -InternetAccess $ia
            if ($ok) { $added++ } else { $errors += "Failed to add: $name" }
        }
    }

    return [pscustomobject]@{ Added=$added; Updated=$updated; Skipped=$skipped; Errors=$errors }
}