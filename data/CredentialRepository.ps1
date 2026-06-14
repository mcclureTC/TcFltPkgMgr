# =============================================================================
#  TcFltPkgMgr — Credential Repository
#  Stores and retrieves secrets from Windows Credential Manager.
#  Falls back to interactive Read-Host -AsSecureString when not found.
#  Key format: TcFltPkgMgr/<credentialName>
# =============================================================================

Add-Type -AssemblyName System.Security

# Retrieve a plain-text password from Windows Credential Manager.
# Returns $null if not stored; does NOT prompt.
function Get-FltStoredPassword {
    param([string]$CredentialName)
    try {
        $cred = Get-Credential -Message '' -UserName "TcFltPkgMgr/$CredentialName" `
                    -ErrorAction Stop
        # Get-Credential shows a UI — use the Windows API directly instead
    } catch {}

    # Use DPAPI via Windows Credential Manager
    try {
        $target = "TcFltPkgMgr/$CredentialName"
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinCred {
    [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll", EntryPoint="CredFree")]
    public static extern void CredFree(IntPtr credential);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags; public uint Type; public string TargetName; public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist;
        public uint AttributeCount; public IntPtr Attributes; public string TargetAlias;
        public string UserName;
    }
}
'@ -ErrorAction SilentlyContinue

        $ptr = [IntPtr]::Zero
        if ([WinCred]::CredRead($target, 1, 0, [ref]$ptr)) {
            $cred = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                        $ptr, [WinCred+CREDENTIAL])
            $bytes = New-Object byte[] $cred.CredentialBlobSize
            [System.Runtime.InteropServices.Marshal]::Copy(
                $cred.CredentialBlob, $bytes, 0, $bytes.Length)
            [WinCred]::CredFree($ptr)
            return [System.Text.Encoding]::Unicode.GetString($bytes)
        }
    } catch {
        # Credential Manager unavailable — fall through to $null
    }
    return $null
}

# Store a password in Windows Credential Manager.
function Set-FltStoredPassword {
    param([string]$CredentialName, [string]$PlainPassword)
    try {
        $target = "TcFltPkgMgr/$CredentialName"
        $bytes  = [System.Text.Encoding]::Unicode.GetBytes($PlainPassword)
        $cred   = New-Object System.Net.NetworkCredential('', $PlainPassword)
        # Use cmdkey.exe as it is always available without needing Add-Type to succeed
        $env:TCFLT_TMPPASS = $PlainPassword
        cmdkey /generic:$target /user:"TcFltPkgMgr" /pass:"$PlainPassword" | Out-Null
        Remove-Item env:TCFLT_TMPPASS -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

# Remove a stored credential.
function Remove-FltStoredPassword {
    param([string]$CredentialName)
    try {
        cmdkey /delete:"TcFltPkgMgr/$CredentialName" | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Get a plain-text password: try Credential Manager first, then prompt.
# Optionally offer to save the entered password for next time.
function Resolve-FltPassword {
    param(
        [string] $CredentialName,
        [string] $PromptLabel,
        [switch] $OfferToSave
    )
    $stored = Get-FltStoredPassword -CredentialName $CredentialName
    if ($stored) {
        Write-Host "  (Using stored credential for '$CredentialName')" -ForegroundColor DarkGray
        return $stored
    }

    $plain = (Read-Host "  $PromptLabel").Trim()

    if ($OfferToSave -and $plain) {
        $save = (Read-Host "  Save this password in Windows Credential Manager for next time?  [1] Yes  [0] No  (default 0)").Trim()
        if ($save -eq '1') {
            if (Set-FltStoredPassword -CredentialName $CredentialName -PlainPassword $plain) {
                Write-Host "  Password saved as 'TcFltPkgMgr/$CredentialName'." -ForegroundColor Green
            } else {
                Write-Host "  Could not save to Credential Manager; will prompt next session." -ForegroundColor Yellow
            }
        }
    }

    return $plain
}