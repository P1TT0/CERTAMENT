param(
    [string]$PfxPath = "C:\_install\e2e2_bak\2029E2E_CERTAMENT.pfx",
    [string]$PfxPassword = "",
    [string]$PasswordFile = ""
)

if (-not (Test-Path $PfxPath)) {
    throw "PFX non trovato: $PfxPath"
}

if ([string]::IsNullOrWhiteSpace($PfxPassword) -and -not [string]::IsNullOrWhiteSpace($PasswordFile) -and (Test-Path $PasswordFile)) {
    $PfxPassword = (Get-Content -Path $PasswordFile -Raw -ErrorAction Stop).Trim()
}

if ([string]::IsNullOrWhiteSpace($PfxPassword)) {
    throw "Password PFX non fornita. Usare -PfxPassword oppure -PasswordFile."
}

$securePassword = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
$pfxData = Get-PfxData -FilePath $PfxPath -Password $securePassword
$endEntityCertificate = $pfxData.EndEntityCertificates

Write-Host ('PFX Path: ' + $PfxPath)
Write-Host ('PFX Thumb: ' + $endEntityCertificate.Thumbprint)
Write-Host ('PFX Expires: ' + $endEntityCertificate.NotAfter)
Write-Host ('PFX Subject: ' + $endEntityCertificate.Subject)

$thumbprintNormalized = ($endEntityCertificate.Thumbprint -replace '\s','').ToUpper()
$installedCertificate = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    ($_.Thumbprint -replace '\s','').ToUpper() -eq $thumbprintNormalized
}

if ($installedCertificate) {
    Write-Host 'WARNING: questo certificato risulta gia installato in LocalMachine\My'
}
else {
    Write-Host 'OK: questo certificato non e ancora installato in LocalMachine\My'
}
