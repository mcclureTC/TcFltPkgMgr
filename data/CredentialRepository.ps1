# =============================================================================
#  TcFltPkgMgr — Credential Repository
#  High-level credential orchestration — prompting, saving, retrieval.
#  Low-level storage is handled by the active credential backend selected
#  at startup via CredentialBackends.ps1.
#
#  The three storage primitives (Get/Set/Remove-FltStoredPassword) are
#  defined in CredentialAdapter.ps1 and delegate to the active backend.
# =============================================================================

# Get a plain-text password: try the credential store first, then prompt.
# Optionally offer to save the entered password for next time.
function Resolve-FltPassword {
    param(
        [string] $CredentialName,
        [string] $PromptLabel,
        [switch] $OfferToSave,
        [switch] $Silent        # suppress informational console output (for diagnostics/scripts)
    )
    $stored = Get-FltStoredPassword -CredentialName $CredentialName
    if ($stored) {
        if (-not $Silent) {
            Write-Host "  (Using stored credential for '$CredentialName')" -ForegroundColor DarkGray
        }
        return $stored
    }

    $plain = (Read-Host "  $PromptLabel").Trim()

    if ($OfferToSave -and $plain) {
        $backendLabel = if ($Script:FltCredentialBackend -eq 'windows') {
            'DPAPI-encrypted file (Windows, current user only)'
        } else {
            'AES-encrypted local file'
        }
        $save = (Read-Host "  Save this password in $backendLabel for next time?  [1] Yes  [0] No  (default 0)").Trim()
        if ($save -eq '1') {
            if (Set-FltStoredPassword -CredentialName $CredentialName -PlainPassword $plain) {
                Write-Host "  Password saved as 'TcFltPkgMgr/$CredentialName'." -ForegroundColor Green
            } else {
                Write-Host "  Could not save credential; will prompt next session." -ForegroundColor Yellow
            }
        }
    }

    return $plain
}