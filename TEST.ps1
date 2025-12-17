$Button1_Click = {
}
# ========================
# CERTAMENT - Verifica certificati
# ========================

# --- Controllo esecuzione come amministratore ---
if (-not ((New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))) {
    Write-Warning "Lo script non è in esecuzione come Amministratore. Rilancio..."
    Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# --- Caricamento configurazione ---
$configPath = "$PSScriptRoot\config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "File di configurazione non trovato: $configPath"
    exit
}

$config = Get-Content -Raw -Path $configPath | ConvertFrom-Json

# --- Import del modulo BC più recente ---
if ($config.BusinessCentral.UseLatestModule -eq $true) {
    $bcModulePaths = Get-ChildItem -Path "C:\Program Files\Microsoft Dynamics 365 Business Central" `
                                   -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" `
                                   -ErrorAction SilentlyContinue

    if (-not $bcModulePaths) {
        Write-Error "Nessun modulo Business Central trovato."
        exit
    }

    $bcModulePath = $bcModulePaths | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    Import-Module $bcModulePath -Force | Out-Null
    Write-Host "Modulo BC importato da: $bcModulePath"
}

# --- Import moduli locali ---
Import-Module "$PSScriptRoot\Get-BCThumbprint.psm1" -Force
Import-Module "$PSScriptRoot\Get-CertDetails.psm1" -Force
Import-Module "$PSScriptRoot\Get-PfxFile.psm1" -Force
Import-Module "$PSScriptRoot\Install-PfxCert.psm1" -Force
Import-Module "$PSScriptRoot\Update-BCServiceCert.psm1" -Force
Import-Module "$PSScriptRoot\Update-IISBinding.psm1" -Force
Import-Module "$PSScriptRoot\Test-BCWebServices.psm1" -Force
Import-Module "$PSScriptRoot\Send-Notification.psm1" -Force

# ========================
# Funzione principale
# ========================
function Main {
    Write-Host "`nAvvio CERTAMENT - Verifica certificati..."

    $hostname = $env:COMPUTERNAME
    $pfxPath = $config.Pfx.Path
    $expiryThreshold = [int]$config.Notifications.CertificateExpiry.NotifyBeforeDays

    # Ottieni certificato attuale
    $thumbprint = Get-BcThumbprint
    if (-not $thumbprint) {
        Write-Warning "Nessun certificato configurato in Business Central."
        return
    }

    $certDetails = $thumbprint | Get-CertDetails
    $currentExpiry = $certDetails.NotAfter
    $daysLeft = [math]::Floor(($currentExpiry - (Get-Date)).TotalDays)

    if ($daysLeft -lt 0) {
        Write-Warning "Il certificato risulta già scaduto ($(-$daysLeft) giorni fa)."
        $daysLeft = 0
    }

    Write-Host "Certificato attuale: $($certDetails.Subject)"
    Write-Host "Scadenza: $currentExpiry ($daysLeft giorni rimanenti)"

    # --- Se il certificato è in scadenza ---
    if ($daysLeft -le $expiryThreshold) {
        Write-Warning "Il certificato scadrà tra $daysLeft giorni. Avvio verifica PFX disponibile..."

        $pfxFile = Get-PfxFile -Path $pfxPath

        # Caso 1: Nessun file PFX trovato
        if ([string]::IsNullOrWhiteSpace($pfxFile)) {
            Write-Warning "Nessun file PFX trovato in $pfxPath"

            $msg = @"
Il certificato **$($certDetails.Subject)** scadrà tra **$daysLeft giorni**.
Caricare un nuovo file PFX valido sul server **$hostname** nel percorso configurato:
**$pfxPath**
"@

            Send-Notification -Title "CERTAMENT - Certificato in scadenza" `
                              -Message $msg `
                              -Target "Customer"
            return
        }

        # Caso 2: PFX presente ma non leggibile
        try {
            $pfxPassword = ConvertTo-SecureString $config.Pfx.Password -AsPlainText -Force
            $pfxDetails = Get-PfxData -FilePath $pfxFile -Password $pfxPassword
            $pfxExpiry = $pfxDetails.EndEntityCertificates.NotAfter
        }
        catch {
            Write-Warning "Errore durante la lettura del file PFX: $($_.Exception.Message)"
            $pfxExpiry = $null
        }

        if ($null -eq $pfxExpiry) {
            Write-Warning "Impossibile determinare la scadenza del PFX."

            $msg = @"
Il certificato **$($certDetails.Subject)** scadrà tra **$daysLeft giorni**, ma non è stato possibile verificare il file PFX.
Caricare un nuovo file PFX valido sul server **$hostname** nel percorso configurato:
**$pfxPath**
"@

            Send-Notification -Title "CERTAMENT - Certificato in scadenza" `
                              -Message $msg `
                              -Target "Customer"
            return
        }

        # Caso 3: Il PFX non è più recente
        if ($pfxExpiry -le $currentExpiry) {
            Write-Warning "Il PFX non è più recente o è uguale al certificato attuale."

            $msg = @"
Il certificato **$($certDetails.Subject)** scadrà tra **$daysLeft giorni**.
È presente un file PFX in **$pfxPath**, ma non contiene un certificato più recente.
Caricare un nuovo PFX aggiornato.
"@

            Send-Notification -Title "CERTAMENT - Certificato non aggiornato" `
                              -Message $msg `
                              -Target "Customer"
            return
        }

        # Caso 4: PFX valido e più recente
        Write-Host "PFX valido e più recente trovato, installazione in corso..."

        $installedCert = Install-PfxCert -PfxPath $pfxFile -Password $pfxPassword
        if ($installedCert) {
            Write-Host "Certificato installato correttamente: $($installedCert.Subject)"

            Update-BCServiceCert -NewThumbprint $installedCert.Thumbprint | Out-Null
            Update-IISBinding -NewThumbprint $installedCert.Thumbprint | Out-Null
            iisreset | Out-Null
            Test-BCWebServices | Out-Null

            $msg = @"
È stato installato un nuovo certificato sul server **$hostname**.

**Dettagli:**
- Certificato: $($installedCert.Subject)
- Thumbprint: $($installedCert.Thumbprint)
- Scadenza: $($installedCert.NotAfter)

Aggiornati i servizi Business Central e IIS.
"@

            Send-Notification -Title "CERTAMENT - Certificato aggiornato" `
                              -Message $msg `
                              -Target "Internal"
        }
        else {
            Write-Warning "Installazione certificato fallita."
        }
    }
    else {
        Write-Host "Certificato attuale valido. Nessuna azione necessaria."
    }
}

Main
