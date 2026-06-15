# =============================================================================
#  TcFltPkgMgr — Windows Credential Backend
#  Stores credentials using Windows DPAPI (Data Protection API) via
#  System.Security.Cryptography.ProtectedData. Credentials are encrypted
#  with the current user's key and stored in a JSON file in the config dir.
#
#  This approach is:
#  - Pure .NET — no P/Invoke struct marshalling issues
#  - Per-user encrypted — only the current Windows user can decrypt
#  - Reliable across PS5/PS7/32-bit/64-bit
#
#  Store: $Script:FltConfigDir/credentials.win.json  (gitignored)
#
#  All functions prefixed _Win_ — load via CredentialBackends.ps1 only.
# =============================================================================

Add-Type -AssemblyName System.Security

function _Win_GetCredPath { Join-Path $Script:FltConfigDir 'credentials.win.json' }

function _Win_LoadStore {
    $path = _Win_GetCredPath
    if (-not (Test-Path $path)) { return @{} }
    try {
        $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $ht   = @{}
        foreach ($prop in $json.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        return $ht
    } catch { return @{} }
}

function _Win_SaveStore {
    param([hashtable]$Store)
    try {
        $Store | ConvertTo-Json -Compress |
            Set-Content -Path (_Win_GetCredPath) -Encoding UTF8 -Force
        return $true
    } catch { return $false }
}

function _Win_GetStoredPassword {
    param([string]$CredentialName)
    try {
        $store = _Win_LoadStore
        if (-not $store.ContainsKey($CredentialName)) { return $null }
        # Decrypt with DPAPI current-user scope
        $encrypted = [Convert]::FromBase64String($store[$CredentialName])
        $plain     = [System.Security.Cryptography.ProtectedData]::Unprotect(
                         $encrypted, $null,
                         [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [System.Text.Encoding]::UTF8.GetString($plain)
    } catch { return $null }
}

function _Win_SetStoredPassword {
    param([string]$CredentialName, [string]$PlainPassword)
    try {
        $store     = _Win_LoadStore
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainPassword)
        $encrypted  = [System.Security.Cryptography.ProtectedData]::Protect(
                          $plainBytes, $null,
                          [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        $store[$CredentialName] = [Convert]::ToBase64String($encrypted)
        return _Win_SaveStore -Store $store
    } catch { return $false }
}

function _Win_RemoveStoredPassword {
    param([string]$CredentialName)
    try {
        $store = _Win_LoadStore
        if ($store.ContainsKey($CredentialName)) {
            $store.Remove($CredentialName)
            return _Win_SaveStore -Store $store
        }
        return $true
    } catch { return $false }
}