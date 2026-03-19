
if (-not ((New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))) {
    Write-Warning "Lo script non è in esecuzione come Amministratore. Rilancio..."
    Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$configPath   = "$PSScriptRoot\config.json"
$config       = $null
$thumbprint   = $null
$certDetails  = $null
$pfxFile      = $null
$pfxPassword  = $null
$pfxDetails   = $null

if (-not (Test-Path $configPath)) {
    Write-Error " File di configurazione non trovato: $configPath"
    exit
}
$config = Get-Content -Raw -Path $configPath | ConvertFrom-Json

if ($config.BusinessCentral.UseLatestModule -eq $true) {
    $bcModulePaths = Get-ChildItem -Path "C:\Program Files\Microsoft Dynamics 365 Business Central" `
                                   -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" `
                                   -ErrorAction SilentlyContinue

    if (-not $bcModulePaths) {
        Write-Error " Nessun modulo Business Central trovato."
        exit
    }

    $bcModulePath = $bcModulePaths | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    Import-Module $bcModulePath -Force | Out-Null
    Write-Host " Modulo BC importato da: $bcModulePath"
}

Import-Module "$PSScriptRoot\Get-BCThumbprint.psm1" -Force
Import-Module "$PSScriptRoot\Get-CertDetails.psm1" -Force
Import-Module "$PSScriptRoot\Get-PfxFile.psm1" -Force
Import-Module "$PSScriptRoot\Install-PfxCert.psm1" -Force
Import-Module "$PSScriptRoot\Update-BCServiceCert.psm1" -Force
Import-Module "$PSScriptRoot\Update-IISBinding.psm1" -Force
Import-Module "$PSScriptRoot\Test-BCWebServices.psm1" -Force


function Main {
    Write-Host "`n Avvio CERTAMENT..."

    $thumbprint = Get-BcThumbprint
    if ($thumbprint) {
        Write-Host " Certificato attuale (BC): $thumbprint"
        $certDetails = $thumbprint | Get-CertDetails
        Write-Host "`n Dettagli certificato attuale:"
        $certDetails | Format-List
    } else {
        Write-Warning " Nessun certificato trovato nelle istanze BC."
    }

    $pfxFile = Get-PfxFile -Path $config.Pfx.Path
    if ($pfxFile) {
        Write-Host "`n PFX trovato: $pfxFile"

        $pfxPassword = ConvertTo-SecureString $config.Pfx.Password -AsPlainText -Force

        $pfxDetails = Get-PfxData -FilePath $pfxFile -Password $pfxPassword
        Write-Host "`n Dettagli PFX più recente:"
        $pfxDetails.EndEntityCertificates | Format-List
    } else {
        Write-Warning "️ Nessun file .pfx trovato in $($config.Pfx.Path)"
    }

$shouldInstall = $false
if ($certDetails -and $pfxDetails) {
    $currentExpiry = $certDetails.NotAfter
    $pfxExpiry     = $pfxDetails.EndEntityCertificates.NotAfter
    $currentThumb  = $certDetails.Thumbprint
    $pfxThumb      = $pfxDetails.EndEntityCertificates.Thumbprint

    Write-Host "`n Confronto certificati:"
    Write-Host "   ️ Scadenza attuale: $currentExpiry"
    Write-Host "   ️ Scadenza PFX    : $pfxExpiry"

    if ($pfxExpiry -gt $currentExpiry -and $pfxThumb -ne $currentThumb) {
        Write-Host " Il PFX è più recente e pronto a sostituire il certificato attuale!"
        $shouldInstall = $true
    } elseif ($pfxThumb -eq $currentThumb) {
        Write-Host " Il PFX contiene lo stesso certificato già installato. Nessuna azione necessaria."
    } else {
        Write-Host "️ Il PFX non è più recente del certificato attuale."
    }
}

if ($shouldInstall -and $pfxDetails -and $pfxFile -and $pfxPassword) {
    Write-Host "`n Installazione del nuovo certificato..."
    $installedCert = Install-PfxCert -PfxPath $pfxFile -Password $pfxPassword

    if ($installedCert) {
        Write-Host " Certificato installato correttamente nello store:"
        $installedCert | Format-List Subject, Thumbprint, NotAfter

        Write-Host "`n Aggiornamento istanze Business Central..."
        $updateResults = Update-BCServiceCert -NewThumbprint $installedCert.Thumbprint

                if ($updateResults) {
            Write-Host "`n Risultati aggiornamento BC:"
            $updateResults | Format-Table -AutoSize
        } else {
            Write-Warning " Nessun risultato dall'aggiornamento delle istanze BC."
        }

        Write-Host "`n Aggiornamento binding IIS..."
        try {
            $iisResults = Update-IISBinding -NewThumbprint $installedCert.Thumbprint

            if ($iisResults) {
                Write-Host "`n Risultati aggiornamento IIS:"
                $iisResults | Format-Table -AutoSize
            } else {
                Write-Warning "️ Nessun binding IIS trovato o aggiornato."
            }

            Write-Host "`n️ Riavvio IIS per applicare le modifiche..."
            iisreset | Out-Null
            Write-Host " IIS riavviato con successo."
        }
        catch {
            Write-Warning " Errore durante l'aggiornamento dei binding IIS: $($_.Exception.Message)"
        }

    } else {
        Write-Warning " Installazione del certificato fallita."
    }
} else {
    Write-Host "`n Nessuna installazione necessaria: il certificato è già aggiornato o non è più recente."
}
}
Main
