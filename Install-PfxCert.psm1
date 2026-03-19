function Install-PfxCert {
    param(
        [string]$PfxPath,
        [SecureString]$Password
    )

    if (-not (Test-Path $PfxPath)) {
        Write-Error " PFX non trovato: $PfxPath"
        return $false
    }

    try {
        Write-Host "`n Installazione del certificato da: $PfxPath"

        $cert = Import-PfxCertificate -FilePath $PfxPath `
                                      -CertStoreLocation Cert:\LocalMachine\My `
                                      -Password $Password `
                                      -Exportable

        if ($cert) {
            Write-Host " Certificato importato con successo:"
            $cert | Format-List Subject, Thumbprint, NotAfter

            $check = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $cert.Thumbprint
            if ($check) {
                Write-Host " Verifica post-installazione riuscita: certificato trovato nello store."
                return $cert
            } else {
                Write-Warning "️ Certificato importato ma non trovato nello store."
                return $false
            }
        } else {
            Write-Warning "️ Nessun certificato importato."
            return $false
        }
    }
    catch {
        Write-Error " Errore durante l'importazione del certificato: $_"
        return $false
    }
}

