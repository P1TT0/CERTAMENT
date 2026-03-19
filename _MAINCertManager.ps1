<#
.SYNOPSIS
    CERTAMENT - Automated certificate lifecycle manager for Business Central.

.DESCRIPTION
    Detects expiring certificates, installs newer PFX replacements, updates
    Business Central service instances, IIS bindings, and sends notifications.

    Designed to run unattended via Scheduled Task on client servers.

.NOTES
    Requires: Administrator privileges, IIS, Business Central Management module.
    Configure via config.json (see config.example.json for template).
#>

# --- Require Administrator ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "CERTAMENT richiede privilegi di Amministratore. Rilancio..."
    Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ============================================================
# Configuration
# ============================================================
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "Config non trovato: $configPath (copiare config.example.json e personalizzare)"
    exit 1
}

$config = Get-Content -Raw -Path $configPath | ConvertFrom-Json

# ============================================================
# Logging
# ============================================================
$logPath = if ($config.Logging -and -not [string]::IsNullOrWhiteSpace([string]$config.Logging.Path)) {
    [string]$config.Logging.Path
}
else {
    "logs"
}

$logDir = Join-Path $PSScriptRoot $logPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$logFile = Join-Path $logDir ("certament_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $logFile -Append | Out-Null

# Clean old logs
if ($config.Logging.RetentionDays) {
    $cutoff = (Get-Date).AddDays(-[int]$config.Logging.RetentionDays)
    Get-ChildItem -Path $logDir -Filter "certament_*.log" |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Import BC Management Module
# ============================================================
if ($config.BusinessCentral.UseLatestModule -eq $true) {
    $bcModulePaths = Get-ChildItem -Path "C:\Program Files\Microsoft Dynamics 365 Business Central" `
        -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" `
        -ErrorAction SilentlyContinue

    if (-not $bcModulePaths) {
        Write-Error "Nessun modulo Business Central trovato."
        Stop-Transcript | Out-Null
        exit 1
    }

    $bcModulePath = $bcModulePaths | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    Import-Module $bcModulePath -Force | Out-Null
    Write-Host "Modulo BC importato da: $bcModulePath"
}

# ============================================================
# Import CERTAMENT Modules
# ============================================================
$moduleDir = Join-Path $PSScriptRoot "modules"
@(
    'Get-BCThumbprint',
    'Get-CertDetails',
    'Get-PfxFile',
    'Install-PfxCert',
    'Update-BCServiceCert',
    'Update-IISBinding',
    'Test-BCWebServices',
    'Send-Notification'
) | ForEach-Object {
    Import-Module (Join-Path $moduleDir "$_.psm1") -Force
}

$script:HeartbeatFailureNotified = $false

# ============================================================
# Helper: build webhook hashtable from config
# ============================================================
function Get-WebhookTable {
    $wh = @{}
    if ($config.Notifications.Webhooks.Customer) { $wh['Customer'] = $config.Notifications.Webhooks.Customer }
    if ($config.Notifications.Webhooks.Internal) { $wh['Internal'] = $config.Notifications.Webhooks.Internal }
    return $wh
}

# ============================================================
# Helper: send failure notification
# ============================================================
function Send-FailureNotification {
    param([string]$Context, [string]$ErrorDetail)

    $webhooks = Get-WebhookTable
    if (-not $webhooks.ContainsKey('Internal')) { return }

    $hostname = $env:COMPUTERNAME
    $msg = @"
Si e' verificato un errore durante l'esecuzione di CERTAMENT sul server **$hostname**.

**Contesto:** $Context
**Errore:** $ErrorDetail
"@

    Send-Notification -Title "CERTAMENT - Errore" -Message $msg -Target "Internal" -Webhooks $webhooks
}

# ============================================================
# Helper: heartbeat settings
# ============================================================
function Get-HeartbeatSettings {
    $enabled = $false
    $url = $null
    $timeoutSec = 10
    $notifyInternalOnFailure = $true

    if ($config.Heartbeat) {
        if ($null -ne $config.Heartbeat.Enabled) {
            $enabled = ($config.Heartbeat.Enabled -eq $true)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$config.Heartbeat.Url)) {
            $url = [string]$config.Heartbeat.Url
        }

        if ($null -ne $config.Heartbeat.TimeoutSec) {
            try {
                $parsedTimeout = [int]$config.Heartbeat.TimeoutSec
                if ($parsedTimeout -gt 0) { $timeoutSec = $parsedTimeout }
            }
            catch { }
        }

        if ($null -ne $config.Heartbeat.NotifyInternalOnFailure) {
            $notifyInternalOnFailure = ($config.Heartbeat.NotifyInternalOnFailure -eq $true)
        }
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        $enabled = $false
    }

    return [PSCustomObject]@{
        Enabled                 = $enabled
        Url                     = $url
        TimeoutSec              = $timeoutSec
        NotifyInternalOnFailure = $notifyInternalOnFailure
    }
}

# ============================================================
# Helper: send heartbeat to Azure
# ============================================================
function Invoke-Heartbeat {
    param(
        [string]$Status,
        [string]$Stage,
        [string]$Detail = ""
    )

    $hb = Get-HeartbeatSettings
    if (-not $hb.Enabled) { return $true }

    $payload = @{
        tool      = "CERTAMENT"
        server    = $env:COMPUTERNAME
        status    = $Status
        stage     = $Stage
        detail    = $Detail
        timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6

    try {
        Invoke-RestMethod -Method POST -Uri $hb.Url -ContentType "application/json; charset=utf-8" `
            -Body $payload -TimeoutSec $hb.TimeoutSec -ErrorAction Stop | Out-Null
        Write-Host "Heartbeat Azure inviato: $Status / $Stage"
        return $true
    }
    catch {
        $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
        Write-Warning "Heartbeat Azure fallito ($Status / $Stage): $errMsg"

        if ($hb.NotifyInternalOnFailure -and -not $script:HeartbeatFailureNotified) {
            $script:HeartbeatFailureNotified = $true
            try {
                Send-FailureNotification -Context "Heartbeat Azure ($Status / $Stage)" -ErrorDetail $errMsg
            }
            catch { }
        }

        return $false
    }
}

# ============================================================
# Main
# ============================================================
function Main {
    Write-Host ("=" * 60)
    Write-Host "CERTAMENT - Avvio [{0}] su {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME
    Write-Host ("=" * 60)

    $webhooks = Get-WebhookTable
    $hostname = $env:COMPUTERNAME
    $pfxPath = $config.Pfx.Path
    $hadPipelineErrors = $false

    Invoke-Heartbeat -Status "Started" -Stage "MainStart" -Detail "Esecuzione CERTAMENT avviata" | Out-Null
    $notifyBeforeDaysRaw = $null
    if ($config.Notifications -and $config.Notifications.CertificateExpiry) {
        $notifyBeforeDaysRaw = $config.Notifications.CertificateExpiry.NotifyBeforeDays
    }

    if ($null -ne $notifyBeforeDaysRaw -and -not [string]::IsNullOrWhiteSpace([string]$notifyBeforeDaysRaw)) {
        $expiryThreshold = [int]$notifyBeforeDaysRaw
    }
    else {
        $expiryThreshold = 30
    }

    if ($config.IIS -and -not [string]::IsNullOrWhiteSpace([string]$config.IIS.SiteName)) {
        $iisSiteName = [string]$config.IIS.SiteName
    }
    else {
        $iisSiteName = "Microsoft Dynamics 365 Business Central Web Client"
    }
    $iisRestart = $config.IIS.RestartAfterUpdate -ne $false

    # ----------------------------------------------------------
    # Step 1: Get current certificate from BC
    # ----------------------------------------------------------
    Write-Host "`n[1/7] Lettura certificato attuale da Business Central..."
    $thumbprint = Get-BCThumbprint
    if (-not $thumbprint) {
        Write-Warning "Nessun certificato configurato in Business Central."
        Send-FailureNotification -Context "Lettura certificato BC" -ErrorDetail "Nessun thumbprint trovato nelle istanze BC."
        Invoke-Heartbeat -Status "Error" -Stage "ReadBCThumbprint" -Detail "Nessun thumbprint BC configurato" | Out-Null
        Stop-Transcript | Out-Null
        return
    }

    # ----------------------------------------------------------
    # Step 2: Get cert details
    # ----------------------------------------------------------
    Write-Host "[2/7] Lettura dettagli certificato..."
    $certDetails = $thumbprint | Get-CertDetails
    if (-not $certDetails) {
        Send-FailureNotification -Context "Dettagli certificato" -ErrorDetail "Certificato $thumbprint non trovato nello store."
        Invoke-Heartbeat -Status "Error" -Stage "ReadCertDetails" -Detail "Certificato attuale non trovato nello store" | Out-Null
        Stop-Transcript | Out-Null
        return
    }

    $currentExpiry = $certDetails.NotAfter
    $daysLeft = [math]::Floor(($currentExpiry - (Get-Date)).TotalDays)
    if ($daysLeft -lt 0) { $daysLeft = 0 }

    Write-Host "Certificato: $($certDetails.Subject)"
    Write-Host "Thumbprint:  $($certDetails.Thumbprint)"
    Write-Host "Scadenza:    $currentExpiry ($daysLeft giorni rimanenti)"

    # ----------------------------------------------------------
    # Step 3: Check expiry threshold
    # ----------------------------------------------------------
    if ($daysLeft -gt $expiryThreshold) {
        Write-Host "`nCertificato valido. Nessuna azione necessaria."
        Invoke-Heartbeat -Status "Healthy" -Stage "NoActionNeeded" -Detail "Certificato valido ($daysLeft giorni rimanenti)" | Out-Null
        Stop-Transcript | Out-Null
        return
    }

    Write-Host "`n[3/7] Certificato in scadenza ($daysLeft giorni). Verifica PFX..."

    # ----------------------------------------------------------
    # Step 4: Find PFX
    # ----------------------------------------------------------
    $pfxFile = Get-PfxFile -Path $pfxPath

    # Case 1: No PFX found
    if ([string]::IsNullOrWhiteSpace($pfxFile)) {
        Write-Warning "Nessun file PFX trovato in $pfxPath"
        if ($webhooks.Count) {
            Send-Notification -Title "CERTAMENT - Certificato in scadenza" `
                -Message ("Il certificato **$($certDetails.Subject)** scadra tra **$daysLeft giorni**.`nCaricare un nuovo PFX sul server **$hostname** in: **$pfxPath**") `
                -Target "Customer" -Webhooks $webhooks
        }
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxMissing" -Detail "Nessun PFX trovato in $pfxPath" | Out-Null
        Stop-Transcript | Out-Null
        return
    }

    # Case 2: Read PFX
    Write-Host "[4/7] PFX trovato: $pfxFile. Lettura..."
    try {
        $pfxPassword = ConvertTo-SecureString $config.Pfx.Password -AsPlainText -Force
        $pfxData = Get-PfxData -FilePath $pfxFile -Password $pfxPassword
        $pfxExpiry = $pfxData.EndEntityCertificates.NotAfter
        $pfxThumb = $pfxData.EndEntityCertificates.Thumbprint
    }
    catch {
        Write-Warning "Errore lettura PFX: $($_.Exception.Message)"
        if ($webhooks.Count) {
            Send-Notification -Title "CERTAMENT - Certificato in scadenza" `
                -Message ("Il certificato **$($certDetails.Subject)** scadra tra **$daysLeft giorni** ma il PFX non e' leggibile.`nCaricare un nuovo PFX su **$hostname** in: **$pfxPath**") `
                -Target "Customer" -Webhooks $webhooks
        }
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxUnreadable" -Detail $_.Exception.Message | Out-Null
        Stop-Transcript | Out-Null
        return
    }

    # Case 3: PFX not newer
    if ($pfxExpiry -le $currentExpiry -or $pfxThumb -eq $certDetails.Thumbprint) {
        Write-Warning "Il PFX non e' piu recente del certificato attuale."
        if ($webhooks.Count) {
            Send-Notification -Title "CERTAMENT - PFX non aggiornato" `
                -Message ("Il certificato **$($certDetails.Subject)** scadra tra **$daysLeft giorni**.`nIl PFX presente in **$pfxPath** non contiene un certificato piu recente.`nCaricare un nuovo PFX aggiornato.") `
                -Target "Customer" -Webhooks $webhooks
        }
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxNotNewer" -Detail "PFX presente ma non piu recente del certificato attuale" | Out-Null
        Stop-Transcript | Out-Null
        return
    }

    # ----------------------------------------------------------
    # Case 4: PFX valid and newer - full pipeline
    # ----------------------------------------------------------
    Write-Host "[5/7] Installazione nuovo certificato..."
    $installedCert = Install-PfxCert -PfxPath $pfxFile -Password $pfxPassword
    if (-not $installedCert -or $installedCert -eq $false) {
        Send-FailureNotification -Context "Installazione PFX" -ErrorDetail "Install-PfxCert ha restituito errore per $pfxFile"
        Invoke-Heartbeat -Status "Error" -Stage "InstallPfx" -Detail "Install-PfxCert fallita" | Out-Null
        Stop-Transcript | Out-Null
        return
    }

    $newThumb = $installedCert.Thumbprint
    Write-Host "Installato: $($installedCert.Subject) [$newThumb]"

    # Update BC
    Write-Host "[6/7] Aggiornamento istanze Business Central..."
    $bcResults = Update-BCServiceCert -NewThumbprint $newThumb
    if ($bcResults) { $bcResults | Format-Table -AutoSize }

    $bcErrors = @($bcResults | Where-Object { $_.Result -eq 'Error' })
    if ($bcErrors.Count -gt 0) {
        $errText = ($bcErrors | ForEach-Object { "$($_.Instance): $($_.ErrorMessage)" }) -join "; "
        Send-FailureNotification -Context "Aggiornamento BC" -ErrorDetail $errText
        $hadPipelineErrors = $true
    }

    # Update IIS
    Write-Host "[7/7] Aggiornamento binding IIS..."
    try {
        $iisResults = Update-IISBinding -NewThumbprint $newThumb -SiteName $iisSiteName -RestartIIS:$iisRestart
        if ($iisResults) { $iisResults | Format-Table -AutoSize }
    }
    catch {
        Send-FailureNotification -Context "Aggiornamento IIS" -ErrorDetail $_.Exception.Message
        $hadPipelineErrors = $true
    }

    # Smoke test
    Write-Host "`nVerifica servizi web..."
    $wsResults = Test-BCWebServices
    if ($wsResults) { $wsResults | Format-Table -AutoSize }

    # Success notification
    if ($webhooks.Count) {
        $msg = @"
Nuovo certificato installato su server **$hostname**.

**Dettagli:**
- Soggetto: $($installedCert.Subject)
- Thumbprint: $newThumb
- Scadenza: $($installedCert.NotAfter)

Servizi BC e IIS aggiornati.
"@
        Send-Notification -Title "CERTAMENT - Certificato aggiornato" -Message $msg -Target "Internal" -Webhooks $webhooks
    }

    if ($hadPipelineErrors) {
        Invoke-Heartbeat -Status "CompletedWithWarnings" -Stage "MainEnd" -Detail "Pipeline completata con warning/errori parziali" | Out-Null
    }
    else {
        Invoke-Heartbeat -Status "Completed" -Stage "MainEnd" -Detail "Pipeline completata con successo" | Out-Null
    }

    Write-Host "`nCERTAMENT completato con successo."
}

try {
    Main
}
catch {
    Write-Error "Errore critico CERTAMENT: $($_.Exception.Message)"
    try { Invoke-Heartbeat -Status "Error" -Stage "UnhandledException" -Detail $_.Exception.Message | Out-Null } catch {}
    try { Send-FailureNotification -Context "Errore critico" -ErrorDetail $_.Exception.Message } catch {}
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
