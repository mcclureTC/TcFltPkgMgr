# =============================================================================
#  TcFltPkgMgr — Credential Backend Loader
#  Called once at startup by TcFltPkgMgr.ps1 after CredentialAdapter.ps1
#  is loaded. Wires the chosen backend's functions to the
#  $Script:FltCred_* variables that CredentialAdapter.ps1 delegates to.
#
#  Usage (called automatically at startup):
#    Set-FltCredentialBackend   # auto-selects based on OS
#
#  Or override explicitly:
#    Set-FltCredentialBackend -Backend 'file'    # force file backend on Windows
#    Set-FltCredentialBackend -Backend 'windows' # Windows Credential Manager
#
#  Supported backends:
#    'windows' — Windows Credential Manager via advapi32/cmdkey (Windows only)
#    'file'    — AES-256 encrypted JSON file (cross-platform)
# =============================================================================

function Set-FltCredentialBackend {
    param(
        [string] $Backend = ''   # '' = auto-detect from OS
    )

    # Auto-detect if not specified
    if (-not $Backend) {
        $Backend = if ($IsWindows) { 'windows' } else { 'file' }
    }

    $Script:FltCredentialBackend = $Backend

    if ($Backend -eq 'windows') {
        # CredentialBackendWindows.ps1 is already dot-sourced at script scope
        # by TcFltPkgMgr.ps1. Wire the adapter variables.
        $Script:FltCred_Get    = ${function:_Win_GetStoredPassword}
        $Script:FltCred_Set    = ${function:_Win_SetStoredPassword}
        $Script:FltCred_Remove = ${function:_Win_RemoveStoredPassword}

    } elseif ($Backend -eq 'file') {
        # CredentialBackendFile.ps1 is already dot-sourced at script scope.
        # Wire the adapter variables.
        $Script:FltCred_Get    = ${function:_File_GetStoredPassword}
        $Script:FltCred_Set    = ${function:_File_SetStoredPassword}
        $Script:FltCred_Remove = ${function:_File_RemoveStoredPassword}

        # Ensure the config directory exists (needed on first Linux run)
        if ($Script:FltConfigDir -and -not (Test-Path $Script:FltConfigDir)) {
            New-Item -ItemType Directory -Path $Script:FltConfigDir -Force | Out-Null
        }

    } else {
        throw "Unknown credential backend '$Backend'. Valid values: 'windows', 'file'."
    }

    Write-Verbose "TcFltPkgMgr: credential backend set to '$Backend'"
}