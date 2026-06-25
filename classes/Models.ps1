# =============================================================================
#  TcFltPkgMgr — Data Models
#  Pure data classes. No tcpkg calls, no console output, no business logic.
# =============================================================================

class FleetTarget {
    [string] $Name
    [string] $Address
    [int]    $Port
    [string] $User
    [bool]   $InternetAccess
    [string] $Reachable       # 'checking' | 'online' | 'offline' | 'unknown'

    # Phase 1 — extended fields for multi-OS / container fleet support
    [string] $OS              # 'windows' | 'linux' | 'macos'
    [string] $TargetType      # 'physical' | 'vm' | 'container'
    [string] $PackageManager  # 'tcpkg' | 'winget' | 'both' | 'apt' | 'yum' | 'dnf' | 'apk' | ''
    [string] $DockerHost      # name of the FleetTarget that is the Docker host (containers only)
    [string] $ContainerName   # Docker container name or ID (containers only)
    [string] $ComposeFile     # relative path to compose file from TcFltPkgMgr root (containers only)
    [string] $ComposeService  # service name within the compose file (containers only)
    [string] $ComposeProject  # --project-name for docker compose (derived from filename)
    [string] $VmxPath         # absolute path to .vmx file (VM targets only, operator-local)

    FleetTarget() {
        $this.Port          = 22
        $this.Reachable     = 'unknown'
        $this.OS            = 'windows'
        $this.TargetType    = 'physical'
        $this.PackageManager = ''
        $this.DockerHost    = ''
        $this.ContainerName = ''
        $this.ComposeFile   = ''
        $this.ComposeService = ''
        $this.ComposeProject = ''
        $this.VmxPath        = ''
    }

    FleetTarget([string]$Name, [string]$Address, [int]$Port,
                [string]$User, [bool]$InternetAccess) {
        $this.Name           = $Name
        $this.Address        = $Address
        $this.Port           = $Port
        $this.User           = $User
        $this.InternetAccess = $InternetAccess
        $this.Reachable      = 'unknown'
        $this.OS             = 'windows'
        $this.TargetType     = 'physical'
        $this.PackageManager = ''
        $this.DockerHost     = ''
        $this.ContainerName  = ''
        $this.ComposeFile    = ''
        $this.ComposeService = ''
        $this.ComposeProject = ''
        $this.VmxPath        = ''
    }

    # Returns the effective package manager — resolves empty string to OS default
    EffectivePackageManager() {
        if ($this.PackageManager -and $this.PackageManager -ne '') {
            $this.PackageManager
        } elseif ($this.OS -eq 'windows') {
            'tcpkg'
        } else {
            'apt'
        }
    }
    # Returns a short OS display string for dashboard columns
    OsDisplay() {
        if ($this.OS -eq 'linux')  { 'Lnx' }
        elseif ($this.OS -eq 'macos')  { 'Mac' }
        else { 'Win' }
    }

    # Returns a short type display string for dashboard columns
    TypeDisplay() {
        if ($this.TargetType -eq 'vm')        { 'VM'   }
        elseif ($this.TargetType -eq 'container') { 'Cntr' }
        else { 'Phys' }
    }

    # Returns true when this target is a Docker container
    IsContainer() {
        $this.TargetType -eq 'container'
    }

    # Returns the display address — containers show host/container
    EffectiveAddress() {
        if ($this.TargetType -eq 'container' -and $this.DockerHost -and $this.ContainerName) {
            "$($this.DockerHost)/$($this.ContainerName)"
        } else {
            $this.Address
        }
    }

    InternetAccessDisplay() {
        if ($this.InternetAccess) { 'Yes' } else { 'No' }
    }

    ReachableIcon() {
        if     ($this.Reachable -eq 'online')   { [char]0x25CF }   # ●
        elseif ($this.Reachable -eq 'offline')  { [char]0x2715 }   # ✕
        elseif ($this.Reachable -eq 'checking') { [char]0x25CB }   # ○
        else                                     { '?' }
    }
}

class PackageState {
    [string] $TargetName
    [string] $PackageName
    [string] $InstalledVersion   # '' if not installed
    [string] $FeedVersion        # '' if not in feed
    [string] $Status             # 'not-installed' | 'up-to-date' | 'upgradable' | 'newer-than-feed' | 'unknown'

    PackageState() {}

    PackageState([string]$TargetName, [string]$PackageName) {
        $this.TargetName  = $TargetName
        $this.PackageName = $PackageName
        $this.Status      = 'unknown'
    }

    StatusDisplay() {
        if     ($this.Status -eq 'not-installed')   { 'not installed' }
        elseif ($this.Status -eq 'up-to-date')      { "v$($this.InstalledVersion)  up to date" }
        elseif ($this.Status -eq 'upgradable')      { "v$($this.InstalledVersion)  -> v$($this.FeedVersion)" }
        elseif ($this.Status -eq 'newer-than-feed') { "v$($this.InstalledVersion)  (feed: v$($this.FeedVersion))" }
        else                                         { $this.Status }
    }

    StatusColor() {
        if     ($this.Status -eq 'not-installed')   { 'Dark'   }
        elseif ($this.Status -eq 'up-to-date')      { 'Green'  }
        elseif ($this.Status -eq 'upgradable')      { 'Yellow' }
        elseif ($this.Status -eq 'newer-than-feed') { 'Cyan'   }
        else                                         { ''       }
    }
}

class FleetPackageSummary {
    [string]         $PackageName
    [string]         $FeedVersion
    [string]         $FeedSource
    [PackageState[]] $States       # one per target, same order as fleet

    FleetPackageSummary() { $this.States = @() }
}

class FeedDefinition {
    [string] $Name
    [string] $Url
    [int]    $Priority
    [string] $Username   # '' if unauthenticated
    [bool]   $IsCustom   # false = Beckhoff preset, true = local custom

    FeedDefinition() {}

    FeedDefinition([string]$Name, [string]$Url, [int]$Priority,
                   [string]$Username, [bool]$IsCustom) {
        $this.Name     = $Name
        $this.Url      = $Url
        $this.Priority = $Priority
        $this.Username = $Username
        $this.IsCustom = $IsCustom
    }

    IsAuthenticated() { -not [string]::IsNullOrEmpty($this.Username) }
}

class LiveSource {
    [string] $Name
    [int]    $Priority
    [bool]   $Enabled
    [string] $Auth        # 'Authenticated' | 'Unauthenticated'
    [string] $Url

    LiveSource() {}
}

class FleetProfile {
    [string]            $Name
    [string[]]          $TargetNames
    [ProfilePackage[]]  $ExpectedPackages

    FleetProfile() { $this.TargetNames = @(); $this.ExpectedPackages = @() }
}

class ProfilePackage {
    [string] $Name
    [string] $Version   # '' means latest

    ProfilePackage() {}
    ProfilePackage([string]$Name, [string]$Version) {
        $this.Name    = $Name
        $this.Version = $Version
    }
}

class BatchResult {
    [string] $TargetName
    [string] $Action
    [string] $PackageSpec
    [string] $PackageManager  # 'tcpkg' | 'winget' | 'ansible' | 'docker-exec' | 'docker-lifecycle'
    [string] $Status          # 'OK' | 'OK (push)' | 'Failed (N)' | 'Timed out' | 'Skipped' | 'Running'
    [double] $DurationSec
    [bool]   $TimedOut
    [string] $Note

    BatchResult() {}
}

class CommandEntry {
    [string]   $Timestamp    # ISO 8601
    [string]   $SessionId
    [string]   $Target
    [string]   $Mode         # 'live' | 'read-only'
    [string]   $Command
    [int]      $ExitCode
    [double]   $DurationSec
    [string]   $Output       # null unless captureOutput = true

    CommandEntry() {}
}

# ── Standalone helper functions ────────────────────────────────────────────────
# PS7 class methods without declared return types cannot be reliably assigned to
# variables. These functions wrap class method logic for use outside expression
# context (e.g. in FleetExecutor bucket routing and test assertions).

# Returns the effective package manager for a FleetTarget.
# Resolves '' to 'tcpkg' (Windows) or 'apt' (Linux/macOS).
function Get-FltEffectivePackageManager {
    param([FleetTarget]$Target)
    if ($Target.PackageManager -and $Target.PackageManager -ne '') {
        return $Target.PackageManager
    } elseif ($Target.OS -eq 'windows' -or $Target.OS -eq '') {
        return 'tcpkg'
    } else {
        return 'apt'
    }
}

function Get-FltEffectiveAddress {
    param([FleetTarget]$Target)
    if ($Target.TargetType -eq 'container' -and $Target.DockerHost -and $Target.ContainerName) {
        return "$($Target.DockerHost)/$($Target.ContainerName)"
    }
    return $Target.Address
}

function Get-FltIsContainer {
    param([FleetTarget]$Target)
    return $Target.TargetType -eq 'container'
}

function Get-FltTypeDisplay {
    param([FleetTarget]$Target)
    if     ($Target.TargetType -eq 'vm')        { return 'VM'   }
    elseif ($Target.TargetType -eq 'container') { return 'Cntr' }
    else                                         { return 'Phys' }
}

function Get-FltOsDisplay {
    param([FleetTarget]$Target)
    if     ($Target.OS -eq 'linux') { return 'Lnx' }
    elseif ($Target.OS -eq 'macos') { return 'Mac' }
    else                            { return 'Win' }
}