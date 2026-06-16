# =============================================================================
#  TcFltPkgMgr — Sort and Filter Helpers
#  Generic sort/filter for any dashboard list.
#  Sort state and filter state are stored per-dashboard in script-scope vars.
#
#  Sort keys:    * to open sort picker, column number, then 1=asc / 2=desc
#  Filter keys:  / to open filter picker, column number, then value prompt
#                0 to clear active filter
#
#  Sort indicator in column headers: Name ▲  or  Status ▼
#  Active filter shown in result row: [Filter: Status = online]  7 → 3 targets
# =============================================================================

# ── Sort / Filter state ────────────────────────────────────────────────────────

# Each dashboard gets its own sort+filter state hashtable.
# Initialize one with:  $state = New-FltSortFilterState
function New-FltSortFilterState {
    return @{
        SortColumn  = ''       # property name, e.g. 'Name'
        SortDesc    = $false
        FilterColumn = ''      # property name, e.g. 'Reachable'
        FilterValue  = ''      # value to match (case-insensitive contains)
    }
}

# ── Sort ──────────────────────────────────────────────────────────────────────

# Apply sort to an array of objects. Returns sorted array.
function Invoke-FltSort {
    param(
        [object[]] $Items,
        [string]   $Column,
        [bool]     $Descending = $false
    )
    if (-not $Column -or -not $Items) { return $Items }
    if ($Descending) {
        return @($Items | Sort-Object -Property $Column -Descending)
    } else {
        return @($Items | Sort-Object -Property $Column)
    }
}

# Return a column header string with sort indicator appended if active.
function Get-FltSortHeader {
    param([string]$Label, [string]$Column, [hashtable]$State)
    if ($State.SortColumn -eq $Column) {
        $arrow = if ($State.SortDesc) { ' ▼' } else { ' ▲' }
        return "$Label$arrow"
    }
    return $Label
}

# Interactive sort picker — shows column list, gets column choice, then direction.
# Returns $true if sort state was changed, $false if cancelled.
function Invoke-FltSortPicker {
    param(
        [string[]]   $Columns,      # display names in order
        [string[]]   $Properties,   # matching property names
        [hashtable]  $State         # sort/filter state to update
    )

    Write-Host ''
    Write-Host '  Sort by:' -ForegroundColor Cyan

    $pageSize = 9
    $page     = 0
    $totalPages = [Math]::Ceiling($Columns.Count / $pageSize)

    while ($true) {
        $offset = $page * $pageSize
        $pageItems = $Columns[$offset..([Math]::Min($offset + $pageSize - 1, $Columns.Count - 1))]

        for ($i = 0; $i -lt $pageItems.Count; $i++) {
            $num = $i + 1
            $col = $pageItems[$i]
            $active = $Properties[$offset + $i] -eq $State.SortColumn
            $marker = if ($active) { $(if ($State.SortDesc) { ' ▼' } else { ' ▲' }) } else { '' }
            Write-Host ("   {0}. {1}{2}" -f $num, $col, $marker)
        }
        if ($totalPages -gt 1 -and $page -lt $totalPages - 1) {
            Write-Host "  10. More..."
        }
        if ($State.SortColumn) { Write-Host '   0. Clear sort' } else { Write-Host '   0. Cancel' }
        Write-Host ''

        $r = (Read-Host '  Column').Trim()

        if ($r -eq '0') {
            if ($State.SortColumn) {
                $State.SortColumn = ''
                $State.SortDesc   = $false
            }
            return $true
        }

        if ($r -eq '10' -and $totalPages -gt 1 -and $page -lt $totalPages - 1) {
            $page++; continue
        }

        if ($r -match '^\d+$') {
            $idx = [int]$r - 1 + $offset
            if ($idx -ge 0 -and $idx -lt $Properties.Count) {
                $prop = $Properties[$idx]
                # Toggle direction if same column, else default ascending
                if ($State.SortColumn -eq $prop) {
                    $State.SortDesc = -not $State.SortDesc
                } else {
                    $State.SortColumn = $prop
                    $State.SortDesc   = $false
                }

                # Ask direction
                Write-Host ''
                Write-Host "  Sort '$($Columns[$idx])':   1. A → Z / Low → High   2. Z → A / High → Low" -ForegroundColor Cyan
                $d = (Read-Host '  Direction (blank = keep current)').Trim()
                if ($d -eq '1') { $State.SortDesc = $false }
                if ($d -eq '2') { $State.SortDesc = $true  }
                return $true
            }
        }
        Write-Host '  Invalid choice.' -ForegroundColor Red
    }
}

# ── Filter ────────────────────────────────────────────────────────────────────

# Apply filter to an array of objects. Case-insensitive contains match.
# Returns filtered array and count of removed items.
function Invoke-FltFilter {
    param(
        [object[]] $Items,
        [string]   $Column,
        [string]   $Value
    )
    if (-not $Column -or -not $Value -or -not $Items) { return $Items }
    return @($Items | Where-Object {
        $prop = $_.$Column
        if ($null -eq $prop) { return $false }
        [string]$prop -like "*$Value*"
    })
}

# Return a filter status string for the result row.
# e.g. "  [Filter: Reachable = online]   7 → 3 targets"
function Get-FltFilterStatus {
    param(
        [hashtable] $State,
        [int]       $TotalCount,
        [int]       $FilteredCount
    )
    if (-not $State.FilterColumn) { return '' }
    return "  [Filter: $($State.FilterColumn) = '$($State.FilterValue)']   $TotalCount → $FilteredCount targets"
}

# Interactive filter picker — shows column list, then prompts for value.
# Returns $true if filter state was changed.
function Invoke-FltFilterPicker {
    param(
        [string[]]  $Columns,
        [string[]]  $Properties,
        [hashtable] $State
    )

    Write-Host ''
    Write-Host '  Filter by:' -ForegroundColor Cyan

    $page     = 0
    $pageSize = 9
    $totalPages = [Math]::Ceiling($Columns.Count / $pageSize)

    while ($true) {
        $offset    = $page * $pageSize
        $pageItems = $Columns[$offset..([Math]::Min($offset + $pageSize - 1, $Columns.Count - 1))]

        for ($i = 0; $i -lt $pageItems.Count; $i++) {
            $num    = $i + 1
            $col    = $pageItems[$i]
            $active = $Properties[$offset + $i] -eq $State.FilterColumn
            $marker = if ($active) { "  ← active: '$($State.FilterValue)'" } else { '' }
            Write-Host ("   {0}. {1}{2}" -f $num, $col, $marker)
        }
        if ($totalPages -gt 1 -and $page -lt $totalPages - 1) {
            Write-Host '  10. More...'
        }
        if ($State.FilterColumn) { Write-Host '   0. Clear filter' } else { Write-Host '   0. Cancel' }
        Write-Host ''

        $r = (Read-Host '  Column').Trim()

        if ($r -eq '0') {
            $State.FilterColumn = ''
            $State.FilterValue  = ''
            return $true
        }

        if ($r -eq '10' -and $totalPages -gt 1 -and $page -lt $totalPages - 1) {
            $page++; continue
        }

        if ($r -match '^\d+$') {
            $idx = [int]$r - 1 + $offset
            if ($idx -ge 0 -and $idx -lt $Properties.Count) {
                $prop = $Properties[$idx]
                Write-Host ''
                $current = if ($State.FilterColumn -eq $prop) { " (current: '$($State.FilterValue)')" } else { '' }
                Write-Host "  Filter value$current (blank to cancel):" -ForegroundColor Cyan
                $val = (Read-Host '  Value').Trim()
                if ($val) {
                    $State.FilterColumn = $prop
                    $State.FilterValue  = $val
                    return $true
                }
                return $false
            }
        }
        Write-Host '  Invalid choice.' -ForegroundColor Red
    }
}