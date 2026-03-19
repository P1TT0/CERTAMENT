<#
.SYNOPSIS
    Remove a certificate from all stores by thumbprint.

.DESCRIPTION
    Removes a certificate matching the given thumbprint from all
    LocalMachine and CurrentUser stores. Useful for cleaning up
    old/replaced certificates.

.EXAMPLE
    .\Remove-Cert.ps1 -Thumbprint "ABC123..."
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Thumbprint
)

$Thumbprint = ($Thumbprint -replace '\s', '').ToUpper()

$stores = @(
    "LocalMachine\My", "LocalMachine\Root", "LocalMachine\CA",
    "LocalMachine\TrustedPublisher", "LocalMachine\AuthRoot",
    "CurrentUser\My", "CurrentUser\Root", "CurrentUser\CA",
    "CurrentUser\TrustedPublisher", "CurrentUser\AuthRoot"
)

$removed = 0
foreach ($store in $stores) {
    $storePath = "Cert:\$store"
    try {
        $certs = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Thumbprint }
        foreach ($cert in $certs) {
            Remove-Item -Path $cert.PSPath -Force
            Write-Host "Rimosso da: $storePath" -ForegroundColor Yellow
            $removed++
        }
    }
    catch {
        Write-Host "Errore nell'accesso a ${storePath}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($removed -eq 0) {
    Write-Host "Certificato $Thumbprint non trovato in nessuno store." -ForegroundColor Yellow
}
else {
    Write-Host "Rimosso da $removed store." -ForegroundColor Green
}
