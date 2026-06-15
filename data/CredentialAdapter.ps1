# =============================================================================
#  TcFltPkgMgr — Credential Adapter
#  Stable public interface for credential storage operations.
#  All callers use these functions — never backend functions directly.
#
#  The active backend is selected at startup by Set-FltCredentialBackend
#  in CredentialBackends.ps1 based on the running OS:
#    Windows → CredentialBackendWindows.ps1  (Windows Credential Manager)
#    Linux   → CredentialBackendFile.ps1     (AES-encrypted local file)
#
#  To add a new backend:
#    1. Create data/CredentialBackend<Name>.ps1 with _<Name>_ prefixed functions
#    2. Add a branch to Set-FltCredentialBackend in CredentialBackends.ps1
#    3. No changes needed here or in CredentialRepository.ps1.
# =============================================================================

# Retrieve a stored plain-text password. Returns $null if not stored.
function Get-FltStoredPassword {
    param([string]$CredentialName)
    & $Script:FltCred_Get -CredentialName $CredentialName
}

# Store a plain-text password. Returns $true on success, $false on failure.
function Set-FltStoredPassword {
    param([string]$CredentialName, [string]$PlainPassword)
    & $Script:FltCred_Set -CredentialName $CredentialName -PlainPassword $PlainPassword
}

# Remove a stored credential. Returns $true on success, $false on failure.
function Remove-FltStoredPassword {
    param([string]$CredentialName)
    & $Script:FltCred_Remove -CredentialName $CredentialName
}