$thumbprint = Read-Host "Inserisci il thumbprint del certificato da rimuovere (senza spazi)"
$stores = @(
    "LocalMachine\My", "LocalMachine\Root", "LocalMachine\CA", "LocalMachine\TrustedPublisher", "LocalMachine\AuthRoot",
    "CurrentUser\My", "CurrentUser\Root", "CurrentUser\CA", "CurrentUser\TrustedPublisher", "CurrentUser\AuthRoot"
)

foreach ($store in $stores) {
    $storePath = "Cert:\$store"
    try {
        $certs = Get-ChildItem -Path $storePath | Where-Object { $_.Thumbprint -eq $thumbprint }
        foreach ($cert in $certs) {
            Remove-Item -Path $cert.PSPath -Force
            Write-Host "Certificato rimosso da: $storePath" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Errore nell'accesso a ${storePath}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

