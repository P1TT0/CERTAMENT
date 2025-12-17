$thumbprint = Read-Host "Inserisci il thumbprint del certificato (senza spazi)"
$stores = @(
    "LocalMachine\My", "LocalMachine\Root", "LocalMachine\CA", "LocalMachine\TrustedPublisher", "LocalMachine\AuthRoot",
    "CurrentUser\My", "CurrentUser\Root", "CurrentUser\CA", "CurrentUser\TrustedPublisher", "CurrentUser\AuthRoot"
)

foreach ($store in $stores) {
    $storePath = "Cert:\$store"
    try {
        $cert = Get-ChildItem -Path $storePath | Where-Object { $_.Thumbprint -eq $thumbprint }
        if ($cert) {
            Write-Host "Certificato trovato in: $storePath" -ForegroundColor Green
        }
    } catch {
        Write-Host "Errore nell'accesso a ${storePath}: $($_.Exception.Message)" -ForegroundColor Red
    }
}
