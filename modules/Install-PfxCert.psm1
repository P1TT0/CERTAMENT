function Install-PfxCert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PfxPath,

        [Parameter(Mandatory = $true)]
        [SecureString]$Password
    )

    if (-not (Test-Path $PfxPath)) {
        Write-Error "PFX non trovato: $PfxPath"
        return $false
    }

    try {
        Write-Host "Installazione del certificato da: $PfxPath"

        $cert = Import-PfxCertificate -FilePath $PfxPath `
            -CertStoreLocation Cert:\LocalMachine\My `
            -Password $Password `
            -Exportable

        if ($cert) {
            Write-Host "Certificato importato: $($cert.Subject) [$($cert.Thumbprint)]"

            $check = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $cert.Thumbprint
            if ($check) {
                Write-Host "Verifica post-installazione riuscita."
                if ($cert.NotAfter -lt (Get-Date)) {
                    Write-Warning "ATTENZIONE: Il certificato installato e' gia' scaduto ($($cert.NotAfter))."
                }
                return $cert
            }
            else {
                Write-Warning "Certificato importato ma non trovato nello store."
                return $false
            }
        }
        else {
            Write-Warning "Nessun certificato importato."
            return $false
        }
    }
    catch {
        Write-Error "Errore durante l'importazione del certificato: $_"
        return $false
    }
}

Export-ModuleMember -Function Install-PfxCert
