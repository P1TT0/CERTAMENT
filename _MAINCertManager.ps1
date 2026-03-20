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

$configRaw = Get-Content -Raw -Path $configPath
# Rimuovi righe con commenti // (stile JSON non standard) prima del parse
$configRaw = ($configRaw -split "\r?\n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
$config = $configRaw | ConvertFrom-Json

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
    $bcCommand = Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue
    if ($bcCommand) {
        Write-Host "Modulo BC gia disponibile in sessione."
    }
    else {
        $bcModulePaths = Get-ChildItem -Path "C:\Program Files\Microsoft Dynamics 365 Business Central" `
            -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" `
            -ErrorAction SilentlyContinue

        if (-not $bcModulePaths) {
            Write-Error "Nessun modulo Business Central trovato."
            Stop-Transcript | Out-Null
            exit 1
        }

        $orderedCandidates = $bcModulePaths | Sort-Object `
            @{ Expression = { if ($_.FullName -match '\\Admin\\') { 1 } else { 0 } } }, `
            @{ Expression = 'LastWriteTime'; Descending = $true }

        $importedPath = $null
        $importErrors = @()

        foreach ($candidate in $orderedCandidates) {
            try {
                Remove-Module -Name Microsoft.Dynamics.Nav.Management -ErrorAction SilentlyContinue
                Import-Module $candidate.FullName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

                $bcCommand = Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue
                if ($bcCommand) {
                    $importedPath = $candidate.FullName
                    break
                }

                $importErrors += ("{0} -> cmdlet Get-NAVServerInstance non disponibile" -f $candidate.FullName)
            }
            catch {
                $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
                $importErrors += ("{0} -> {1}" -f $candidate.FullName, $errMsg)
            }
        }

        if (-not $importedPath) {
            $firstErrors = ($importErrors | Select-Object -First 5) -join "`n"
            Write-Error "Nessun modulo BC importabile in questa sessione. Errori principali:`n$firstErrors"
            Stop-Transcript | Out-Null
            exit 1
        }

        Write-Host "Modulo BC importato da: $importedPath"
    }
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
# Helper: exit with transcript cleanup
# ============================================================
function Exit-WithCode {
    param([int]$Code)
    try { Stop-Transcript | Out-Null } catch {}
    exit $Code
}

# ============================================================
# Helper: customer context
# ============================================================
function Get-CustomerName {
    if ($config.Context -and -not [string]::IsNullOrWhiteSpace([string]$config.Context.CustomerName)) {
        return [string]$config.Context.CustomerName.Trim()
    }
    return $null
}

$script:CustomerName = Get-CustomerName

function Get-CustomerLabel {
    if ([string]::IsNullOrWhiteSpace([string]$script:CustomerName)) {
        return "Cliente non specificato"
    }
    return [string]$script:CustomerName
}

function Get-CertamentTitle {
    param([string]$BaseTitle)

    if ([string]::IsNullOrWhiteSpace([string]$script:CustomerName)) {
        return $BaseTitle
    }
    return ("{0} [{1}]" -f $BaseTitle, $script:CustomerName)
}

# ============================================================
# Helper: build webhook hashtable from config
# ============================================================
function Get-WebhookTable {
    if ($config.Notifications -and $config.Notifications.EnableWebhook -eq $false) {
        Write-Host "[INFO] Webhook disabilitati (Notifications.EnableWebhook=false). Notifiche soppresse."
        return @{}
    }
    $wh = @{}
    if ($config.Notifications.Webhooks.Customer) { $wh['Customer'] = $config.Notifications.Webhooks.Customer }
    if ($config.Notifications.Webhooks.Internal) { $wh['Internal'] = $config.Notifications.Webhooks.Internal }
    return $wh
}

# ============================================================
# Helper: send internal notification
# ============================================================
function Send-InternalNotification {
    param(
        [string]$Title,
        [string]$Message
    )

    $webhooks = Get-WebhookTable
    if (-not $webhooks.ContainsKey('Internal')) {
        Write-Warning "Webhook Internal non configurato. Notifica interna non inviata."
        return $false
    }

    $fullTitle = Get-CertamentTitle -BaseTitle $Title
    return (Send-Notification -Title $fullTitle -Message $Message -Target "Internal" -Webhooks $webhooks)
}

# ============================================================
# Helper: send customer notification with fallback on failure
# ============================================================
function Send-CustomerNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$ContextLabel = ""
    )

    if ($config.Notifications -and $config.Notifications.CertificateExpiry -and
        $config.Notifications.CertificateExpiry.EnableCustomerNotification -eq $false) {
        Write-Host "[INFO] Notifiche Customer disabilitate (EnableCustomerNotification=false). Messaggio soppresso."
        return $true
    }

    $webhooks = Get-WebhookTable
    $fullTitle = Get-CertamentTitle -BaseTitle $Title

    if (-not $webhooks.ContainsKey('Customer')) {
        $detail = if ([string]::IsNullOrWhiteSpace($ContextLabel)) { "Webhook Customer non configurato" } else { $ContextLabel }
        Write-Warning "Webhook Customer non configurato."
        Invoke-Heartbeat -Status "NotificationFailed" -Stage "CustomerNotificationMissing" -Detail $detail | Out-Null

        $fallbackMsg = @"
Invio notifica CUSTOMER non possibile su server **$env:COMPUTERNAME**.

**Cliente:** $(Get-CustomerLabel)
**Contesto:** $detail
**Motivo:** Webhook Customer non configurato.
"@
        $null = Send-InternalNotification -Title "CERTAMENT - Alert notifica Customer fallita" -Message $fallbackMsg
        return $false
    }

    $sent = Send-Notification -Title $fullTitle -Message $Message -Target "Customer" -Webhooks $webhooks
    if ($sent) { return $true }

    $failDetail = if ([string]::IsNullOrWhiteSpace($ContextLabel)) { "Invio notifica Customer fallito" } else { $ContextLabel }
    Invoke-Heartbeat -Status "NotificationFailed" -Stage "CustomerNotification" -Detail $failDetail | Out-Null

    $fallbackMsg = @"
Invio notifica CUSTOMER fallito su server **$env:COMPUTERNAME**.

**Cliente:** $(Get-CustomerLabel)
**Contesto:** $failDetail
**Azione:** verificare webhook Customer / flow Power Automate.
"@
    $null = Send-InternalNotification -Title "CERTAMENT - Alert notifica Customer fallita" -Message $fallbackMsg
    return $false
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

**Cliente:** $(Get-CustomerLabel)
**Contesto:** $Context
**Errore:** $ErrorDetail
"@

    $null = Send-InternalNotification -Title "CERTAMENT - Errore" -Message $msg
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
        customer  = (Get-CustomerLabel)
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
# Helper: wait for web services with polling
# ============================================================
function Wait-ForWebServices {
    param(
        [int]$MaxWaitSec = 600,
        [int]$IntervalSec = 30,
        [string]$ExpectedThumbprint = ''
    )

    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $attempt = 0
    $wsParams = @{ TimeoutSec = 15 }
    if ($ExpectedThumbprint) { $wsParams['ExpectedThumbprint'] = $ExpectedThumbprint }

    while ((Get-Date) -lt $deadline) {
        $attempt++
        Write-Host ("  Attesa servizi web (tentativo {0}, max {1}s)..." -f $attempt, $MaxWaitSec)
        $results = Test-BCWebServices @wsParams
        if ($results) {
            $errors = @($results | Where-Object { $_.Status -eq 'ERROR' })
            $sslMismatches = @($results | Where-Object { $_.SslMatch -eq $false })
            if ($errors.Count -eq 0 -and $sslMismatches.Count -eq 0) {
                Write-Host "  Servizi web tutti operativi, SSL verificato."
                return $results
            }
            if ($errors.Count -gt 0) {
                $errSummary = ($errors | ForEach-Object { "$($_.Instance): $($_.Error)" }) -join '; '
                Write-Host "  Servizi non ancora pronti: $errSummary"
            }
            if ($sslMismatches.Count -gt 0) {
                $sslSummary = ($sslMismatches | ForEach-Object { "$($_.Instance): SSL $($_.SslThumbprint)" }) -join '; '
                Write-Host "  SSL mismatch: $sslSummary"
            }
        }
        else {
            Write-Host "  Test-BCWebServices non ha restituito risultati."
        }
        if ((Get-Date).AddSeconds($IntervalSec) -ge $deadline) { break }
        Start-Sleep -Seconds $IntervalSec
    }
    Write-Warning "Timeout ($MaxWaitSec s): alcuni servizi non rispondono."
    return $results
}

# ============================================================
# Helper: verify BC post-update (thumbprint + Running state)
# ============================================================
function Test-BCPostUpdate {
    param([string]$ExpectedThumbprint)

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $errors = @()

    try {
        $instances = Get-NAVServerInstance -ErrorAction Stop
    }
    catch {
        return @("Impossibile enumerare istanze BC: $($_.Exception.Message)")
    }

    foreach ($inst in $instances) {
        $name = $inst.ServerInstance
        $hasThumb = $false

        try {
            $thumb = Get-NAVServerConfiguration -ServerInstance $name -KeyName "ServicesCertificateThumbprint" -ErrorAction Stop
            if ($thumb -and $thumb.Trim() -ne "") {
                $hasThumb = $true
                $thumbNorm = ($thumb -replace '\s', '').ToUpper()
                if ($thumbNorm -ne $expectedNorm) {
                    $errors += "$name : thumbprint $thumbNorm (atteso $expectedNorm)"
                }
            }
        }
        catch {
            $errors += "$name : errore lettura thumbprint - $($_.Exception.Message)"
        }

        # Controlla Running solo per istanze con thumbprint configurato
        if ($hasThumb -and $inst.State -and $inst.State -ne 'Running') {
            $errors += "$name : stato $($inst.State) (atteso Running)"
        }
    }

    return $errors
}

# ============================================================
# Helper: verify IIS binding post-update
# ============================================================
function Test-IISPostUpdate {
    param(
        [string]$ExpectedThumbprint,
        [string]$SiteName = "Microsoft Dynamics 365 Business Central Web Client"
    )

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $errors = @()

    try {
        if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "Microsoft.Web.Administration" })) {
            $dllPath = "C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll"
            if (Test-Path $dllPath) { [void][Reflection.Assembly]::LoadFrom($dllPath) }
            else { return @("Microsoft.Web.Administration.dll non trovata") }
        }

        $sm = New-Object Microsoft.Web.Administration.ServerManager
        $site = $sm.Sites[$SiteName]
        if (-not $site) { return @("Sito '$SiteName' non trovato in IIS") }

        foreach ($binding in $site.Bindings) {
            if ($binding.Protocol -ne 'https') { continue }
            $bindingInfo = $binding.BindingInformation
            if ($binding.CertificateHash) {
                $currentThumb = ([System.BitConverter]::ToString($binding.CertificateHash) -replace '-', '').ToUpper()
                if ($currentThumb -ne $expectedNorm) {
                    $errors += "Binding $bindingInfo : thumbprint $currentThumb (atteso $expectedNorm)"
                }
            }
            else {
                $errors += "Binding $bindingInfo : nessun certificato associato"
            }
        }
    }
    catch {
        $errors += "Errore verifica IIS: $($_.Exception.Message)"
    }

    return $errors
}

# ============================================================
# Main
# ============================================================
function Main {
    Write-Host ("=" * 60)
    Write-Host ("CERTAMENT - Avvio [{0}] su {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME)
    Write-Host ("Cliente: {0}" -f (Get-CustomerLabel))
    Write-Host ("=" * 60)

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
        Exit-WithCode 1
    }

    # ----------------------------------------------------------
    # Step 2: Get cert details
    # ----------------------------------------------------------
    Write-Host "[2/7] Lettura dettagli certificato..."
    $certDetails = $thumbprint | Get-CertDetails
    if (-not $certDetails) {
        Send-FailureNotification -Context "Dettagli certificato" -ErrorDetail "Certificato $thumbprint non trovato nello store."
        Invoke-Heartbeat -Status "Error" -Stage "ReadCertDetails" -Detail "Certificato attuale non trovato nello store" | Out-Null
        Exit-WithCode 1
    }

    $currentExpiry = $certDetails.NotAfter
    $daysLeft = [math]::Floor(($currentExpiry - (Get-Date)).TotalDays)
    $certAlreadyExpired = $daysLeft -lt 0
    if ($certAlreadyExpired) { $daysLeft = 0 }

    Write-Host "Certificato: $($certDetails.Subject)"
    Write-Host "Thumbprint:  $($certDetails.Thumbprint)"
    if ($certAlreadyExpired) {
        Write-Warning "Scadenza:    $currentExpiry (GIA' SCADUTO)"
    } else {
        Write-Host "Scadenza:    $currentExpiry ($daysLeft giorni rimanenti)"
    }

    # ----------------------------------------------------------
    # Step 3: Check expiry threshold
    # ----------------------------------------------------------
    if ($daysLeft -gt $expiryThreshold) {
        Write-Host "`nCertificato valido. Nessuna azione necessaria."
        Invoke-Heartbeat -Status "Healthy" -Stage "NoActionNeeded" -Detail "Certificato valido ($daysLeft giorni rimanenti)" | Out-Null
        Exit-WithCode 0
    }

    $expiryLabel = if ($certAlreadyExpired) { "GIA' SCADUTO" } else { "in scadenza ($daysLeft giorni)" }
    Write-Host "`n[3/7] Certificato $expiryLabel. Verifica PFX..."

    # ----------------------------------------------------------
    # Step 4: Find PFX
    # ----------------------------------------------------------
    $pfxFile = Get-PfxFile -Path $pfxPath

    # Case 1: No PFX found
    if ([string]::IsNullOrWhiteSpace($pfxFile)) {
        Write-Warning "Nessun file PFX trovato in $pfxPath"
        $null = Send-CustomerNotification -Title "CERTAMENT - Certificato in scadenza" `
            -Message ("Il certificato **$($certDetails.Subject)** e' **$expiryLabel**.`nCaricare un nuovo PFX sul server **$hostname** in: **$pfxPath**") `
            -ContextLabel "Certificato in scadenza - PFX mancante"
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxMissing" -Detail "Nessun PFX trovato in $pfxPath" | Out-Null
        Exit-WithCode 2
    }

    # Case 2: Read PFX
    Write-Host "[4/7] PFX trovato: $pfxFile. Lettura..."

    # --- Resolve PFX password: password.txt > config fallback ---
    $pfxPasswordPlain = $null
    $passwordFile = Join-Path $pfxPath "password.txt"
    if (Test-Path $passwordFile) {
        $pfxPasswordPlain = (Get-Content -Path $passwordFile -Raw -ErrorAction Stop).Trim()
        Write-Host "Password letta da: $passwordFile"
    }
    elseif ($config.Pfx.Password -and $config.Pfx.Password.Trim() -ne "") {
        $pfxPasswordPlain = $config.Pfx.Password
        Write-Host "Password da config.json (fallback)"
    }

    if ([string]::IsNullOrWhiteSpace($pfxPasswordPlain)) {
        Write-Warning "Nessuna password PFX disponibile. Creare password.txt in $pfxPath"
        $null = Send-CustomerNotification -Title "CERTAMENT - Password PFX mancante" `
            -Message ("Il certificato **$($certDetails.Subject)** e' **$expiryLabel**.`nE' stato trovato un PFX ma manca la password.`nCreare il file **password.txt** in **$pfxPath** con la password del PFX.") `
            -ContextLabel "Certificato in scadenza - password PFX mancante"
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxNoPassword" -Detail "Nessuna password PFX disponibile" | Out-Null
        Exit-WithCode 2
    }

    try {
        $pfxPassword = ConvertTo-SecureString $pfxPasswordPlain -AsPlainText -Force
        $pfxData = Get-PfxData -FilePath $pfxFile -Password $pfxPassword
        $pfxExpiry = $pfxData.EndEntityCertificates.NotAfter
        $pfxThumb = $pfxData.EndEntityCertificates.Thumbprint
    }
    catch {
        Write-Warning "Errore lettura PFX: $($_.Exception.Message)"
        $null = Send-CustomerNotification -Title "CERTAMENT - Certificato in scadenza" `
            -Message ("Il certificato **$($certDetails.Subject)** e' **$expiryLabel** ma il PFX non e' leggibile.`nVerificare che la password sia corretta.`nCaricare un nuovo PFX su **$hostname** in: **$pfxPath**") `
            -ContextLabel "Certificato in scadenza - PFX non leggibile"
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxUnreadable" -Detail $_.Exception.Message | Out-Null
        Exit-WithCode 2
    }

    # Case 3a: PFX cert already expired
    if ($pfxExpiry -lt (Get-Date)) {
        Write-Warning "Il PFX contiene un certificato gia' scaduto ($pfxExpiry). Non verra' installato."
        $null = Send-CustomerNotification -Title "CERTAMENT - PFX scaduto" `
            -Message ("Il certificato **$($certDetails.Subject)** e' $expiryLabel.`nIl PFX trovato in **$pfxPath** contiene a sua volta un certificato **gia' scaduto** ($pfxExpiry).`nCaricare un PFX con un certificato valido.") `
            -ContextLabel "Certificato scaduto - PFX scaduto"
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxExpired" -Detail "PFX trovato ma certificato gia' scaduto: $pfxExpiry" | Out-Null
        Exit-WithCode 2
    }

    # Case 3b: PFX not newer
    if ($pfxExpiry -le $currentExpiry -or $pfxThumb -eq $certDetails.Thumbprint) {
        Write-Warning "Il PFX non e' piu recente del certificato attuale."
        $null = Send-CustomerNotification -Title "CERTAMENT - PFX non aggiornato" `
            -Message ("Il certificato **$($certDetails.Subject)** e' $expiryLabel.`nIl PFX presente in **$pfxPath** non contiene un certificato piu recente.`nCaricare un nuovo PFX aggiornato.") `
            -ContextLabel "Certificato scaduto - PFX non aggiornato"
        Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxNotNewer" -Detail "PFX presente ma non piu recente del certificato attuale" | Out-Null
        Exit-WithCode 2
    }

    # ----------------------------------------------------------
    # Case 4: PFX valid and newer - full pipeline
    # ----------------------------------------------------------
    Write-Host "[5/7] Installazione nuovo certificato..."
    $installedCert = Install-PfxCert -PfxPath $pfxFile -Password $pfxPassword
    if (-not $installedCert -or $installedCert -eq $false) {
        Send-FailureNotification -Context "Installazione PFX" -ErrorDetail "Install-PfxCert ha restituito errore per $pfxFile"
        Invoke-Heartbeat -Status "Error" -Stage "InstallPfx" -Detail "Install-PfxCert fallita" | Out-Null
        Exit-WithCode 1
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

    # --- Post-BC verification with auto-remediation ---
    Write-Host "`nVerifica post-aggiornamento BC (attesa avvio servizi)..."
    Start-Sleep -Seconds 15
    $bcVerifyErrors = Test-BCPostUpdate -ExpectedThumbprint $newThumb
    if ($bcVerifyErrors) {
        Write-Warning "Verifica BC fallita: $($bcVerifyErrors -join '; ')"
        Write-Host "Retry aggiornamento BC..."
        $bcRetry = Update-BCServiceCert -NewThumbprint $newThumb
        if ($bcRetry) { $bcRetry | Format-Table -AutoSize }
        Start-Sleep -Seconds 15
        $bcVerifyErrors2 = Test-BCPostUpdate -ExpectedThumbprint $newThumb
        if ($bcVerifyErrors2) {
            $errDetail = $bcVerifyErrors2 -join "; "
            Send-FailureNotification -Context "Verifica post-aggiornamento BC" -ErrorDetail "Fallita anche dopo retry: $errDetail"
            $hadPipelineErrors = $true
        }
        else {
            Write-Host "Remediation BC riuscita dopo retry."
        }
    }
    else {
        Write-Host "Verifica BC OK: thumbprint e stato Running confermati."
    }

    # Update IIS
    Write-Host "`n[7/7] Aggiornamento binding IIS..."
    try {
        $iisResults = Update-IISBinding -NewThumbprint $newThumb -SiteName $iisSiteName -RestartIIS:$iisRestart
        if ($iisResults) { $iisResults | Format-Table -AutoSize }
    }
    catch {
        Send-FailureNotification -Context "Aggiornamento IIS" -ErrorDetail $_.Exception.Message
        $hadPipelineErrors = $true
    }

    # --- Post-IIS verification with auto-remediation ---
    Write-Host "`nVerifica post-aggiornamento IIS..."
    $iisVerifyErrors = Test-IISPostUpdate -ExpectedThumbprint $newThumb -SiteName $iisSiteName
    if ($iisVerifyErrors) {
        Write-Warning "Verifica IIS fallita: $($iisVerifyErrors -join '; ')"
        Write-Host "Retry aggiornamento IIS (con restart forzato)..."
        try {
            $iisRetry = Update-IISBinding -NewThumbprint $newThumb -SiteName $iisSiteName -RestartIIS
            if ($iisRetry) { $iisRetry | Format-Table -AutoSize }
        }
        catch {
            Write-Warning "Retry IIS fallito: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 10
        $iisVerifyErrors2 = Test-IISPostUpdate -ExpectedThumbprint $newThumb -SiteName $iisSiteName
        if ($iisVerifyErrors2) {
            $errDetail = $iisVerifyErrors2 -join "; "
            Send-FailureNotification -Context "Verifica post-aggiornamento IIS" -ErrorDetail "Fallita anche dopo retry con restart: $errDetail"
            $hadPipelineErrors = $true
        }
        else {
            Write-Host "Remediation IIS riuscita dopo retry."
        }
    }
    else {
        Write-Host "Verifica IIS OK: binding aggiornati correttamente."
    }

    # Smoke test with polling + SSL verification (servizi possono metterci fino a 10 min)
    Write-Host "`nAttesa servizi web post-aggiornamento (fino a 10 min)..."
    $wsResults = Wait-ForWebServices -MaxWaitSec 600 -IntervalSec 30 -ExpectedThumbprint $newThumb
    if ($wsResults) { $wsResults | Format-Table -AutoSize }

    $wsErrors = if ($wsResults) { @($wsResults | Where-Object { $_.Status -eq 'ERROR' }) } else { @() }
    if ($wsErrors.Count -gt 0) {
        $wsErrText = ($wsErrors | ForEach-Object { "$($_.Instance) [$($_.Url)]: $($_.Error)" }) -join "; "
        Send-FailureNotification -Context "Verifica servizi web post-aggiornamento" -ErrorDetail $wsErrText
        $hadPipelineErrors = $true
    }

    $sslMismatches = if ($wsResults) { @($wsResults | Where-Object { $_.SslMatch -eq $false }) } else { @() }
    if ($sslMismatches.Count -gt 0) {
        $sslErrText = ($sslMismatches | ForEach-Object { "$($_.Instance) [$($_.Url)]: SSL cert $($_.SslThumbprint) (atteso $newThumb)" }) -join "; "
        Send-FailureNotification -Context "Verifica SSL post-aggiornamento" -ErrorDetail $sslErrText
        $hadPipelineErrors = $true
    }

    # Pipeline completion notification
    $statusLabel = if ($hadPipelineErrors) { "con warning" } else { "con successo" }
    $notifTitle = if ($hadPipelineErrors) { "CERTAMENT - Certificato aggiornato (con warning)" } else { "CERTAMENT - Certificato aggiornato" }
    $msg = @"
Nuovo certificato installato $statusLabel su server **$hostname**.

**Cliente:** $(Get-CustomerLabel)
**Dettagli:**
- Soggetto: $($installedCert.Subject)
- Thumbprint: $newThumb
- Scadenza: $($installedCert.NotAfter)

Servizi BC e IIS aggiornati.
"@
    if ($hadPipelineErrors) {
        $msg += "`n`n**Attenzione:** si sono verificati errori durante la pipeline. Verificare i log."
    }
    $null = Send-InternalNotification -Title $notifTitle -Message $msg

    # --- Post-pipeline cleanup: delete password.txt and archive PFX ---
    if (Test-Path $passwordFile) {
        Remove-Item -Path $passwordFile -Force -ErrorAction SilentlyContinue
        Write-Host "File password.txt eliminato."
    }

    $installedDir = Join-Path $pfxPath "installed"
    if (-not (Test-Path $installedDir)) { New-Item -ItemType Directory -Path $installedDir -Force | Out-Null }
    try {
        Move-Item -Path $pfxFile -Destination $installedDir -Force
        Write-Host "PFX archiviato in: $installedDir"
    }
    catch {
        Write-Warning "Impossibile archiviare PFX: $($_.Exception.Message)"
    }

    if ($hadPipelineErrors) {
        Invoke-Heartbeat -Status "CompletedWithWarnings" -Stage "MainEnd" -Detail "Pipeline completata con warning/errori parziali" | Out-Null
    }
    else {
        Invoke-Heartbeat -Status "Completed" -Stage "MainEnd" -Detail "Pipeline completata con successo" | Out-Null
    }

    if ($hadPipelineErrors) {
        Write-Warning "CERTAMENT completato con warning/errori. Verificare i log."
        Exit-WithCode 1
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
    try { Stop-Transcript | Out-Null } catch {}
}
