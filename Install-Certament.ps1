<#
.SYNOPSIS
    CERTAMENT interactive installer.

.DESCRIPTION
    Launches a step-by-step CLI wizard that collects all required configuration,
    copies files to the install directory, writes config.json, and registers a
    daily Windows Scheduled Task - no manual file editing required.

.EXAMPLE
    .\Install-Certament.ps1
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ============================================================
# Helpers
# ============================================================
function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║           CERTAMENT  -  Installer v1.0              ║" -ForegroundColor Cyan
    Write-Host "  ║    Automated certificate manager for BC + IIS       ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([int]$n, [int]$total, [string]$label)
    Write-Host ""
    Write-Host "  ── Step $n/$total : $label ──" -ForegroundColor Yellow
    Write-Host ""
}

function Write-Ok   { param([string]$msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info { param([string]$msg) Write-Host "  [i]  $msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$msg) Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "  [X]  $msg" -ForegroundColor Red }

function Read-Value {
    param([string]$Prompt, [string]$Default = "", [switch]$AllowEmpty)
    $hint = if ($Default) { " [$Default]" } else { "" }
    $raw = Read-Host "      $Prompt$hint"
    $val = if ($raw.Trim() -eq "" -and $Default) { $Default } else { $raw.Trim() }
    if (-not $AllowEmpty -and $val -eq "") {
        Write-Warn "Valore obbligatorio."
        return Read-Value @PSBoundParameters
    }
    return $val
}

function Read-SecureValue {
    param([string]$Prompt)
    $ss = Read-Host "      $Prompt" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
    if ($plain.Trim() -eq "") {
        Write-Warn "Valore obbligatorio."
        return Read-SecureValue @PSBoundParameters
    }
    return $plain
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { "[S/n]" } else { "[s/N]" }
    $raw = Read-Host "      $Prompt $hint"
    if ($raw.Trim() -eq "") { return $Default }
    return ($raw.Trim() -imatch '^s')
}

function Read-TimeValue {
    param([string]$Prompt, [string]$Default = "06:00")
    $val = Read-Value -Prompt $Prompt -Default $Default
    if ($val -notmatch '^\d{2}:\d{2}$') {
        Write-Warn "Formato non valido. Usare HH:mm (es. 06:00)."
        return Read-TimeValue -Prompt $Prompt -Default $Default
    }
    return $val
}

# ============================================================
# Require Administrator
# ============================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  CERTAMENT Installer richiede privilegi di Amministratore." -ForegroundColor Red
    Write-Host "  Rilancio con elevazione..." -ForegroundColor Yellow
    Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$sourceDir = $PSScriptRoot

# ============================================================
# WIZARD
# ============================================================
Write-Banner

Write-Host "  Benvenuto nel wizard di installazione di CERTAMENT." -ForegroundColor White
Write-Host "  Rispondere alle domande seguenti per configurare lo strumento." -ForegroundColor Gray
Write-Host "  I valori tra parentesi quadre sono i default: premi Invio per accettarli." -ForegroundColor Gray

# ---------- Step 1: Install path ----------
Write-Step 1 6 "Percorso di installazione"
Write-Info "Dove installare CERTAMENT su questo server?"
$installPath = Read-Value -Prompt "Percorso" -Default "C:\CERTAMENT"

# ---------- Step 2: PFX drop folder ----------
Write-Step 2 6 "Cartella PFX"
Write-Info "Percorso della cartella dove verra depositato il file .pfx rinnovato."
Write-Info "CERTAMENT cerchera il .pfx piu recente in questa cartella."
$pfxPath = Read-Value -Prompt "Cartella PFX" -Default "C:\_install"

Write-Info "Password del file PFX (usata per aprirlo)."
$pfxPassword = Read-SecureValue -Prompt "Password PFX"

# ---------- Step 3: IIS ----------
Write-Step 3 6 "Configurazione IIS"
Write-Info "Nome del sito IIS Business Central (esatto, case-sensitive)."
$iisSiteName = Read-Value -Prompt "Nome sito IIS" -Default "Microsoft Dynamics 365 Business Central Web Client"
$iisRestart = Read-YesNo -Prompt "Riavviare IIS dopo aggiornamento del binding?" -Default $true

# ---------- Step 4: Notifications ----------
Write-Step 4 6 "Notifiche Teams (Power Automate webhook)"
Write-Info "Le notifiche vengono inviate tramite webhook a Microsoft Teams."
Write-Info "Lasciare vuoto per disabilitare le notifiche."

$webhookCustomer = Read-Value -Prompt "Webhook Customer (Teams)" -AllowEmpty
$webhookInternal = Read-Value -Prompt "Webhook Internal (Teams)" -AllowEmpty

Write-Info "Quanti giorni prima della scadenza avviare il processo di rinnovo?"
$notifyDays = Read-Value -Prompt "Giorni soglia scadenza" -Default "30"
while ($notifyDays -notmatch '^\d+$') {
    Write-Warn "Inserire un numero intero."
    $notifyDays = Read-Value -Prompt "Giorni soglia scadenza" -Default "30"
}

# ---------- Step 5: Scheduled Task ----------
Write-Step 5 6 "Scheduled Task"
$createTask = Read-YesNo -Prompt "Registrare uno Scheduled Task per l'esecuzione automatica?" -Default $true
$taskTime = "06:00"
if ($createTask) {
    Write-Info "A che ora eseguire CERTAMENT ogni giorno?"
    $taskTime = Read-TimeValue -Prompt "Orario esecuzione (HH:mm)" -Default "06:00"
}

# ---------- Step 6: Confirm ----------
Write-Step 6 6 "Riepilogo"

Write-Host "  ┌─────────────────────────────────────────────────────┐" -ForegroundColor White
Write-Host ("  │  Percorso installazione : {0}" -f $installPath.PadRight(27)) -ForegroundColor White
Write-Host ("  │  Cartella PFX           : {0}" -f $pfxPath.PadRight(27)) -ForegroundColor White
Write-Host ("  │  Sito IIS               : {0}" -f ($iisSiteName.Substring(0, [Math]::Min(27, $iisSiteName.Length))).PadRight(27)) -ForegroundColor White
Write-Host ("  │  Riavvio IIS            : {0}" -f ($(if ($iisRestart) {"Si"} else {"No"}).PadRight(27))) -ForegroundColor White
Write-Host ("  │  Webhook Customer       : {0}" -f ($(if ($webhookCustomer) {"Configurato"} else {"Disabilitato"}).PadRight(27))) -ForegroundColor White
Write-Host ("  │  Webhook Internal       : {0}" -f ($(if ($webhookInternal) {"Configurato"} else {"Disabilitato"}).PadRight(27))) -ForegroundColor White
Write-Host ("  │  Soglia scadenza        : {0} giorni" -f $notifyDays.PadRight(21)) -ForegroundColor White
Write-Host ("  │  Scheduled Task         : {0}" -f ($(if ($createTask) {"Si, alle $taskTime"} else {"No"}).PadRight(27))) -ForegroundColor White
Write-Host "  └─────────────────────────────────────────────────────┘" -ForegroundColor White
Write-Host ""

$confirm = Read-YesNo -Prompt "Procedere con l'installazione?" -Default $true
if (-not $confirm) {
    Write-Host ""
    Write-Warn "Installazione annullata."
    exit 0
}

# ============================================================
# INSTALLATION
# ============================================================
Write-Host ""
Write-Host "  Installazione in corso..." -ForegroundColor Cyan
Write-Host ""

# --- Copy files ---
if (-not (Test-Path $installPath)) {
    New-Item -ItemType Directory -Path $installPath -Force | Out-Null
}
foreach ($subDir in @('modules','tools','logs')) {
    $d = Join-Path $installPath $subDir
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

foreach ($file in @('_MAINCertManager.ps1', 'config.example.json')) {
    $src = Join-Path $sourceDir $file
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $installPath -Force
        Write-Ok "Copiato: $file"
    }
}
foreach ($folder in @('modules','tools')) {
    $src = Join-Path $sourceDir $folder
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination (Join-Path $installPath $folder) -Recurse -Force
        Write-Ok "Copiato: $folder\"
    }
}

# --- Write config.json ---
$configPath = Join-Path $installPath "config.json"
$enableWebhook = ($webhookCustomer -ne "" -or $webhookInternal -ne "")

$configObj = [ordered]@{
    Pfx = [ordered]@{
        Path             = $pfxPath
        Password         = $pfxPassword
        AutoSelectLatest = $true
    }
    BusinessCentral = [ordered]@{
        UseLatestModule = $true
    }
    IIS = [ordered]@{
        SiteName           = $iisSiteName
        RestartAfterUpdate = $iisRestart
    }
    Logging = [ordered]@{
        Enabled       = $true
        Path          = "logs"
        RetentionDays = 90
    }
    Notifications = [ordered]@{
        EnableWebhook = $enableWebhook
        Webhooks      = [ordered]@{
            Customer = $webhookCustomer
            Internal = $webhookInternal
        }
        CertificateExpiry = [ordered]@{
            NotifyBeforeDays          = [int]$notifyDays
            EnableCustomerNotification = $true
        }
    }
}

$configObj | ConvertTo-Json -Depth 6 | Set-Content -Path $configPath -Encoding UTF8
Write-Ok "config.json scritto: $configPath"

# --- Scheduled Task ---
if ($createTask) {
    $taskName  = "CERTAMENT"
    $scriptPath = Join-Path $installPath "_MAINCertManager.ps1"

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
        -WorkingDirectory $installPath

    $trigger   = New-ScheduledTaskTrigger -Daily -At $taskTime
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable -DontStopOnIdleEnd `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Info "Task precedente rimosso."
    }

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description "CERTAMENT - Gestione automatica certificati Business Central" | Out-Null

    Write-Ok "Scheduled Task '$taskName' registrato (ogni giorno alle $taskTime)."
}

# ============================================================
# DONE
# ============================================================
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║          Installazione completata!                  ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Info "Percorso: $installPath"
Write-Info "Per eseguire manualmente:"
Write-Host "      powershell -File `"$(Join-Path $installPath '_MAINCertManager.ps1')`"" -ForegroundColor White
Write-Host ""
Write-Info "Ricordarsi di copiare il file .pfx in: $pfxPath"
Write-Host ""
