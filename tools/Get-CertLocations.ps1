<#
.SYNOPSIS
    Find which certificate stores contain a given thumbprint.

.DESCRIPTION
    Searches LocalMachine and CurrentUser stores for a certificate by thumbprint.
    Useful for debugging certificate placement issues.

.EXAMPLE
    .\Get-CertLocations.ps1 -Thumbprint "ABC123..."
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

$found = $false
foreach ($store in $stores) {
    $storePath = "Cert:\$store"
    try {
        $cert = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Thumbprint }
        if ($cert) {
            Write-Host "TROVATO in: $storePath" -ForegroundColor Green
            $found = $true
        }
    }
    catch {
        Write-Host "Errore nell'accesso a ${storePath}: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (-not $found) {
    Write-Host "Certificato $Thumbprint non trovato in nessuno store." -ForegroundColor Yellow
}
