# =============================================================================
#  TcFltPkgMgr — File Credential Backend
#  Stores credentials in an AES-256-CBC encrypted JSON file.
#  Cross-platform — works on Windows, Linux, and macOS.
#
#  Key: a cryptographically random 32-byte key generated once on first use
#  and stored in credentials.key. Security comes entirely from filesystem
#  permissions on the config directory — the key is not derived from any
#  guessable machine property.
#
#  On Linux, restrict the config directory:
#    chmod 700 ~/.config/tcfltpkgmgr
#
#  Future (Phase 5): Ansible Vault integration will allow vault passwords
#  to be stored here, with the vault password itself protected by this backend.
#  See Plan.md Phase 5.6 for details.
#
#  Store location: $Script:FltConfigDir/credentials.local.enc  (gitignored)
#  Key location:   $Script:FltConfigDir/credentials.key        (gitignored)
#
#  All functions prefixed _File_ — load via CredentialBackends.ps1 only.
# =============================================================================

function _File_GetCredPath { Join-Path $Script:FltConfigDir 'credentials.local.enc' }
function _File_GetKeyPath  { Join-Path $Script:FltConfigDir 'credentials.key' }

# Load or generate the 256-bit AES machine key.
# The key is random and stored in credentials.key — never derived from
# guessable properties like hostname or username.
function _File_GetOrCreateKey {
    $keyPath = _File_GetKeyPath

    if (-not (Test-Path $keyPath)) {
        # Generate a cryptographically random 32-byte key on first use
        $key = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($key)
        [System.IO.File]::WriteAllBytes($keyPath, $key)

        # On Linux/macOS: restrict key file to owner-read-only (chmod 600)
        if (-not $IsWindows) {
            try {
                & chmod 600 $keyPath 2>$null
            } catch { }
        }

        Write-Verbose "TcFltPkgMgr: Generated new credential key at $keyPath"
    }

    return [System.IO.File]::ReadAllBytes($keyPath)
}

# Load and decrypt the credential store. Returns a hashtable of name→password.
function _File_LoadStore {
    $path = _File_GetCredPath
    if (-not (Test-Path $path)) { return @{} }
    try {
        $data = [System.IO.File]::ReadAllBytes($path)
        # Format: [16 bytes IV][remaining bytes ciphertext]
        if ($data.Length -lt 17) { return @{} }
        $iv         = $data[0..15]
        $ciphertext = $data[16..($data.Length - 1)]
        $key        = _File_GetOrCreateKey

        $aes         = [System.Security.Cryptography.Aes]::Create()
        $aes.Key     = $key
        $aes.IV      = $iv
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $decryptor   = $aes.CreateDecryptor()
        $plainBytes  = $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
        $aes.Dispose()

        $json = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        $obj  = $json | ConvertFrom-Json
        $ht   = @{}
        foreach ($prop in $obj.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
        return $ht
    } catch {
        Write-Warning "TcFltPkgMgr: Could not decrypt credential store — $($_.Exception.Message)"
        return @{}
    }
}

# Encrypt and save the credential store hashtable.
function _File_SaveStore {
    param([hashtable]$Store)
    try {
        $json      = $Store | ConvertTo-Json -Compress
        $plainText = [System.Text.Encoding]::UTF8.GetBytes($json)
        $key       = _File_GetOrCreateKey

        $aes         = [System.Security.Cryptography.Aes]::Create()
        $aes.Key     = $key
        $aes.GenerateIV()
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $encryptor   = $aes.CreateEncryptor()
        $ciphertext  = $encryptor.TransformFinalBlock($plainText, 0, $plainText.Length)

        # Prepend IV to ciphertext — IV is safe to store in plain text
        $output = New-Object byte[] (16 + $ciphertext.Length)
        [Array]::Copy($aes.IV, $output, 16)
        [Array]::Copy($ciphertext, 0, $output, 16, $ciphertext.Length)
        $aes.Dispose()

        [System.IO.File]::WriteAllBytes((_File_GetCredPath), $output)
        return $true
    } catch {
        Write-Warning "TcFltPkgMgr: Could not save credential store — $($_.Exception.Message)"
        return $false
    }
}

function _File_GetStoredPassword {
    param([string]$CredentialName)
    $store = _File_LoadStore
    if ($store.ContainsKey($CredentialName)) { return $store[$CredentialName] }
    return $null
}

function _File_SetStoredPassword {
    param([string]$CredentialName, [string]$PlainPassword)
    $store = _File_LoadStore
    $store[$CredentialName] = $PlainPassword
    return _File_SaveStore -Store $store
}

function _File_RemoveStoredPassword {
    param([string]$CredentialName)
    $store = _File_LoadStore
    if ($store.ContainsKey($CredentialName)) {
        $store.Remove($CredentialName)
        return _File_SaveStore -Store $store
    }
    return $true   # already absent = success
}