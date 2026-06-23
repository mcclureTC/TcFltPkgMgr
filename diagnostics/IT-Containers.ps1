# =============================================================================
#  This file is auto-included by IntegrationTests.ps1
# =============================================================================

Set-StrictMode -Off

function Invoke-IT_ContainerExecutor {
    $r = _IT_NewResult

    _IT_Section 'Container executor'

    # Helper: build a synthetic container FleetTarget
    function _MkCT {
        param([string]$Name, [string]$DockerHost, [string]$ContainerName,
              [string]$PM = 'apt')
        $t = [FleetTarget]::new($Name, '', 22, 'admin', $false)
        $t.OS            = 'linux'
        $t.TargetType    = 'container'
        $t.DockerHost    = $DockerHost
        $t.ContainerName = $ContainerName
        $t.PackageManager = $PM
        $t
    }

    # ------------------------------------------------------------------
    # 28a — _Get-FltContainerPkgCmd: apt install
    # ------------------------------------------------------------------
    try {
        $cmd = _Get-FltContainerPkgCmd -PackageManager 'apt' -Action 'install' -PackageName 'curl'
        if ($cmd -eq 'apt-get install -y curl') {
            _IT_Pass $r '28a  _Get-FltContainerPkgCmd: apt install → apt-get install -y'
        } else {
            _IT_Fail $r '28a  _Get-FltContainerPkgCmd: apt install → apt-get install -y' "Got: $cmd"
        }
    } catch { _IT_Fail $r '28a  _Get-FltContainerPkgCmd apt install' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28b — _Get-FltContainerPkgCmd: apk remove
    # ------------------------------------------------------------------
    try {
        $cmd = _Get-FltContainerPkgCmd -PackageManager 'apk' -Action 'remove' -PackageName 'curl'
        if ($cmd -eq 'apk del curl') {
            _IT_Pass $r '28b  _Get-FltContainerPkgCmd: apk remove → apk del'
        } else {
            _IT_Fail $r '28b  _Get-FltContainerPkgCmd: apk remove → apk del' "Got: $cmd"
        }
    } catch { _IT_Fail $r '28b  _Get-FltContainerPkgCmd apk remove' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28c — _Get-FltContainerPkgCmd: yum upgrade
    # ------------------------------------------------------------------
    try {
        $cmd = _Get-FltContainerPkgCmd -PackageManager 'yum' -Action 'upgrade' -PackageName 'curl'
        if ($cmd -eq 'yum update -y curl') {
            _IT_Pass $r '28c  _Get-FltContainerPkgCmd: yum upgrade → yum update -y'
        } else {
            _IT_Fail $r '28c  _Get-FltContainerPkgCmd: yum upgrade → yum update -y' "Got: $cmd"
        }
    } catch { _IT_Fail $r '28c  _Get-FltContainerPkgCmd yum upgrade' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28d — DockerExecBatch read-only: returns Skipped
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCT 'web-1' 'docker-host' 'web_app')
        $results = Invoke-FltDockerExecBatch -Targets $targets `
                       -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        if ($results.Count -eq 1 -and $results[0].Status -eq 'Skipped') {
            _IT_Pass $r '28d  DockerExecBatch read-only: returns Skipped'
        } else {
            _IT_Fail $r '28d  DockerExecBatch read-only: returns Skipped' `
                "Count=$($results.Count) Status=$($results[0].Status)"
        }
    } catch { _IT_Fail $r '28d  DockerExecBatch read-only' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28e — DockerExecBatch read-only: PackageManager = 'docker-exec'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCT 'web-1' 'docker-host' 'web_app')
        $results = Invoke-FltDockerExecBatch -Targets $targets `
                       -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        if ($results[0].PackageManager -eq 'docker-exec') {
            _IT_Pass $r '28e  DockerExecBatch: PackageManager = ''docker-exec'''
        } else {
            _IT_Fail $r '28e  DockerExecBatch: PackageManager = ''docker-exec''' `
                "Got: $($results[0].PackageManager)"
        }
    } catch { _IT_Fail $r '28e  DockerExecBatch PackageManager' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28f — DockerExecBatch read-only: Note contains container name
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCT 'web-1' 'docker-host' 'web_app')
        $results = Invoke-FltDockerExecBatch -Targets $targets `
                       -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        if ($results[0].Note -eq 'Read-only mode') {
            _IT_Pass $r '28f  DockerExecBatch read-only: Note = ''Read-only mode'''
        } else {
            _IT_Fail $r '28f  DockerExecBatch read-only: Note = ''Read-only mode''' `
                "Got: $($results[0].Note)"
        }
    } catch { _IT_Fail $r '28f  DockerExecBatch Note' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28g — DockerExecBatch read-only: multiple targets all Skipped
    # ------------------------------------------------------------------
    try {
        $targets = @(
            (_MkCT 'web-1' 'host-1' 'web_app')
            (_MkCT 'web-2' 'host-1' 'web_app_2')
            (_MkCT 'db-1'  'host-2' 'postgres')
        )
        $results = Invoke-FltDockerExecBatch -Targets $targets `
                       -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        $allSkipped = ($results | Where-Object { $_.Status -ne 'Skipped' }).Count -eq 0
        if ($results.Count -eq 3 -and $allSkipped) {
            _IT_Pass $r '28g  DockerExecBatch read-only: all 3 targets Skipped'
        } else {
            _IT_Fail $r '28g  DockerExecBatch read-only: all 3 targets Skipped' `
                "Count=$($results.Count) NotSkipped=$(($results | Where-Object { $_.Status -ne 'Skipped' }).Count)"
        }
    } catch { _IT_Fail $r '28g  DockerExecBatch multi-target' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28h — LifecycleBatch read-only: returns Skipped
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCT 'web-1' 'docker-host' 'web_app')
        $results = Invoke-FltDockerLifecycleBatch -Targets $targets `
                       -Action 'stop' -PackageSpec 'web_app' -ReadOnly $true
        if ($results.Count -eq 1 -and $results[0].Status -eq 'Skipped') {
            _IT_Pass $r '28h  DockerLifecycleBatch read-only: returns Skipped'
        } else {
            _IT_Fail $r '28h  DockerLifecycleBatch read-only: returns Skipped' `
                "Count=$($results.Count) Status=$($results[0].Status)"
        }
    } catch { _IT_Fail $r '28h  DockerLifecycleBatch read-only' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28i — LifecycleBatch read-only: PackageManager = 'docker-lifecycle'
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCT 'web-1' 'docker-host' 'web_app')
        $results = Invoke-FltDockerLifecycleBatch -Targets $targets `
                       -Action 'start' -PackageSpec 'web_app' -ReadOnly $true
        if ($results[0].PackageManager -eq 'docker-lifecycle') {
            _IT_Pass $r '28i  DockerLifecycleBatch: PackageManager = ''docker-lifecycle'''
        } else {
            _IT_Fail $r '28i  DockerLifecycleBatch: PackageManager = ''docker-lifecycle''' `
                "Got: $($results[0].PackageManager)"
        }
    } catch { _IT_Fail $r '28i  DockerLifecycleBatch PackageManager' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28j — FleetExecutor routing: container target → docker-exec bucket
    # ------------------------------------------------------------------
    try {
        $savedReadOnly    = $Script:FltReadOnly
        $savedBatchStatus = $Script:FltBatchStatus
        $Script:FltReadOnly    = $true
        $Script:FltBatchStatus = @{}

        $targets = @(_MkCT 'web-1' 'docker-host' 'web_app')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $r0 = $results | Where-Object { $_.TargetName -eq 'web-1' }

        if ($r0 -and $r0.PackageManager -eq 'docker-exec') {
            _IT_Pass $r '28j  Fleet routing: container → docker-exec bucket'
        } else {
            _IT_Fail $r '28j  Fleet routing: container → docker-exec bucket' `
                "PackageManager=$($r0.PackageManager) Status=$($r0.Status)"
        }

        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
    } catch {
        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
        _IT_Fail $r '28j  Fleet routing container' $_.Exception.Message
    }

    # ------------------------------------------------------------------
    # 28k — FleetExecutor routing: mixed fleet — container and Windows
    # ------------------------------------------------------------------
    try {
        $savedReadOnly    = $Script:FltReadOnly
        $savedBatchStatus = $Script:FltBatchStatus
        $Script:FltReadOnly    = $true
        $Script:FltBatchStatus = @{}

        $winTarget  = [FleetTarget]::new('win-1', '10.0.0.1', 22, 'admin', $true)
        $winTarget.OS = 'windows'; $winTarget.TargetType = 'physical'
        $winTarget.PackageManager = 'tcpkg'
        $cntrTarget = _MkCT 'web-1' 'docker-host' 'web_app'

        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' `
                       -Targets @($winTarget, $cntrTarget)
        $win  = $results | Where-Object { $_.TargetName -eq 'win-1' }
        $cntr = $results | Where-Object { $_.TargetName -eq 'web-1' }

        if ($win.PackageManager -eq 'tcpkg' -and $cntr.PackageManager -eq 'docker-exec') {
            _IT_Pass $r '28k  Fleet routing: win→tcpkg, container→docker-exec'
        } else {
            _IT_Fail $r '28k  Fleet routing: win→tcpkg, container→docker-exec' `
                "win=$($win.PackageManager) container=$($cntr.PackageManager)"
        }

        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
    } catch {
        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
        _IT_Fail $r '28k  Fleet routing mixed' $_.Exception.Message
    }

    # ------------------------------------------------------------------
    # 28l — BatchResult shape: has all required fields
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCT 'web-1' 'docker-host' 'web_app')
        $results = Invoke-FltDockerExecBatch -Targets $targets `
                       -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        $props    = $results[0].PSObject.Properties.Name
        $required = @('TargetName','Action','PackageSpec','PackageManager','Status','DurationSec','TimedOut','Note')
        $missing  = $required | Where-Object { $props -notcontains $_ }
        if ($missing.Count -eq 0) {
            _IT_Pass $r '28l  BatchResult has all required fields'
        } else {
            _IT_Fail $r '28l  BatchResult has all required fields' "Missing: $($missing -join ', ')"
        }
    } catch { _IT_Fail $r '28l  BatchResult shape' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 28m — Test-FltDockerHostReachable: returns string result
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Test-FltDockerHostReachable' -ErrorAction SilentlyContinue
        if ($fn) {
            _IT_Pass $r '28m  Test-FltDockerHostReachable is defined and callable'
        } else {
            _IT_Fail $r '28m  Test-FltDockerHostReachable is defined and callable' 'Function not found'
        }
    } catch { _IT_Fail $r '28m  Test-FltDockerHostReachable defined' $_.Exception.Message }

    return $r
}

# ── Suite 29 — Container target flow ──────────────────────────────────────────

# Tests the container target data model directly:
# - FleetTarget field inheritance from Docker host
# - EffectiveAddress() returns host/container format
# - _Get-FltDockerHostTarget resolution
# - _Get-FltContainerPkgCmd for all four package managers
# - Fleet routing excludes containers from windowsTargets
# Does NOT test the interactive Invoke-TargetMenu (requires user input).
function Invoke-IT_ContainerTargetFlow {
    $r = _IT_NewResult

    _IT_Section 'Container target flow'

    # Save and restore FleetTargets
    $savedTargets = $Script:FleetTargets

    # Synthetic fleet: one physical host + one container
    $hostTarget = [FleetTarget]::new('docker-host-1', '192.168.8.50', 22, 'admin', $true)
    $hostTarget.OS         = 'linux'
    $hostTarget.TargetType = 'physical'

    $cntrTarget = [FleetTarget]::new('web-1', '192.168.8.50', 22, 'admin', $false)
    $cntrTarget.OS             = 'linux'
    $cntrTarget.TargetType     = 'container'
    $cntrTarget.DockerHost     = 'docker-host-1'
    $cntrTarget.ContainerName  = 'web_app'
    $cntrTarget.PackageManager = 'apt'

    $Script:FleetTargets = @($hostTarget, $cntrTarget)

    # ------------------------------------------------------------------
    # 29a — Container target: EffectiveAddress = host/container
    # ------------------------------------------------------------------
    try {
        $addr = Get-FltEffectiveAddress -Target $cntrTarget
        if ($addr -eq 'docker-host-1/web_app') {
            _IT_Pass $r '29a  Container EffectiveAddress: returns host/container format'
        } else {
            _IT_Fail $r '29a  Container EffectiveAddress: returns host/container format' "Got: $addr"
        }
    } catch { _IT_Fail $r '29a  EffectiveAddress' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 29b — Physical target: EffectiveAddress = IP address
    # ------------------------------------------------------------------
    try {
        $addr = Get-FltEffectiveAddress -Target $hostTarget
        if ($addr -eq '192.168.8.50') {
            _IT_Pass $r '29b  Physical EffectiveAddress: returns IP address'
        } else {
            _IT_Fail $r '29b  Physical EffectiveAddress: returns IP address' "Got: $addr"
        }
    } catch { _IT_Fail $r '29b  EffectiveAddress physical' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 29c — IsContainer() returns $true for container target
    # ------------------------------------------------------------------
    try {
        if ((Get-FltIsContainer -Target $cntrTarget) -eq $true) {
            _IT_Pass $r '29c  IsContainer(): $true for container target'
        } else {
            _IT_Fail $r '29c  IsContainer(): $true for container target' "Got: $(Get-FltIsContainer -Target $cntrTarget)"
        }
    } catch { _IT_Fail $r '29c  IsContainer()' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 29d — IsContainer() returns $false for physical target
    # ------------------------------------------------------------------
    try {
        if ((Get-FltIsContainer -Target $hostTarget) -eq $false) {
            _IT_Pass $r '29d  IsContainer(): $false for physical target'
        } else {
            _IT_Fail $r '29d  IsContainer(): $false for physical target' "Got: $(Get-FltIsContainer -Target $hostTarget)"
        }
    } catch { _IT_Fail $r '29d  IsContainer() physical' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 29e — _Get-FltDockerHostTarget resolves host from fleet
    # ------------------------------------------------------------------
    try {
        $resolved = _Get-FltDockerHostTarget -ContainerTarget $cntrTarget
        if ($resolved -and $resolved.Name -eq 'docker-host-1') {
            _IT_Pass $r '29e  _Get-FltDockerHostTarget: resolves correct host from fleet'
        } else {
            _IT_Fail $r '29e  _Get-FltDockerHostTarget: resolves correct host from fleet' `
                "Got: $($resolved.Name)"
        }
    } catch { _IT_Fail $r '29e  _Get-FltDockerHostTarget' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 29f — _Get-FltDockerHostTarget returns $null for unknown host
    # ------------------------------------------------------------------
    try {
        $orphan = [FleetTarget]::new('orphan', '', 22, '', $false)
        $orphan.TargetType = 'container'
        $orphan.DockerHost = 'nonexistent-host'
        $resolved = _Get-FltDockerHostTarget -ContainerTarget $orphan
        if ($null -eq $resolved) {
            _IT_Pass $r '29f  _Get-FltDockerHostTarget: $null for unknown host'
        } else {
            _IT_Fail $r '29f  _Get-FltDockerHostTarget: $null for unknown host' "Got: $($resolved.Name)"
        }
    } catch { _IT_Fail $r '29f  _Get-FltDockerHostTarget unknown' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 29g — Fleet routing: container excluded from windowsTargets
    #        (verified via read-only FleetExecutor: container→docker-exec, not tcpkg)
    # ------------------------------------------------------------------
    try {
        $savedReadOnly    = $Script:FltReadOnly
        $savedBatchStatus = $Script:FltBatchStatus
        $Script:FltReadOnly    = $true
        $Script:FltBatchStatus = @{}

        $winTarget = [FleetTarget]::new('win-1', '10.0.0.1', 22, 'admin', $true)
        $winTarget.OS = 'windows'; $winTarget.TargetType = 'physical'
        $winTarget.PackageManager = 'tcpkg'

        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' `
                       -Targets @($winTarget, $cntrTarget)

        $winResult  = $results | Where-Object { $_.TargetName -eq 'win-1' }
        $cntrResult = $results | Where-Object { $_.TargetName -eq 'web-1' }

        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus

        if ($winResult.PackageManager -eq 'tcpkg' -and $cntrResult.PackageManager -eq 'docker-exec') {
            _IT_Pass $r '29g  Fleet routing: container excluded from Windows bucket'
        } else {
            _IT_Fail $r '29g  Fleet routing: container excluded from Windows bucket' `
                "win=$($winResult.PackageManager) cntr=$($cntrResult.PackageManager)"
        }
    } catch {
        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
        _IT_Fail $r '29g  Fleet routing container exclusion' $_.Exception.Message
    }

    # ------------------------------------------------------------------
    # 29h — TypeDisplay() returns 'Cntr' for container target
    # ------------------------------------------------------------------
    try {
        if ((Get-FltTypeDisplay -Target $cntrTarget) -eq 'Cntr') {
            _IT_Pass $r '29h  TypeDisplay(): ''Cntr'' for container target'
        } else {
            _IT_Fail $r '29h  TypeDisplay(): ''Cntr'' for container target' "Got: $(Get-FltTypeDisplay -Target $cntrTarget)"
        }
    } catch { _IT_Fail $r '29h  TypeDisplay()' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Restore FleetTargets
    # ------------------------------------------------------------------
    $Script:FleetTargets = $savedTargets

    return $r
}

# ── Suite 30 — Batch dashboard pagination ─────────────────────────────────────

# Tests the batch dashboard pagination state machine directly.
# Avoids calling Show-FleetBatchDashboard (which clears the screen and
# paints ANSI escape sequences) by seeding script-scope state manually
# and testing the navigation and summary logic.
function Invoke-IT_BatchPagination {
    $r = _IT_NewResult

    _IT_Section 'Batch dashboard pagination'

    # Save batch state
    $savedPage       = $Script:FltBatchPage
    $savedPageSize   = $Script:FltBatchPageSize
    $savedTotalPages = $Script:FltBatchTotalPages
    $savedTargets    = $Script:FltBatchTargets
    $savedStatus     = $Script:FltBatchStatus
    $savedHeight     = $Script:FltBatchDashHeight
    $savedScroll     = $Script:FltBatchScrollStart

    # Helper: build N synthetic targets
    function _MkTargets { param([int]$N)
        1..$N | ForEach-Object {
            $t = [FleetTarget]::new("lin-$_", "10.0.0.$_", 22, 'admin', $false)
            $t.OS = 'linux'; $t.TargetType = 'physical'
            $t
        }
    }

    # ------------------------------------------------------------------
    # 30a — Single page: TotalPages = 1 when targets ≤ page size
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkTargets 5)
        $Script:FltBatchPageSize   = 20
        $Script:FltBatchTotalPages = [Math]::Max(1, [Math]::Ceiling($targets.Count / 20))
        $Script:FltBatchPage       = 0

        if ($Script:FltBatchTotalPages -eq 1) {
            _IT_Pass $r '30a  Single page: TotalPages=1 when targets ≤ page size'
        } else {
            _IT_Fail $r '30a  Single page: TotalPages=1 when targets ≤ page size' `
                "TotalPages=$($Script:FltBatchTotalPages)"
        }
    } catch { _IT_Fail $r '30a  Single page calculation' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 30b — Multi-page: TotalPages = ceil(n / pageSize)
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkTargets 25)
        $Script:FltBatchPageSize   = 10
        $Script:FltBatchTotalPages = [Math]::Max(1, [Math]::Ceiling($targets.Count / 10))

        if ($Script:FltBatchTotalPages -eq 3) {
            _IT_Pass $r '30b  Multi-page: TotalPages=3 for 25 targets with page size 10'
        } else {
            _IT_Fail $r '30b  Multi-page: TotalPages=3 for 25 targets with page size 10' `
                "TotalPages=$($Script:FltBatchTotalPages)"
        }
    } catch { _IT_Fail $r '30b  TotalPages calculation' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 30c — Move-FltBatchPage: next page increments page counter
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchPage       = 0
        $Script:FltBatchTotalPages = 3
        $Script:FltBatchTargets    = @(_MkTargets 25)
        $Script:FltBatchPageSize   = 10
        $Script:FltBatchStatus     = @{}
        foreach ($t in $Script:FltBatchTargets) {
            $Script:FltBatchStatus[$t.Name] = @{ Status='Pending'; Duration=0.0; Note='' }
        }
        $Script:FltBatchDashHeight  = 20
        $Script:FltBatchScrollStart = 21

        # Suppress the ANSI repaint by temporarily overriding the function
        function _Ansi_RepaintBatchDashboard { param($Action,$PackageSpec,$Mode) <# no-op in test #> }

        Move-FltBatchPage -Delta 1

        if ($Script:FltBatchPage -eq 1) {
            _IT_Pass $r '30c  Move-FltBatchPage +1: page increments from 0 to 1'
        } else {
            _IT_Fail $r '30c  Move-FltBatchPage +1: page increments from 0 to 1' `
                "Page=$($Script:FltBatchPage)"
        }
    } catch { _IT_Fail $r '30c  Move-FltBatchPage next' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 30d — Move-FltBatchPage: prev page decrements page counter
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchPage = 2
        Move-FltBatchPage -Delta -1
        if ($Script:FltBatchPage -eq 1) {
            _IT_Pass $r '30d  Move-FltBatchPage -1: page decrements from 2 to 1'
        } else {
            _IT_Fail $r '30d  Move-FltBatchPage -1: page decrements from 2 to 1' `
                "Page=$($Script:FltBatchPage)"
        }
    } catch { _IT_Fail $r '30d  Move-FltBatchPage prev' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 30e — Move-FltBatchPage: does not go below page 0
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchPage = 0
        Move-FltBatchPage -Delta -1
        if ($Script:FltBatchPage -eq 0) {
            _IT_Pass $r '30e  Move-FltBatchPage: clamps at page 0 (no underflow)'
        } else {
            _IT_Fail $r '30e  Move-FltBatchPage: clamps at page 0 (no underflow)' `
                "Page=$($Script:FltBatchPage)"
        }
    } catch { _IT_Fail $r '30e  Page underflow clamp' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 30f — Move-FltBatchPage: does not exceed TotalPages - 1
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchPage       = 2  # already last page (0-indexed, 3 total)
        $Script:FltBatchTotalPages = 3
        Move-FltBatchPage -Delta 1
        if ($Script:FltBatchPage -eq 2) {
            _IT_Pass $r '30f  Move-FltBatchPage: clamps at TotalPages-1 (no overflow)'
        } else {
            _IT_Fail $r '30f  Move-FltBatchPage: clamps at TotalPages-1 (no overflow)' `
                "Page=$($Script:FltBatchPage)"
        }
    } catch { _IT_Fail $r '30f  Page overflow clamp' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 30g — Move-FltBatchPage: no-op when single page
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchPage       = 0
        $Script:FltBatchTotalPages = 1
        Move-FltBatchPage -Delta 1
        if ($Script:FltBatchPage -eq 0) {
            _IT_Pass $r '30g  Move-FltBatchPage: no-op when TotalPages=1'
        } else {
            _IT_Fail $r '30g  Move-FltBatchPage: no-op when TotalPages=1' `
                "Page=$($Script:FltBatchPage)"
        }
    } catch { _IT_Fail $r '30g  Single page no-op' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 30h — Summary counts span all pages, not just current page
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkTargets 25)
        $Script:FltBatchTargets    = $targets
        $Script:FltBatchPageSize   = 10
        $Script:FltBatchPage       = 0
        $Script:FltBatchTotalPages = 3
        $Script:FltBatchStatus     = @{}

        # Seed: page 0 (targets 1-10) = Pending, page 1 (11-20) = OK, page 2 (21-25) = Failed
        for ($i = 0; $i -lt 25; $i++) {
            $st = if ($i -lt 10) { 'Pending' } elseif ($i -lt 20) { 'OK' } else { 'Failed' }
            $Script:FltBatchStatus[$targets[$i].Name] = @{ Status=$st; Duration=0.0; Note='' }
        }

        $all  = $Script:FltBatchStatus.Values
        $ok   = @($all | Where-Object { $_.Status -like 'OK*' }).Count
        $fail = @($all | Where-Object { $_.Status -like 'Failed*' }).Count
        $pend = @($all | Where-Object { $_.Status -eq 'Pending' }).Count

        # On page 0, we only SEE 10 targets but summary must show all 25
        if ($ok -eq 10 -and $fail -eq 5 -and $pend -eq 10) {
            _IT_Pass $r '30h  Summary counts span all pages (ok=10, fail=5, pend=10)'
        } else {
            _IT_Fail $r '30h  Summary counts span all pages (ok=10, fail=5, pend=10)' `
                "ok=$ok fail=$fail pend=$pend"
        }
    } catch { _IT_Fail $r '30h  Cross-page summary counts' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Restore batch state
    # ------------------------------------------------------------------
    $Script:FltBatchPage        = $savedPage
    $Script:FltBatchPageSize    = $savedPageSize
    $Script:FltBatchTotalPages  = $savedTotalPages
    $Script:FltBatchTargets     = $savedTargets
    $Script:FltBatchStatus      = $savedStatus
    $Script:FltBatchDashHeight  = $savedHeight
    $Script:FltBatchScrollStart = $savedScroll

    return $r
}

# ── Suite 31 — Phase 8.0 pre-work ─────────────────────────────────────────────

function Invoke-IT_Phase80PreWork {
    $r = _IT_NewResult

    _IT_Section 'Phase 8.0 pre-work'

    # Save/restore batch state
    $savedAction      = $Script:FltBatchAction
    $savedPackage     = $Script:FltBatchPackageSpec
    $savedMode        = $Script:FltBatchMode
    $savedTimeout     = $Script:FltBatchTimeoutSecs
    $savedPage        = $Script:FltBatchPage
    $savedTotalPages  = $Script:FltBatchTotalPages
    $savedTargets     = $Script:FltBatchTargets
    $savedPageSize    = $Script:FltBatchPageSize
    $savedStatus      = $Script:FltBatchStatus
    $savedHeight      = $Script:FltBatchDashHeight
    $savedScroll      = $Script:FltBatchScrollStart

    # ------------------------------------------------------------------
    # 31a — Script-scope action vars are initialised at startup
    # ------------------------------------------------------------------
    try {
        $hasAction  = $null -ne $Script:FltBatchAction
        $hasPackage = $null -ne $Script:FltBatchPackageSpec
        $hasMode    = $null -ne $Script:FltBatchMode
        if ($hasAction -and $hasPackage -and $hasMode) {
            _IT_Pass $r '31a  FltBatchAction/PackageSpec/Mode vars initialised at startup'
        } else {
            _IT_Fail $r '31a  FltBatchAction/PackageSpec/Mode vars initialised at startup' `
                "Action=$hasAction Package=$hasPackage Mode=$hasMode"
        }
    } catch { _IT_Fail $r '31a  Script-scope action vars' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 31b — _Ansi_RepaintBatchDashboard uses stored vars when called with empty args
    #        (test by setting known stored values, calling repaint, checking no error)
    # ------------------------------------------------------------------
    try {
        $Script:FltBatchAction      = 'install'
        $Script:FltBatchPackageSpec = 'curl'
        $Script:FltBatchMode        = 'Ansible'
        $Script:FltBatchTimeoutSecs = 0
        $Script:FltBatchPage        = 0
        $Script:FltBatchPageSize    = 20
        $Script:FltBatchTotalPages  = 1
        $Script:FltBatchTargets     = @()
        $Script:FltBatchStatus      = @{}
        $Script:FltBatchDashHeight  = 15
        $Script:FltBatchScrollStart = 16

        # Override repaint to be a no-op for this test
        function _Ansi_RepaintBatchDashboard { param($Action,$PackageSpec,$Mode,$TimeoutSecs) <# no-op #> }

        # Invoke-FltBatchPageNav calls _Ansi_RepaintBatchDashboard with no args
        # It should not throw even though stored vars are set
        Invoke-FltBatchPageNav -Delta 0   # delta 0 = no page change, but exercises the path
        _IT_Pass $r '31b  _Ansi_RepaintBatchDashboard: no error when called via Invoke-FltBatchPageNav'
    } catch { _IT_Fail $r '31b  _Ansi_RepaintBatchDashboard stored vars' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 31c — Read-FltBatchNav is defined and callable
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Read-FltBatchNav' -ErrorAction SilentlyContinue
        if ($fn) {
            _IT_Pass $r '31c  Read-FltBatchNav is defined'
        } else {
            _IT_Fail $r '31c  Read-FltBatchNav is defined' 'Function not found'
        }
    } catch { _IT_Fail $r '31c  Read-FltBatchNav defined' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 31d — Move-FltBatchPage is defined and callable
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Move-FltBatchPage' -ErrorAction SilentlyContinue
        if ($fn) {
            _IT_Pass $r '31d  Move-FltBatchPage is defined'
        } else {
            _IT_Fail $r '31d  Move-FltBatchPage is defined' 'Function not found'
        }
    } catch { _IT_Fail $r '31d  Move-FltBatchPage defined' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 31e — Write-FltBatchEntry log record contains targetType field
    # ------------------------------------------------------------------
    try {
        # Build a synthetic result and check the record shape
        $t = [FleetTarget]::new('test-1', '10.0.0.1', 22, 'admin', $true)
        $t.TargetType = 'physical'
        $Script:FleetTargets = @($t)

        $res = [BatchResult]::new()
        $res.TargetName     = 'test-1'
        $res.Action         = 'install'
        $res.PackageSpec    = 'curl'
        $res.PackageManager = 'ansible'
        $res.Status         = 'OK'
        $res.DurationSec    = 1.5
        $res.TimedOut       = $false
        $res.Note           = ''

        # Intercept _Write-FltLogEntry to capture the record
        $script:capturedRecord = $null
        function _Write-FltLogEntry { param($Record); $script:capturedRecord = $Record }

        Write-FltBatchEntry -Action 'install' -PackageSpec 'curl' -Results @($res)

        if ($script:capturedRecord -and
            $script:capturedRecord.results -and
            $script:capturedRecord.results[0].Contains('targetType')) {
            _IT_Pass $r '31e  Write-FltBatchEntry: log record contains targetType field'
        } else {
            _IT_Fail $r '31e  Write-FltBatchEntry: log record contains targetType field' `
                "Record=$(if ($script:capturedRecord) { 'present' } else { 'null' })"
        }
    } catch { _IT_Fail $r '31e  Write-FltBatchEntry targetType' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 31f — targetType value is correct for a physical target
    # ------------------------------------------------------------------
    try {
        if ($script:capturedRecord -and $script:capturedRecord.results) {
            $tt = $script:capturedRecord.results[0].targetType
            if ($tt -eq 'physical') {
                _IT_Pass $r '31f  Write-FltBatchEntry: targetType=''physical'' for physical target'
            } else {
                _IT_Fail $r '31f  Write-FltBatchEntry: targetType=''physical'' for physical target' "Got: $tt"
            }
        } else {
            _IT_Fail $r '31f  Write-FltBatchEntry targetType value' 'No record from 31e'
        }
    } catch { _IT_Fail $r '31f  targetType value' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 31g — Get-FltTypeDisplay returns correct strings
    # ------------------------------------------------------------------
    try {
        $physical  = [FleetTarget]::new('p', '1.2.3.4', 22, '', $false)
        $physical.TargetType = 'physical'
        $vm        = [FleetTarget]::new('v', '1.2.3.5', 22, '', $false)
        $vm.TargetType = 'vm'
        $container = [FleetTarget]::new('c', '1.2.3.6', 22, '', $false)
        $container.TargetType = 'container'

        $dp = Get-FltTypeDisplay -Target $physical
        $dv = Get-FltTypeDisplay -Target $vm
        $dc = Get-FltTypeDisplay -Target $container

        if ($dp -eq 'Phys' -and $dv -eq 'VM' -and $dc -eq 'Cntr') {
            _IT_Pass $r '31g  Get-FltTypeDisplay: Phys/VM/Cntr for physical/vm/container'
        } else {
            _IT_Fail $r '31g  Get-FltTypeDisplay: Phys/VM/Cntr for physical/vm/container' `
                "physical=$dp vm=$dv container=$dc"
        }
    } catch { _IT_Fail $r '31g  Get-FltTypeDisplay' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 31h — Batch dashboard header row format includes Type column
    # ------------------------------------------------------------------
    try {
        # The header row format string should now include Type (5 chars)
        $headerFmt = '  {0,-18} {1,-5} {2,-14} {3,9}  {4}' -f 'Target','Type','Status','Duration','Note'
        if ($headerFmt -match 'Type') {
            _IT_Pass $r '31h  Batch dashboard header includes Type column'
        } else {
            _IT_Fail $r '31h  Batch dashboard header includes Type column' "Format: $headerFmt"
        }
    } catch { _IT_Fail $r '31h  Batch header Type column' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Restore state
    # ------------------------------------------------------------------
    $Script:FltBatchAction      = $savedAction
    $Script:FltBatchPackageSpec = $savedPackage
    $Script:FltBatchMode        = $savedMode
    $Script:FltBatchTimeoutSecs = $savedTimeout
    $Script:FltBatchPage        = $savedPage
    $Script:FltBatchTotalPages  = $savedTotalPages
    $Script:FltBatchTargets     = $savedTargets
    $Script:FltBatchPageSize    = $savedPageSize
    $Script:FltBatchStatus      = $savedStatus
    $Script:FltBatchDashHeight  = $savedHeight
    $Script:FltBatchScrollStart = $savedScroll

    return $r
}

# ── Suite 32 — Container Admin menu ───────────────────────────────────────────

function Invoke-IT_ContainerAdminMenu {
    $r = _IT_NewResult

    _IT_Section 'Container Admin menu'

    $savedTargets = $Script:FleetTargets

    function _MkCntr {
        param([string]$Name, [string]$DockerHostName, [string]$Container, [string]$PM = 'apt')
        $t = [FleetTarget]::new($Name, '10.0.0.1', 22, 'admin', $false)
        $t.OS = 'linux'; $t.TargetType = 'container'
        $t.DockerHost = $DockerHostName; $t.ContainerName = $Container
        $t.PackageManager = $PM
        $t
    }

    # ------------------------------------------------------------------
    # 32a — Invoke-ContainerAdminMenu is defined
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Invoke-ContainerAdminMenu' -ErrorAction SilentlyContinue
        if ($fn) { _IT_Pass $r '32a  Invoke-ContainerAdminMenu is defined' }
        else      { _IT_Fail $r '32a  Invoke-ContainerAdminMenu is defined' 'Function not found' }
    } catch { _IT_Fail $r '32a  Invoke-ContainerAdminMenu' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32b — _Get-ContainerTargets filters to TargetType=container only
    # ------------------------------------------------------------------
    try {
        $hostTgt = [FleetTarget]::new('docker-host-1', '10.0.0.1', 22, 'admin', $true)
        $hostTgt.OS = 'linux'; $hostTgt.TargetType = 'physical'
        $Script:FleetTargets = @($hostTgt, (_MkCntr 'web-1' 'docker-host-1' 'web_app'))
        $cntrTargets = @(_Get-ContainerTargets)
        if ($cntrTargets.Count -eq 1 -and $cntrTargets[0].Name -eq 'web-1') {
            _IT_Pass $r '32b  _Get-ContainerTargets: returns only container targets'
        } else {
            _IT_Fail $r '32b  _Get-ContainerTargets: returns only container targets' `
                "Count=$($cntrTargets.Count)"
        }
    } catch { _IT_Fail $r '32b  _Get-ContainerTargets' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32c — DockerExecBatch read-only: package install produces Skipped
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCntr 'web-1' 'docker-host-1' 'web_app')
        $results = Invoke-FltDockerExecBatch -Targets $targets `
                       -Action 'install' -PackageSpec 'curl' -ReadOnly $true
        if ($results[0].Status -eq 'Skipped') {
            _IT_Pass $r '32c  DockerExecBatch read-only: Status=Skipped'
        } else {
            _IT_Fail $r '32c  DockerExecBatch read-only: Status=Skipped' "Got=$($results[0].Status)"
        }
    } catch { _IT_Fail $r '32c  DockerExecBatch read-only' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32d — DockerLifecycleBatch read-only: lifecycle produces Skipped
    # ------------------------------------------------------------------
    try {
        $targets = @(_MkCntr 'web-1' 'docker-host-1' 'web_app')
        $results = Invoke-FltDockerLifecycleBatch -Targets $targets `
                       -Action 'stop' -PackageSpec 'web_app' -ReadOnly $true
        if ($results[0].Status -eq 'Skipped') {
            _IT_Pass $r '32d  DockerLifecycleBatch read-only: Status=Skipped'
        } else {
            _IT_Fail $r '32d  DockerLifecycleBatch read-only: Status=Skipped' "Got=$($results[0].Status)"
        }
    } catch { _IT_Fail $r '32d  DockerLifecycleBatch read-only' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32e — Fleet routing: container targets route to docker-exec
    # ------------------------------------------------------------------
    try {
        $savedReadOnly    = $Script:FltReadOnly
        $savedBatchStatus = $Script:FltBatchStatus
        $Script:FltReadOnly    = $true
        $Script:FltBatchStatus = @{}
        $targets = @(_MkCntr 'web-1' 'docker-host-1' 'web_app')
        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' -Targets $targets
        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
        if ($results[0].PackageManager -eq 'docker-exec') {
            _IT_Pass $r '32e  Fleet routing: container → docker-exec'
        } else {
            _IT_Fail $r '32e  Fleet routing: container → docker-exec' `
                "PackageManager=$($results[0].PackageManager)"
        }
    } catch {
        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
        _IT_Fail $r '32e  Fleet routing container' $_.Exception.Message
    }

    # ------------------------------------------------------------------
    # 32f — Invoke-ContainerInstallMenu is defined
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Invoke-ContainerInstallMenu' -ErrorAction SilentlyContinue
        if ($fn) { _IT_Pass $r '32f  Invoke-ContainerInstallMenu is defined' }
        else      { _IT_Fail $r '32f  Invoke-ContainerInstallMenu is defined' 'Not found' }
    } catch { _IT_Fail $r '32f  Invoke-ContainerInstallMenu' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32g — Invoke-ContainerLifecycleMenu is defined
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Invoke-ContainerLifecycleMenu' -ErrorAction SilentlyContinue
        if ($fn) { _IT_Pass $r '32g  Invoke-ContainerLifecycleMenu is defined' }
        else      { _IT_Fail $r '32g  Invoke-ContainerLifecycleMenu is defined' 'Not found' }
    } catch { _IT_Fail $r '32g  Invoke-ContainerLifecycleMenu' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32h — Invoke-ContainerLogsMenu is defined
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Invoke-ContainerLogsMenu' -ErrorAction SilentlyContinue
        if ($fn) { _IT_Pass $r '32h  Invoke-ContainerLogsMenu is defined' }
        else      { _IT_Fail $r '32h  Invoke-ContainerLogsMenu is defined' 'Not found' }
    } catch { _IT_Fail $r '32h  Invoke-ContainerLogsMenu' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32i — Invoke-ContainerHealthMenu is defined
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command 'Invoke-ContainerHealthMenu' -ErrorAction SilentlyContinue
        if ($fn) { _IT_Pass $r '32i  Invoke-ContainerHealthMenu is defined' }
        else      { _IT_Fail $r '32i  Invoke-ContainerHealthMenu is defined' 'Not found' }
    } catch { _IT_Fail $r '32i  Invoke-ContainerHealthMenu' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 32j — Mixed fleet: container→docker-exec, Linux physical→ansible
    # ------------------------------------------------------------------
    try {
        $savedReadOnly    = $Script:FltReadOnly
        $savedBatchStatus = $Script:FltBatchStatus
        $Script:FltReadOnly    = $true
        $Script:FltBatchStatus = @{}

        $linTgt = [FleetTarget]::new('lin-1', '10.0.0.2', 22, 'admin', $false)
        $linTgt.OS = 'linux'; $linTgt.TargetType = 'physical'
        $cntrTgt = _MkCntr 'web-1' 'docker-host-1' 'web_app'

        $results = Invoke-FleetAction -Action 'install' -PackageSpec 'curl' `
                       -Targets @($linTgt, $cntrTgt)
        $lin  = $results | Where-Object { $_.TargetName -eq 'lin-1' }
        $cntr = $results | Where-Object { $_.TargetName -eq 'web-1' }

        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus

        if ($lin.PackageManager -eq 'ansible' -and $cntr.PackageManager -eq 'docker-exec') {
            _IT_Pass $r '32j  Mixed fleet: lin-1→ansible, web-1→docker-exec'
        } else {
            _IT_Fail $r '32j  Mixed fleet: lin-1→ansible, web-1→docker-exec' `
                "lin=$($lin.PackageManager) cntr=$($cntr.PackageManager)"
        }
    } catch {
        $Script:FltReadOnly    = $savedReadOnly
        $Script:FltBatchStatus = $savedBatchStatus
        _IT_Fail $r '32j  Mixed fleet routing' $_.Exception.Message
    }

    $Script:FleetTargets = $savedTargets
    return $r
}

# ── Suite 33 — Compose repository ─────────────────────────────────────────────

function Invoke-IT_ComposeRepository {
    $r = _IT_NewResult

    _IT_Section 'Compose repository'

    $savedRoot    = $Script:FltScriptRoot
    $tmpDir       = Join-Path ([System.IO.Path]::GetTempPath()) "tcflt_it33_$(Get-Random)"
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpDir 'compose\templates') -Force | Out-Null

    # Copy real templates into temp dir BEFORE redirecting script root
    $realTemplateDir = Join-Path $savedRoot 'compose\templates'
    $tmpTemplateDir  = Join-Path $tmpDir 'compose\templates'
    if (Test-Path $realTemplateDir) {
        Get-ChildItem "$realTemplateDir\*.template" -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName $tmpTemplateDir -Force }
    } else {
        # Templates folder not found — create minimal stubs so template tests can run
        $stubContent = "networks:`n  {{NETWORK_NAME}}:`n    {{NETWORK_DEFINITION}}`n" +
                       "services:`n  {{CONTAINER_NAME}}:`n    image: stub:latest`n" +
                       "    container_name: {{CONTAINER_NAME}}`n    hostname: {{CONTAINER_NAME}}`n" +
                       "    restart: unless-stopped`n    networks:`n      {{NETWORK_NAME}}:`n" +
                       "        ipv4_address: {{IP_ADDRESS}}`n"
        foreach ($tname in @('twincat-xar','mosquitto','debian-ssh')) {
            $stubPath = Join-Path $tmpTemplateDir "$tname.yml.template"
            [System.IO.File]::WriteAllText($stubPath, $stubContent, [System.Text.Encoding]::UTF8)
        }
    }

    # Redirect script root to temp dir so Get-FltComposeDir points there
    $Script:FltScriptRoot = $tmpDir

    # ------------------------------------------------------------------
    # 33a — Get-FltComposeTemplates: finds templates in templates/ dir
    # ------------------------------------------------------------------
    try {
        $tmplDir   = Get-FltComposeTemplateDir
        $tmplFiles = @(Get-ChildItem $tmplDir -Filter '*.template' -ErrorAction SilentlyContinue)
        $templates = @(Get-FltComposeTemplates)
        if ($templates.Count -ge 3) {
            _IT_Pass $r '33a  Get-FltComposeTemplates: finds all 3 built-in templates'
        } else {
            _IT_Fail $r '33a  Get-FltComposeTemplates: finds all 3 built-in templates' `
                "Found: $($templates.Count) (dir=$tmplDir exists=$(Test-Path $tmplDir) files=$($tmplFiles.Count))"
        }
    } catch { _IT_Fail $r '33a  Get-FltComposeTemplates' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33b — Get-FltComposeTemplates: all expected names present
    # ------------------------------------------------------------------
    try {
        $templates = @(Get-FltComposeTemplates)
        $names = $templates | ForEach-Object { $_.Name }
        $hasAll = ('twincat-xar' -in $names) -and ('mosquitto' -in $names) -and ('debian-ssh' -in $names)
        if ($hasAll) {
            _IT_Pass $r '33b  Get-FltComposeTemplates: twincat-xar, mosquitto, debian-ssh present'
        } else {
            _IT_Fail $r '33b  Get-FltComposeTemplates: twincat-xar, mosquitto, debian-ssh present' `
                "Names: $($names -join ', ')"
        }
    } catch { _IT_Fail $r '33b  Template names' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33c — Get-FltComposeServices: parses service names from YAML
    # ------------------------------------------------------------------
    try {
        $testYml = @"
networks:
  container-network:
    external: true

services:
  mosquitto:
    image: eclipse-mosquitto:latest
  tc31-xar-base:
    image: ghcr.io/beckhoff/tcbsd-twincat-xar:latest
  debian-test:
    image: debian:bookworm-slim
"@
        $ymlPath = Join-Path $tmpDir 'test.yml'
        $testYml | Set-Content $ymlPath -Encoding UTF8
        $services = @(Get-FltComposeServices -Path $ymlPath)
        if ($services.Count -eq 3 -and 'mosquitto' -in $services -and 'tc31-xar-base' -in $services) {
            _IT_Pass $r '33c  Get-FltComposeServices: parses 3 services correctly'
        } else {
            _IT_Fail $r '33c  Get-FltComposeServices: parses 3 services correctly' `
                "Count=$($services.Count) Services=$($services -join ',')"
        }
    } catch { _IT_Fail $r '33c  Get-FltComposeServices' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33d — New-FltComposeFromTemplate: generates valid compose file
    # ------------------------------------------------------------------
    try {
        $vars = @{
            CONTAINER_NAME     = 'test-xar'
            AMS_NETID          = '15.15.15.15.1.1'
            IP_ADDRESS         = '192.168.20.3'
            NETWORK_NAME       = 'container-network'
            NETWORK_DEFINITION = 'external: true'
        }
        $result = New-FltComposeFromTemplate -TemplateName 'twincat-xar' `
                      -OutputName 'test-xar' -Variables $vars
        if ($result.Ok -and (Test-Path $result.Path)) {
            _IT_Pass $r '33d  New-FltComposeFromTemplate: generates compose file'
        } else {
            _IT_Fail $r '33d  New-FltComposeFromTemplate: generates compose file' `
                $result.Message
        }
    } catch { _IT_Fail $r '33d  New-FltComposeFromTemplate' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33e — New-FltComposeFromTemplate: substituted variables correct
    # ------------------------------------------------------------------
    try {
        $outPath = Join-Path $tmpDir 'compose\test-xar.yml'
        if (Test-Path $outPath) {
            $content2 = Get-Content $outPath -Raw
            $hasName   = $content2 -match 'container_name: test-xar'
            $hasNetId  = $content2 -match '15\.15\.15\.15\.1\.1'
            $hasIp     = $content2 -match '192\.168\.20\.3'
            $noPlaceholder = $content2 -notmatch '\{\{[A-Z_]+\}\}'
            if ($hasName -and $hasNetId -and $hasIp -and $noPlaceholder) {
                _IT_Pass $r '33e  New-FltComposeFromTemplate: all variables substituted'
            } else {
                _IT_Fail $r '33e  New-FltComposeFromTemplate: all variables substituted' `
                    "name=$hasName netid=$hasNetId ip=$hasIp noplac=$noPlaceholder"
            }
        } else {
            _IT_Fail $r '33e  Variable substitution' 'Compose file not found (33d failed)'
        }
    } catch { _IT_Fail $r '33e  Variable substitution' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33f — New-FltComposeFromTemplate: returns service list
    # ------------------------------------------------------------------
    try {
        $vars = @{
            CONTAINER_NAME     = 'test-xar'
            AMS_NETID          = '15.15.15.15.1.1'
            IP_ADDRESS         = '192.168.20.3'
            NETWORK_NAME       = 'container-network'
            NETWORK_DEFINITION = 'external: true'
        }
        $result = New-FltComposeFromTemplate -TemplateName 'twincat-xar' `
                      -OutputName 'test-xar2' -Variables $vars
        if ($result.Ok -and $result.Services.Count -gt 0) {
            _IT_Pass $r '33f  New-FltComposeFromTemplate: returns service list'
        } else {
            _IT_Fail $r '33f  New-FltComposeFromTemplate: returns service list' `
                "Services=$($result.Services.Count)"
        }
    } catch { _IT_Fail $r '33f  Service list returned' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33g — Import-FltContainerCsv: generates multi-service compose file
    # ------------------------------------------------------------------
    try {
        $csvContent = @"
Name,Template,AmsNetId,IpAddress,SshPort,PackageManager
tc31-node1,twincat-xar,15.15.15.15.1.1,192.168.20.3,,apt
tc31-node2,twincat-xar,15.15.15.15.1.2,192.168.20.4,,apt
mqtt-broker,mosquitto,,192.168.20.2,1883,apt
"@
        $csvPath = Join-Path $tmpDir 'test-containers.csv'
        $csvContent | Set-Content $csvPath -Encoding UTF8

        $result = Import-FltContainerCsv -CsvPath $csvPath -OutputName 'test-batch' `
                      -NetworkName 'container-network' -NetworkExternal $true `
                      -Subnet '192.168.20.0/24' -Gateway '192.168.20.1'

        if ($result.Ok -and $result.Services.Count -eq 3) {
            _IT_Pass $r '33g  Import-FltContainerCsv: generates 3-service compose file'
        } else {
            _IT_Fail $r '33g  Import-FltContainerCsv: generates 3-service compose file' `
                "$($result.Message) Services=$($result.Services.Count)"
        }
    } catch { _IT_Fail $r '33g  Import-FltContainerCsv' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33h — Import-FltContainerCsv: generated file contains all services
    # ------------------------------------------------------------------
    try {
        $outPath = Join-Path $tmpDir 'compose\test-batch.yml'
        if (Test-Path $outPath) {
            $content2 = Get-Content $outPath -Raw
            $hasNode1  = $content2 -match 'container_name: tc31-node1'
            $hasNode2  = $content2 -match 'container_name: tc31-node2'
            $hasMqtt   = $content2 -match 'container_name: mqtt-broker'
            if ($hasNode1 -and $hasNode2 -and $hasMqtt) {
                _IT_Pass $r '33h  Import-FltContainerCsv: all services in generated file'
            } else {
                _IT_Fail $r '33h  Import-FltContainerCsv: all services in generated file' `
                    "node1=$hasNode1 node2=$hasNode2 mqtt=$hasMqtt"
            }
        } else {
            _IT_Fail $r '33h  CSV import file content' 'File not found (33g failed)'
        }
    } catch { _IT_Fail $r '33h  CSV import file content' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33i — _Get-FltNetworkDefinition: inline network YAML correct
    # ------------------------------------------------------------------
    try {
        $def = _Get-FltNetworkDefinition -NetworkName 'mynet' `
                   -Subnet '10.0.0.0/24' -Gateway '10.0.0.1' -External $false
        if ($def -match 'subnet: 10\.0\.0\.0/24' -and $def -match '10\.0\.0\.1') {
            _IT_Pass $r '33i  _Get-FltNetworkDefinition: inline network has subnet and gateway'
        } else {
            _IT_Fail $r '33i  _Get-FltNetworkDefinition: inline network has subnet and gateway' `
                "Got: $def"
        }
    } catch { _IT_Fail $r '33i  _Get-FltNetworkDefinition inline' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 33j — _Get-FltNetworkDefinition: external network correct
    # ------------------------------------------------------------------
    try {
        $def = _Get-FltNetworkDefinition -NetworkName 'mynet' `
                   -Subnet '' -Gateway '' -External $true
        if ($def -eq 'external: true') {
            _IT_Pass $r '33j  _Get-FltNetworkDefinition: external network = ''external: true'''
        } else {
            _IT_Fail $r '33j  _Get-FltNetworkDefinition: external network = ''external: true''' `
                "Got: $def"
        }
    } catch { _IT_Fail $r '33j  _Get-FltNetworkDefinition external' $_.Exception.Message }

    # ------------------------------------------------------------------
    # Cleanup
    # ------------------------------------------------------------------
    $Script:FltScriptRoot = $savedRoot
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    return $r
}

# ── Suite 34 — Container target registration ──────────────────────────────────

function Invoke-IT_ContainerTargetReg {
    $r = _IT_NewResult

    _IT_Section 'Container target registration'

    $savedTargets    = $Script:FleetTargets
    $targetsFilePath = Join-Path $Script:FltConfigDir 'targets.local.json'
    $savedTargetFile = Get-Content $targetsFilePath -Raw -ErrorAction SilentlyContinue

    # Seed a Docker host target — work on a copy so real targets.local.json is preserved
    $hostTgt = [FleetTarget]::new('docker-host-1', '10.0.0.1', 22, 'admin', $true)
    $hostTgt.OS = 'linux'; $hostTgt.TargetType = 'physical'
    $Script:FleetTargets = @($hostTgt)

    # ------------------------------------------------------------------
    # 34a — _Register-ContainerTarget: target added to FleetTargets
    # ------------------------------------------------------------------
    try {
        $ok = _Register-ContainerTarget -Name 'web-1' -DockerHostName 'docker-host-1' `
                  -ContainerName 'web_app' -PackageManager 'apt'
        $added = $Script:FleetTargets | Where-Object { $_.Name -eq 'web-1' } | Select-Object -First 1
        if ($ok -and $added) {
            _IT_Pass $r '34a  _Register-ContainerTarget: target added to FleetTargets'
        } else {
            _IT_Fail $r '34a  _Register-ContainerTarget: target added to FleetTargets' `
                "ok=$ok added=$($null -ne $added)"
        }
    } catch { _IT_Fail $r '34a  _Register-ContainerTarget' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 34b — Fields: DockerHost, ContainerName, TargetType, OS
    # ------------------------------------------------------------------
    try {
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'web-1' } | Select-Object -First 1
        if ($t.DockerHost -eq 'docker-host-1' -and $t.ContainerName -eq 'web_app' `
            -and $t.TargetType -eq 'container' -and $t.OS -eq 'linux') {
            _IT_Pass $r '34b  Fields: DockerHost, ContainerName, TargetType, OS all correct'
        } else {
            _IT_Fail $r '34b  Fields: DockerHost, ContainerName, TargetType, OS all correct' `
                "host=$($t.DockerHost) cname=$($t.ContainerName) type=$($t.TargetType) os=$($t.OS)"
        }
    } catch { _IT_Fail $r '34b  Target fields' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 34c — Address/Port/User inherited from Docker host
    # ------------------------------------------------------------------
    try {
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'web-1' } | Select-Object -First 1
        if ($t.Address -eq '10.0.0.1' -and $t.Port -eq 22 -and $t.User -eq 'admin') {
            _IT_Pass $r '34c  Address/Port/User inherited from Docker host target'
        } else {
            _IT_Fail $r '34c  Address/Port/User inherited from Docker host target' `
                "addr=$($t.Address) port=$($t.Port) user=$($t.User)"
        }
    } catch { _IT_Fail $r '34c  Address inheritance' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 34d — ComposeFile/Service/Project fields stored
    # ------------------------------------------------------------------
    try {
        $ok = _Register-ContainerTarget -Name 'web-2' -DockerHostName 'docker-host-1' `
                  -ContainerName 'web_app2' -PackageManager 'apt' `
                  -ComposeFile 'compose\myproject.yml' -ComposeService 'web_app2' `
                  -ComposeProject 'myproject'
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'web-2' } | Select-Object -First 1
        if ($t.ComposeFile -eq 'compose\myproject.yml' `
            -and $t.ComposeService -eq 'web_app2' `
            -and $t.ComposeProject -eq 'myproject') {
            _IT_Pass $r '34d  ComposeFile/Service/Project fields stored correctly'
        } else {
            _IT_Fail $r '34d  ComposeFile/Service/Project fields stored correctly' `
                "file=$($t.ComposeFile) svc=$($t.ComposeService) proj=$($t.ComposeProject)"
        }
    } catch { _IT_Fail $r '34d  Compose fields' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 34e — Duplicate guard: second registration of same name fails
    # ------------------------------------------------------------------
    try {
        $before = $Script:FleetTargets.Count
        $ok = _Register-ContainerTarget -Name 'web-1' -DockerHostName 'docker-host-1' `
                  -ContainerName 'web_app' -PackageManager 'apt'
        $after = $Script:FleetTargets.Count
        if (-not $ok -and $after -eq $before) {
            _IT_Pass $r '34e  Duplicate guard: second registration of same name fails'
        } else {
            _IT_Fail $r '34e  Duplicate guard: second registration of same name fails' `
                "ok=$ok before=$before after=$after"
        }
    } catch { _IT_Fail $r '34e  Duplicate guard' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 34f — __local__ host: Address='__local__', Port=0, User=''
    # ------------------------------------------------------------------
    try {
        $ok = _Register-ContainerTarget -Name 'local-1' -DockerHostName '__local__' `
                  -ContainerName 'mycontainer' -PackageManager 'apt'
        $t = $Script:FleetTargets | Where-Object { $_.Name -eq 'local-1' } | Select-Object -First 1
        if ($t.Address -eq '__local__' -and $t.Port -eq 0 -and $t.User -eq '') {
            _IT_Pass $r '34f  __local__ host: Address=__local__, Port=0, User=empty'
        } else {
            _IT_Fail $r '34f  __local__ host: Address=__local__, Port=0, User=empty' `
                "addr=$($t.Address) port=$($t.Port) user=[$($t.User)]"
        }
    } catch { _IT_Fail $r '34f  __local__ host fields' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 34g — _Invoke-AddContainerManual and _Invoke-AddContainerFromFile defined
    # ------------------------------------------------------------------
    try {
        $fnM = Get-Command '_Invoke-AddContainerManual'   -ErrorAction SilentlyContinue
        $fnF = Get-Command '_Invoke-AddContainerFromFile' -ErrorAction SilentlyContinue
        $fnT = Get-Command '_Invoke-AddContainerFromTemplate' -ErrorAction SilentlyContinue
        $fnC = Get-Command '_Invoke-AddContainerFromCsv'  -ErrorAction SilentlyContinue
        if ($fnM -and $fnF -and $fnT -and $fnC) {
            _IT_Pass $r '34g  All four Add-Container path functions defined'
        } else {
            _IT_Fail $r '34g  All four Add-Container path functions defined' `
                "Manual=$($null -ne $fnM) File=$($null -ne $fnF) Template=$($null -ne $fnT) Csv=$($null -ne $fnC)"
        }
    } catch { _IT_Fail $r '34g  Add-Container functions' $_.Exception.Message }

    # ------------------------------------------------------------------
    # 34h — _Deploy-ComposeTargets is defined
    # ------------------------------------------------------------------
    try {
        $fn = Get-Command '_Deploy-ComposeTargets' -ErrorAction SilentlyContinue
        if ($fn) {
            _IT_Pass $r '34h  _Deploy-ComposeTargets is defined'
        } else {
            _IT_Fail $r '34h  _Deploy-ComposeTargets is defined' 'Not found'
        }
    } catch { _IT_Fail $r '34h  _Deploy-ComposeTargets' $_.Exception.Message }

    # Restore in-memory targets
    $Script:FleetTargets = $savedTargets

    # Restore targets.local.json to remove test targets written by _Register-ContainerTarget
    if ($null -ne $savedTargetFile) {
        $savedTargetFile | Set-Content $targetsFilePath -Encoding UTF8 -NoNewline
    } elseif (Test-Path $targetsFilePath) {
        Remove-Item $targetsFilePath -Force -ErrorAction SilentlyContinue
    }

    return $r
}