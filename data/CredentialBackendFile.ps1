# =============================================================================
#  TcFltPkgMgr — File Credential Backend
#  Stores credentials in an AES-256 encrypted JSON file.
#  Cross-platform — works on Windows, Linux, and macOS.
#
#  Key derivation: PBKDF2-SHA256 using a machine-specific secret
#  (hostname + a random salt stored alongside the encrypted file).
#  Not as secure as Windows Credential Manager or the system keyring,
#  but suitable for a controlled operator environment where the config
#  directory is protected by filesystem permissions.
#
#  Store location: $Script:FltConfigDir/credentials.local.enc  (gitignored)
#  Salt location:  $Script:FltConfigDir/credentials.salt       (gitignored)
#
#  All functions prefixed _File_ — load via CredentialBackends.ps1 only.
# =============================================================================

function _File_GetCredPath  { Join-Path $Script:FltConfigDir 'credentials.local.enc' }
function _File_GetSaltPath  { Join-Path $Script:FltConfigDir 'credentials.salt' }

# Derive a 256-bit AES key from the machine secret and stored salt.
function _File_DeriveKey {
    $saltPath = _File_GetSaltPath

    # Create salt on first use
    if (-not (Test-Path $saltPath)) {
        $newSalt = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($newSalt)
        [System.IO.File]::WriteAllBytes($saltPath, $newSalt)
    }
    $salt = [System.IO.File]::ReadAllBytes($saltPath)

    # Machine secret: hostname + OS username — not a strong secret but
    # provides basic protection against casual access to the config dir
    $machineSecret = "$($env:COMPUTERNAME)$($env:USERNAME)$($env:HOSTNAME)$($env:USER)"
    $secretBytes   = [System.Text.Encoding]::UTF8.GetBytes($machineSecret)

    $pbkdf2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
        $secretBytes, $salt, 100000,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    return $pbkdf2.GetBytes(32)   # 256-bit key
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
        $key        = _File_DeriveKey

        $aes             = [System.Security.Cryptography.Aes]::Create()
        $aes.Key         = $key
        $aes.IV          = $iv
        $aes.Mode        = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding     = [System.Security.Cryptography.PaddingMode]::PKCS7
        $decryptor       = $aes.CreateDecryptor()
        $plainBytes      = $decryptor.TransformFinalBlock($ciphertext, 0, $ciphertext.Length)
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
        $key       = _File_DeriveKey

        $aes         = [System.Security.Cryptography.Aes]::Create()
        $aes.Key     = $key
        $aes.GenerateIV()
        $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $encryptor   = $aes.CreateEncryptor()
        $ciphertext  = $encryptor.TransformFinalBlock($plainText, 0, $plainText.Length)
        $aes.Dispose()

        # Prepend IV to ciphertext
        $output = New-Object byte[] (16 + $ciphertext.Length)
        [Array]::Copy($aes.IV, $output, 16)
        [Array]::Copy($ciphertext, 0, $output, 16, $ciphertext.Length)
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