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

    FleetTarget() { $this.Port = 22; $this.Reachable = 'unknown' }

    FleetTarget([string]$Name, [string]$Address, [int]$Port,
                [string]$User, [bool]$InternetAccess) {
        $this.Name           = $Name
        $this.Address        = $Address
        $this.Port           = $Port
        $this.User           = $User
        $this.InternetAccess = $InternetAccess
        $this.Reachable      = 'unknown'
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
    [string] $Status      # 'OK' | 'OK (push)' | 'Failed (N)' | 'Timed out' | 'Skipped' | 'Running'
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