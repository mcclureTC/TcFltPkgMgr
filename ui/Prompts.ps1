# =============================================================================
#  TcFltPkgMgr — Prompts
#  All user input collection. Pure input — no data fetching, no screen painting.
#  Every function here reads from the user and returns a typed value or $null.
#
#  Global UX rules (enforced here):
#    - All selections are numbers (0 = always Back/Cancel)
#    - Fixed operations: 1, 2, 3 ...
#    - Variable items (targets, packages, sources): start at 11
#    - Yes/No: [1] Yes  [0] No
# =============================================================================

# Read a single required value. Returns $null if the user leaves it blank and
# -CancelOnBlank is set; loops if required but blank; returns '' if -AllowEmpty.
function Read-FltValue {
    param([string]$Prompt, [switch]$AllowEmpty, [switch]$CancelOnBlank)
    while ($true) {
        $v = (Read-Host "  $Prompt").Trim()
        if ([string]::IsNullOrWhiteSpace($v)) {
            if ($AllowEmpty)    { return $v }
            if ($CancelOnBlank) { return $null }
            Write-Host '  A value is required.' -ForegroundColor Yellow
        } else {
            return $v
        }
    }
}

# [1] Yes  [0] No prompt. Returns $true/$false.
function Read-FltYesNo {
    param([string]$Prompt, [switch]$DefaultYes)
    $default = if ($DefaultYes) { '1' } else { '0' }
    while ($true) {
        $r = (Read-Host "  $Prompt  [1] Yes  [0] No  (default $default)").Trim()
        if ($r -eq '')  { return ($default -eq '1') }
        if ($r -eq '1') { return $true }
        if ($r -eq '0') { return $false }
        Write-Host '  Please enter 1 or 0.' -ForegroundColor Yellow
    }
}

# Parse a selection string like "1,3,5..8" or "11-14" into a flat list of ints.
# Validates that each value is in [1..$Max].
function Expand-FltSelectionRange {
    param([string]$RawInput, [int]$Max)
    $indices = [System.Collections.Generic.SortedSet[int]]::new()
    foreach ($part in ($RawInput -split '[,\s]+')) {
        $part = $part.Trim()
        if (-not $part) { continue }
        if ($part -match '^(\d+)[\.\-]+(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -gt $to) { $from,$to = $to,$from }
            for ($i = $from; $i -le $to; $i++) {
                if ($i -ge 1 -and $i -le $Max) { [void]$indices.Add($i) }
            }
        } elseif ($part -match '^\d+$') {
            $n = [int]$part
            if ($n -ge 1 -and $n -le $Max) { [void]$indices.Add($n) }
        }
    }
    return @($indices)
}

# Numbered choice prompt. $Items is an array; displays them with base-$Base numbering.
# Returns the selected item or $null if the user enters 0 or blank.
function Read-FltNumberedChoice {
    param(
        [object[]] $Items,
        [string]   $Prompt  = 'Choice',
        [int]      $Base    = 11,          # 11 for variable items, 1 for fixed ops
        [int]      $ZeroExit = 0           # what 0 means in display text
    )
    while ($true) {
        $r = (Read-Host "  $Prompt").Trim()
        if ($r -eq '' -or $r -eq '0') { return $null }
        if ($r -match '^\d+$') {
            $n = [int]$r
            $idx = $n - $Base
            if ($idx -ge 0 -and $idx -lt $Items.Count) {
                return $Items[$idx]
            }
        }
        Write-Host ("  Enter a number between $Base and $($Base + $Items.Count - 1), or 0 to cancel.") `
            -ForegroundColor Yellow
    }
}

# Multi-select from a list. Returns selected items array or @() if cancelled.
# Supports ranges: "11,13,15..17"
function Read-FltMultiSelect {
    param(
        [object[]] $Items,
        [string]   $Prompt = 'Select (numbers/ranges, blank to cancel)',
        [int]      $Base   = 11
    )
    $raw = (Read-Host "  $Prompt").Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }

    # Map back from base-N to 0-indexed
    $indices = Expand-FltSelectionRange -RawInput $raw -Max ($Base + $Items.Count - 1)
    $result  = @($indices | Where-Object { $_ -ge $Base } | ForEach-Object { $Items[$_ - $Base] })
    return $result
}

# Prompt for a package search term.
function Read-FltPackageSearch {
    param([string]$Prompt = 'Package name or search term (blank to cancel):')
    return Read-FltValue -Prompt $Prompt -CancelOnBlank
}

# Prompt for a timeout value with a default.
function Read-FltTimeout {
    param([int]$Default = 1800)
    $r = (Read-Host "  Timeout in seconds per target (blank = $Default)").Trim()
    if ([string]::IsNullOrWhiteSpace($r) -or $r -notmatch '^\d+$') { return $Default }
    return [int]$r
}

# Prompt for SSH password and return a PSCredential.
function Read-FltSshPassword {
    param([string]$Username)
    Write-Host ("  Enter the SSH password for '{0}'." -f $Username) -ForegroundColor Cyan
    $plain = (Read-Host "  Password for $Username").Trim()
    $sec   = ConvertTo-SecureString $plain -AsPlainText -Force
    return [System.Management.Automation.PSCredential]::new($Username, $sec)
}