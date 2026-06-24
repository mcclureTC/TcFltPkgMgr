# =============================================================================
#  TcFltPkgMgr — Integration Tests
#  Tests that exercise real infrastructure: file I/O, SSH, tcpkg, credentials.
#  Each suite is a function that accepts optional context ($Target, $Creds)
#  and returns a [pscustomobject]@{ Passed; Failed; Warned; Results[] }
#
#  Test quality rules (same as Diagnostics.ps1):
#  - Test behaviour, not existence.
#  - Every FAIL must tell the operator what to do about it.
#  - Suites must clean up after themselves (remove test files, restore state).
#  - Suites must be idempotent — safe to run multiple times.
#  - Network-dependent suites must gracefully handle offline targets.
# =============================================================================

# ── Shared result helpers ──────────────────────────────────────────────────────

# Create a fresh result accumulator for a suite.
function _IT_NewResult {
    return [pscustomobject]@{
        Passed  = 0
        Failed  = 0
        Warned  = 0
        Skipped = 0
        Results = [System.Collections.Generic.List[pscustomobject]]::new()
    }
}

# Record a PASS result into an accumulator.
function _IT_Pass {
    param($Accum, [string]$Label)
    $Accum.Passed++
    $Accum.Results.Add([pscustomobject]@{ Status='PASS'; Label=$Label; Detail='' })
    Write-Host ("  {0,-62} " -f $Label) -NoNewline
    Write-Host 'PASS' -ForegroundColor Green
}

# Record a FAIL result into an accumulator.
function _IT_Fail {
    param($Accum, [string]$Label, [string]$Detail = '')
    $Accum.Failed++
    $Accum.Results.Add([pscustomobject]@{ Status='FAIL'; Label=$Label; Detail=$Detail })
    Write-Host ("  {0,-62} " -f $Label) -NoNewline
    Write-Host 'FAIL' -ForegroundColor Red
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor Yellow }
}

# Record a WARN result into an accumulator.
function _IT_Warn {
    param($Accum, [string]$Label, [string]$Detail = '')
    $Accum.Warned++
    $Accum.Results.Add([pscustomobject]@{ Status='WARN'; Label=$Label; Detail=$Detail })
    Write-Host ("  {0,-62} " -f $Label) -NoNewline
    Write-Host 'WARN' -ForegroundColor Yellow
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
}

# Record a SKIP result — check not run because a prerequisite was not met.
# Increments Warned so the suite total reflects the skipped check.
function _IT_Skip {
    param($Accum, [string]$Label, [string]$Reason = '')
    $Accum.Skipped++
    $Accum.Results.Add([pscustomobject]@{ Status='SKIP'; Label=$Label; Detail=$Reason })
    Write-Host ("  {0,-62} " -f $Label) -NoNewline
    Write-Host 'SKIP' -ForegroundColor DarkGray
    if ($Reason) { Write-Host "       $Reason" -ForegroundColor DarkGray }
}

# Print a section header within a suite.
function _IT_Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "  $('-' * 62)" -ForegroundColor DarkGray
}

function Get-IT_Suites {
    return @(
        [pscustomobject]@{
            Id          = 11
            Name        = 'File I/O'
            Description = 'CSV round-trip, sort persistence, filter correctness, UI Config persistence'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local file system
            Function    = 'Invoke-IT_FileIO'
            CheckCount  = 25
        },
        [pscustomobject]@{
            Id          = 12
            Name        = 'Pagination and target selection'
            Description = 'Page slicing, target numbering, sort-aware selection'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local logic
            Function    = 'Invoke-IT_Pagination'
            CheckCount  = 6
        },
        [pscustomobject]@{
            Id          = 13
            Name        = 'SSH connectivity'
            Description = 'TCP check, SSH session, remote command, tcpkg path on target'
            NeedsTarget = $true
            NeedsSSH    = $true
            PerTarget   = $true    # runs against each selected target
            Function    = 'Invoke-IT_SSH'
            CheckCount  = 5
        },
        [pscustomobject]@{
            Id          = 14
            Name        = 'Read-only mode'
            Description = 'tcpkg blocked, batch produces [read-only] status, credentials exempt'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local mode flag
            Function    = 'Invoke-IT_ReadOnly'
            CheckCount  = 4
        },
        [pscustomobject]@{
            Id          = 15
            Name        = 'Log system'
            Description = 'Entry written, retrieved by history, retention preserves current log'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # runs once — tests local log files
            Function    = 'Invoke-IT_Log'
            CheckCount  = 7
        },
        [pscustomobject]@{
            Id          = 16
            Name        = 'Reachability cache'
            Description = 'Cache skip, expiry recheck, optional live cache population'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $true    # optional live check runs per selected target
            Function    = 'Invoke-IT_ReachCache'
            CheckCount  = 4
        }
        [pscustomobject]@{
            Id          = 17
            Name        = 'tcpkg local'
            Description = 'tcpkg exe found, config export, target verify, internet access toggle'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $true    # target-specific tests run per selected target
            Function    = 'Invoke-IT_TcpkgLocal'
            CheckCount  = 9
        },
        [pscustomobject]@{
            Id          = 18
            Name        = 'Package queries'
            Description = 'Package search, version listing, remote status query'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $true    # remote status query runs per target
            Function    = 'Invoke-IT_PackageQueries'
            CheckCount  = 3
        },
        [pscustomobject]@{
            Id          = 19
            Name        = 'WinGet executor'
            Description = 'WinGet available, executor routing logic, package search (if winget installed)'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # routing logic is local; search runs once
            Function    = 'Invoke-IT_WinGet'
            CheckCount  = 11
        },
        [pscustomobject]@{
            Id          = 20
            Name        = 'WinGet live install'
            Description = 'Real install/uninstall via SSH using Invoke-FltWinGetBatch [needs target]'
            NeedsTarget = $true
            NeedsSSH    = $true
            PerTarget   = $true    # runs against each selected target
            Function    = 'Invoke-IT_WinGetLive'
            CheckCount  = 9
        },
        [pscustomobject]@{
            Id          = 21
            Name        = 'Ansible availability'
            Description = 'Ansible mode detection, version, community.docker collection check'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # local check only
            Function    = 'Invoke-IT_Ansible'
            CheckCount  = 7
        },
        [pscustomobject]@{
            Id          = 22
            Name        = 'Docker operator'
            Description = 'Docker Desktop status, start/stop, and operator container checks'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false
            Function    = 'Invoke-IT_DockerOperator'
            CheckCount  = 5
        },
        [pscustomobject]@{
            Id          = 23
            Name        = 'Ansible inventory builder'
            Description = 'New-FltAnsibleInventory: INI generation, groups, auth vars, cleanup'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — synthetic targets only
            Function    = 'Invoke-IT_AnsibleInventory'
            CheckCount  = 13
        },
        [pscustomobject]@{
            Id          = 24
            Name        = 'Ansible playbook builder'
            Description = '_Get-*Playbook: YAML generation, file write, cleanup for all five builders'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — no Ansible required
            Function    = 'Invoke-IT_AnsiblePlaybook'
            CheckCount  = 15
        },
        [pscustomobject]@{
            Id          = 25
            Name        = 'Ansible batch executor'
            Description = 'Invoke-FltAnsibleBatch: read-only mode, output parser, BatchResult shape'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # offline — parser tested directly; live run tested in Phase 5.5+
            Function    = 'Invoke-IT_AnsibleBatch'
            CheckCount  = 13
        },
        [pscustomobject]@{
            Id          = 26
            Name        = 'Fleet executor routing'
            Description = 'Invoke-FleetAction: Ansible/tcpkg/winget/push bucket routing in read-only mode'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — read-only mode exercises bucket logic
            Function    = 'Invoke-IT_FleetRouting'
            CheckCount  = 10
        },
        [pscustomobject]@{
            Id          = 27
            Name        = 'Ansible Vault helpers'
            Description = '_Get-VaultPasswordFile: temp file write/cleanup; Invoke-FltVaultSetup: return shape'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — credential store and temp file only
            Function    = 'Invoke-IT_AnsibleVault'
            CheckCount  = 8
        },
        [pscustomobject]@{
            Id          = 28
            Name        = 'Container executor'
            Description = 'Invoke-FltDockerExecBatch / Lifecycle / Test-FltDockerHostReachable: read-only, routing, result shape'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # offline — live docker exec tested when container targets exist
            Function    = 'Invoke-IT_ContainerExecutor'
            CheckCount  = 13
        },
        [pscustomobject]@{
            Id          = 29
            Name        = 'Container target flow'
            Description = 'Add container target: validation, field inheritance, Save-FltTargets, EffectiveAddress'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — uses synthetic fleet state
            Function    = 'Invoke-IT_ContainerTargetFlow'
            CheckCount  = 8
        },
        [pscustomobject]@{
            Id          = 30
            Name        = 'Batch dashboard pagination'
            Description = 'Show-FleetBatchDashboard: page state, Move-FltBatchPage, summary totals across pages'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — tests script-scope state directly
            Function    = 'Invoke-IT_BatchPagination'
            CheckCount  = 8
        },
        [pscustomobject]@{
            Id          = 31
            Name        = 'Phase 8.0 pre-work'
            Description = 'CommandLog targetType, batch dashboard Type column vars, Read-FltBatchNav, stored action vars'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline
            Function    = 'Invoke-IT_Phase80PreWork'
            CheckCount  = 8
        },
        [pscustomobject]@{
            Id          = 32
            Name        = 'Container Admin menu'
            Description = 'Invoke-ContainerAdminMenu: no-targets guard, docker exec/lifecycle routing, function existence'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # offline — live docker exec tested when container targets exist
            Function    = 'Invoke-IT_ContainerAdminMenu'
            CheckCount  = 10
        },
        [pscustomobject]@{
            Id          = 33
            Name        = 'Compose repository'
            Description = 'ComposeRepository: templates, service parsing, variable substitution, CSV import/export'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline — no docker calls
            Function    = 'Invoke-IT_ComposeRepository'
            CheckCount  = 10
        },
        [pscustomobject]@{
            Id          = 34
            Name        = 'Container target registration'
            Description = '_Register-ContainerTarget: field assignment, ComposeFile/Service/Project, duplicate guard'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline
            Function    = 'Invoke-IT_ContainerTargetReg'
            CheckCount  = 8
        },
        [pscustomobject]@{
            Id          = 35
            Name        = 'Phase 8.10 compose-aware lifecycle'
            Description = '_Get-TargetComposeFile, _Invoke-ComposeOrDockerAction, Invoke-ContainerDeployMenu existence'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline
            Function    = 'Invoke-IT_ComposeLifecycle'
            CheckCount  = 8
        },
        [pscustomobject]@{
            Id          = 36
            Name        = 'Phase 9.1 OS/PM prompts'
            Description = 'Add Target OS/PackageManager fields; Edit flow OS/PM/TargetType; Setup dashboard PM column'
            NeedsTarget = $false
            NeedsSSH    = $false
            PerTarget   = $false   # fully offline
            Function    = 'Invoke-IT_OsPrompts'
            CheckCount  = 8
        }
    )
}

# ── Test suite implementations (split by subsystem) ─────────────────────────
. (Join-Path $PSScriptRoot 'IT-Infrastructure.ps1')
. (Join-Path $PSScriptRoot 'IT-TcpkgWinGet.ps1')
. (Join-Path $PSScriptRoot 'IT-Ansible.ps1')
. (Join-Path $PSScriptRoot 'IT-Containers.ps1')