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

param(
    [switch]$WaitAtEnd
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ============================================================
# Helpers
# ============================================================
function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +======================================================+" -ForegroundColor Cyan
    Write-Host "  |           CERTAMENT  -  Installer v1.0              |" -ForegroundColor Cyan
    Write-Host "  |    Automated certificate manager for BC + IIS       |" -ForegroundColor Cyan
    Write-Host "  +======================================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([int]$n, [int]$total, [string]$label)
    Write-Host ""
    Write-Host "  --- Step $n/$total : $label ---" -ForegroundColor Yellow
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
    Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", '-WaitAtEnd') -Verb RunAs
    exit
}

$sourceDir = $PSScriptRoot

# ============================================================
# Diagnostic helper
# ============================================================
$script:dPass = 0; $script:dWarn = 0; $script:dFail = 0

function Write-DiagCheck {
    param([bool]$Result, [string]$Label, [string]$Detail = "", [switch]$AsWarn)
    $msg = if ($Detail) { "$Label - $Detail" } else { $Label }
    if ($Result) {
        Write-Ok  $msg; $script:dPass++
    } elseif ($AsWarn) {
        Write-Warn $msg; $script:dWarn++
    } else {
        Write-Err  $msg; $script:dFail++
    }
}

function Get-CertamentTaskInstallPath {
    try {
        $task = Get-ScheduledTask -TaskName "CERTAMENT" -ErrorAction SilentlyContinue
        if (-not $task) { return $null }

        $act = $task.Actions | Select-Object -First 1
        if (-not $act) { return $null }

        $argText = [string]$act.Arguments
        $m = [regex]::Match($argText, '-File\s+"([^"]+)"')
        if (-not $m.Success) { return $null }

        $scriptPath = $m.Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($scriptPath)) { return $null }

        $installDir = Split-Path -Path $scriptPath -Parent
        if ([string]::IsNullOrWhiteSpace($installDir)) { return $null }

        if (Test-Path (Join-Path $installDir "config.json")) {
            return $installDir
        }
    }
    catch { }

    return $null
}

# ============================================================
# DIAGNOSTICS
# ============================================================
function Invoke-Diagnostics {
    $script:dPass = 0; $script:dWarn = 0; $script:dFail = 0

    Write-Banner
    Write-Host "  Verifica installazione CERTAMENT" -ForegroundColor Yellow
    Write-Host ""

    $taskInstallPath = Get-CertamentTaskInstallPath
    $defaultPath = if ($taskInstallPath) {
        $taskInstallPath
    }
    elseif (Test-Path (Join-Path $PSScriptRoot "config.json")) {
        $PSScriptRoot
    }
    else {
        "C:\CERTAMENT"
    }
    $checkPath   = Read-Value -Prompt "Percorso installazione da verificare" -Default $defaultPath
    $webhookTable = @{}
    $heartbeatEnabled = $false
    $heartbeatUrl = ""
    $heartbeatTimeoutSec = 10

    if ($taskInstallPath) {
        Write-Info "Installazione attiva rilevata dal task: $taskInstallPath"
    }

    # ---- 1. File system ----
    Write-Host ""
    Write-Host "  [File di installazione]" -ForegroundColor Yellow
    $requiredFiles = @(
        "_MAINCertManager.ps1",
        "Install-Certament.ps1",
        "config.json",
        "modules\Get-CertDetails.psm1",
        "modules\Get-PfxFile.psm1",
        "modules\Get-BCThumbprint.psm1",
        "modules\Install-PfxCert.psm1",
        "modules\Update-BCServiceCert.psm1",
        "modules\Update-IISBinding.psm1",
        "modules\Send-Notification.psm1",
        "modules\Test-BCWebServices.psm1"
    )
    foreach ($f in $requiredFiles) {
        Write-DiagCheck -Result (Test-Path (Join-Path $checkPath $f)) -Label $f
    }

    # ---- 2. Config JSON ----
    Write-Host ""
    Write-Host "  [Configurazione]" -ForegroundColor Yellow
    $cfgPath = Join-Path $checkPath "config.json"
    $cfg = $null
    if (Test-Path $cfgPath) {
        try {
            $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
            Write-DiagCheck -Result $true -Label "config.json e JSON valido"
            Write-DiagCheck -Result ($cfg.Pfx.Path     -and $cfg.Pfx.Path.Trim()     -ne "") -Label "config.json: Pfx.Path configurato"
            $hasConfigPwd = ($cfg.Pfx.Password -and $cfg.Pfx.Password.Trim() -ne "")
            $hasPwdTxt = $false
            if ($cfg.Pfx.Path -and (Test-Path $cfg.Pfx.Path)) {
                $hasPwdTxt = Test-Path (Join-Path $cfg.Pfx.Path "password.txt")
            }
            if ($hasPwdTxt) {
                Write-DiagCheck -Result $true -Label "password.txt presente in $($cfg.Pfx.Path)"
            } elseif ($hasConfigPwd) {
                Write-DiagCheck -Result $true -Label "Pfx.Password fallback nel config"
            } else {
                Write-DiagCheck -AsWarn -Result $false -Label "Password PFX" -Detail "Nessun password.txt e nessun fallback nel config"
            }
            $customerNameConfigured = ($cfg.Context -and $cfg.Context.CustomerName -and $cfg.Context.CustomerName.Trim() -ne "")
            Write-DiagCheck -AsWarn -Result $customerNameConfigured -Label "config.json: Context.CustomerName configurato"
            $iisSiteConfigured = ($cfg.IIS -and $cfg.IIS.SiteName -and $cfg.IIS.SiteName.Trim() -ne "")
            Write-DiagCheck -AsWarn -Result $iisSiteConfigured -Label "config.json: IIS.SiteName configurato"

            if ($cfg.Notifications -and $cfg.Notifications.Webhooks) {
                if ($cfg.Notifications.Webhooks.Internal -and $cfg.Notifications.Webhooks.Internal.Trim() -ne "") {
                    $webhookTable['Internal'] = [string]$cfg.Notifications.Webhooks.Internal
                }
                if ($cfg.Notifications.Webhooks.Customer -and $cfg.Notifications.Webhooks.Customer.Trim() -ne "") {
                    $webhookTable['Customer'] = [string]$cfg.Notifications.Webhooks.Customer
                }
            }
            Write-DiagCheck -AsWarn -Result $webhookTable.ContainsKey('Internal') -Label "config.json: webhook Internal configurato"
            Write-DiagCheck -AsWarn -Result $webhookTable.ContainsKey('Customer') -Label "config.json: webhook Customer configurato"
            if ($webhookTable.ContainsKey('Internal') -and $webhookTable.ContainsKey('Customer')) {
                $sameWebhook = ([string]$webhookTable['Internal'] -eq [string]$webhookTable['Customer'])
                Write-DiagCheck -AsWarn -Result (-not $sameWebhook) -Label "Webhook Customer/Internal separati"
            }

            if ($cfg.Heartbeat) {
                $heartbeatEnabled = ($cfg.Heartbeat.Enabled -eq $true)
                if ($cfg.Heartbeat.Url) {
                    $heartbeatUrl = [string]$cfg.Heartbeat.Url
                }
                if ($cfg.Heartbeat.TimeoutSec) {
                    try {
                        $parsedHbTimeout = [int]$cfg.Heartbeat.TimeoutSec
                        if ($parsedHbTimeout -gt 0) { $heartbeatTimeoutSec = $parsedHbTimeout }
                    }
                    catch { }
                }
            }
            Write-DiagCheck -AsWarn -Result $heartbeatEnabled -Label "config.json: Heartbeat.Enabled"
            if ($heartbeatEnabled) {
                Write-DiagCheck -Result (-not [string]::IsNullOrWhiteSpace($heartbeatUrl)) -Label "config.json: Heartbeat.Url configurato"
            }

            if ($cfg.Pfx.Path) {
                Write-DiagCheck -AsWarn -Result (Test-Path $cfg.Pfx.Path) -Label "Cartella PFX esiste ($($cfg.Pfx.Path))"
                if (Test-Path $cfg.Pfx.Path) {
                    $pfxFiles = @(Get-ChildItem $cfg.Pfx.Path -Filter *.pfx -File -ErrorAction SilentlyContinue)
                    Write-DiagCheck -AsWarn -Result ($pfxFiles.Count -gt 0) -Label "$($pfxFiles.Count) file .pfx trovati in $($cfg.Pfx.Path)"
                    if ($pfxFiles.Count -gt 0) {
                        Write-Info "  PFX piu recente: $(($pfxFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1).Name)"
                    }
                }
            }
        } catch {
            Write-DiagCheck -Result $false -Label "config.json parse" -Detail $_.Exception.Message
        }
    } else {
        Write-DiagCheck -Result $false -Label "config.json presente"
    }

    # ---- 3. Modules ----
    Write-Host ""
    Write-Host "  [Moduli PowerShell]" -ForegroundColor Yellow
    $moduleDir = Join-Path $checkPath "modules"
    $moduleMap = [ordered]@{
        "Get-CertDetails.psm1"      = "Get-CertDetails"
        "Get-PfxFile.psm1"          = "Get-PfxFile"
        "Get-BCThumbprint.psm1"     = "Get-BCThumbprint"
        "Install-PfxCert.psm1"      = "Install-PfxCert"
        "Update-BCServiceCert.psm1" = "Update-BCServiceCert"
        "Update-IISBinding.psm1"    = "Update-IISBinding"
        "Send-Notification.psm1"    = "Send-Notification"
        "Test-BCWebServices.psm1"   = "Test-BCWebServices"
    }
    foreach ($modFile in $moduleMap.Keys) {
        $modPath = Join-Path $moduleDir $modFile
        if (Test-Path $modPath) {
            try {
                Import-Module $modPath -Force -ErrorAction Stop
                $fn = Get-Command $moduleMap[$modFile] -ErrorAction SilentlyContinue
                Write-DiagCheck -Result ($null -ne $fn) -Label "$modFile -> $($moduleMap[$modFile])()"
            } catch {
                Write-DiagCheck -Result $false -Label "$modFile" -Detail $_.Exception.Message
            }
        } else {
            Write-DiagCheck -Result $false -Label "$modFile (file mancante)"
        }
    }

    # ---- 4. Notifications test ----
    Write-Host ""
    Write-Host "  [Notifiche]" -ForegroundColor Yellow
    $notifCmd = Get-Command Send-Notification -ErrorAction SilentlyContinue
    Write-DiagCheck -AsWarn -Result ($null -ne $notifCmd) -Label "Funzione Send-Notification disponibile"

    if ($notifCmd -and $webhookTable.ContainsKey('Internal')) {
        $testTitle = "CERTAMENT - Test notifica Internal"
        $testMsg = "Test invio notifica da diagnostica CERTAMENT su $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
        $sentInternal = Send-Notification -Title $testTitle -Message $testMsg -Target "Internal" -Webhooks $webhookTable
        Write-DiagCheck -AsWarn -Result ([bool]$sentInternal) -Label "Invio notifica test Internal"
    }

    if ($notifCmd -and $webhookTable.ContainsKey('Customer')) {
        $testCustomer = Read-YesNo -Prompt "Inviare test notifica anche al webhook Customer?" -Default $false
        if ($testCustomer) {
            $testTitle = "CERTAMENT - Test notifica Customer"
            $testMsg = "Test invio notifica da diagnostica CERTAMENT su $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
            $sentCustomer = Send-Notification -Title $testTitle -Message $testMsg -Target "Customer" -Webhooks $webhookTable
            Write-DiagCheck -AsWarn -Result ([bool]$sentCustomer) -Label "Invio notifica test Customer"
        }
        else {
            Write-Info "  Test webhook Customer saltato."
        }
    }

    # ---- 5. Heartbeat test ----
    Write-Host ""
    Write-Host "  [Heartbeat Azure]" -ForegroundColor Yellow
    if ($heartbeatEnabled -and -not [string]::IsNullOrWhiteSpace($heartbeatUrl)) {
        $hbPayload = @{
            tool      = "CERTAMENT"
            customer  = if ($cfg.Context -and $cfg.Context.CustomerName) { [string]$cfg.Context.CustomerName } else { "" }
            server    = $env:COMPUTERNAME
            status    = "Diagnostics"
            stage     = "Install-Certament"
            detail    = "Heartbeat test da diagnostica"
            timestamp = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 6

        try {
            Invoke-RestMethod -Method POST -Uri $heartbeatUrl -ContentType "application/json; charset=utf-8" `
                -Body $hbPayload -TimeoutSec $heartbeatTimeoutSec -ErrorAction Stop | Out-Null
            Write-DiagCheck -Result $true -Label "Heartbeat Azure inviato"
        }
        catch {
            $hbErr = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
            Write-DiagCheck -Result $false -Label "Heartbeat Azure inviato" -Detail $hbErr

            if ($notifCmd -and $webhookTable.ContainsKey('Internal')) {
                $alertTitle = "CERTAMENT - Errore heartbeat"
                $alertMsg = "Heartbeat Azure fallito durante diagnostica su $env:COMPUTERNAME.`nErrore: $hbErr"
                $alertSent = Send-Notification -Title $alertTitle -Message $alertMsg -Target "Internal" -Webhooks $webhookTable
                Write-DiagCheck -AsWarn -Result ([bool]$alertSent) -Label "Alert interno su errore heartbeat"
            }
        }
    }
    else {
        Write-DiagCheck -AsWarn -Result $false -Label "Heartbeat Azure abilitato e configurato"
    }

    # ---- 6. Scheduled Task ----
    Write-Host ""
    Write-Host "  [Scheduled Task]" -ForegroundColor Yellow
    $task = Get-ScheduledTask -TaskName "CERTAMENT" -ErrorAction SilentlyContinue
    Write-DiagCheck -Result ($null -ne $task) -Label "Task 'CERTAMENT' registrato"
    if ($task) {
        Write-DiagCheck -Result ($task.State -in @('Ready', 'Running')) -Label "Task stato: $($task.State)"
        $taskInfo = Get-ScheduledTaskInfo -TaskName "CERTAMENT" -ErrorAction SilentlyContinue
        if ($taskInfo -and $taskInfo.NextRunTime) {
            Write-Info "  Prossima esecuzione: $($taskInfo.NextRunTime.ToString('yyyy-MM-dd HH:mm'))"
        }
        $act = $task.Actions | Select-Object -First 1
        Write-Info "  Comando: $($act.Execute) $($act.Arguments)"

        try {
            $taskScriptPath = $null
            $argText = [string]$act.Arguments
            $m = [regex]::Match($argText, '-File\s+"([^"]+)"')
            if ($m.Success) {
                $taskScriptPath = $m.Groups[1].Value
            }

            if (-not [string]::IsNullOrWhiteSpace($taskScriptPath)) {
                $expectedScript = Join-Path $checkPath "_MAINCertManager.ps1"
                $taskScriptNorm = [System.IO.Path]::GetFullPath($taskScriptPath)
                $expectedNorm = [System.IO.Path]::GetFullPath($expectedScript)
                $sameTarget = ($taskScriptNorm -ieq $expectedNorm)
                Write-DiagCheck -AsWarn -Result $sameTarget -Label "Task punta al path verificato"
                if (-not $sameTarget) {
                    Write-Info "  Task script: $taskScriptNorm"
                    Write-Info "  Path verificato: $expectedNorm"
                }
            }
        }
        catch { }
    }

    # ---- 7. IIS ----
    if ($cfg) {
        Write-Host ""
        Write-Host "  [IIS]" -ForegroundColor Yellow
        $siteName = if ($cfg.IIS -and $cfg.IIS.SiteName -and $cfg.IIS.SiteName.Trim() -ne "") {
            [string]$cfg.IIS.SiteName
        }
        else {
            "Microsoft Dynamics 365 Business Central Web Client"
        }
        if (-not ($cfg.IIS -and $cfg.IIS.SiteName -and $cfg.IIS.SiteName.Trim() -ne "")) {
            Write-Info "  IIS.SiteName non configurato: uso default '$siteName'"
        }
        $siteFound = $false
        $siteObj   = $null
        try {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $siteObj = Get-Website -Name $siteName -ErrorAction SilentlyContinue
            if ($siteObj) { $siteFound = $true }
        } catch { }
        if (-not $siteFound) {
            try {
                $dll = "C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll"
                if (Test-Path $dll) {
                    [void][Reflection.Assembly]::LoadFrom($dll)
                    $sm = New-Object Microsoft.Web.Administration.ServerManager
                    $siteObj = $sm.Sites[$siteName]
                    if ($siteObj) { $siteFound = $true }
                }
            } catch { }
        }
        Write-DiagCheck -Result $siteFound -Label "Sito IIS trovato: '$siteName'"
        if ($siteFound -and $siteObj) {
            $httpsCount = 0
            try {
                $bindColl = if ($siteObj.PSObject.Properties.Name -contains 'bindings') { $siteObj.bindings.Collection } else { $siteObj.Bindings }
                foreach ($b in $bindColl) {
                    $proto = if ($b.PSObject.Properties.Name -contains 'protocol') { $b.protocol } else { $b.Protocol }
                    $info  = if ($b.PSObject.Properties.Name -contains 'bindingInformation') { $b.bindingInformation } else { $b.BindingInformation }
                    if ($proto -eq 'https') { $httpsCount++; Write-Info "  Binding HTTPS: $info" }
                }
            } catch { }
            if ($httpsCount -eq 0) { Write-Warn "  Nessun binding HTTPS trovato per il sito." }
        }
    }

    # ---- 8. Business Central ----
    Write-Host ""
    Write-Host "  [Business Central]" -ForegroundColor Yellow
    $bcMods = @(Get-ChildItem "C:\Program Files\Microsoft Dynamics 365 Business Central" `
        -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" -ErrorAction SilentlyContinue)
    Write-DiagCheck -AsWarn -Result ($bcMods.Count -gt 0) -Label "Modulo BC trovato su disco ($($bcMods.Count) versioni)"
    if ($bcMods.Count -gt 0) {
        $orderedBcMods = $bcMods | Sort-Object `
            @{ Expression = { if ($_.FullName -match '\\Admin\\') { 1 } else { 0 } } }, `
            @{ Expression = 'LastWriteTime'; Descending = $true }

        $selectedBcPath = $null
        try {
            $bcCommand = Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue

            if ($bcCommand) {
                $selectedBcPath = $bcCommand.Source
            }
            else {
                foreach ($bcCandidate in $orderedBcMods) {
                    try {
                        Remove-Module -Name Microsoft.Dynamics.Nav.Management -ErrorAction SilentlyContinue
                        Import-Module $bcCandidate.FullName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

                        $bcCommand = Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue
                        if ($bcCommand) {
                            $selectedBcPath = $bcCandidate.FullName
                            break
                        }
                    }
                    catch { }
                }
            }

            if (-not $selectedBcPath) {
                Write-DiagCheck -AsWarn -Result $false -Label "Import modulo BC funzionante" -Detail "Get-NAVServerInstance non disponibile"
            }

            if ($selectedBcPath) {
                Write-Info "  Modulo BC: $selectedBcPath"

                $instances = @(Get-NAVServerInstance -ErrorAction Stop)
                Write-DiagCheck -AsWarn -Result ($instances.Count -gt 0) -Label "Istanze BC trovate: $($instances.Count)"
                foreach ($inst in $instances) {
                    $iName  = $inst.ServerInstance
                    $iState = $inst.State
                    $thumb  = $null
                    try { $thumb = Get-NAVServerConfiguration -ServerInstance $iName -KeyName "ServicesCertificateThumbprint" -ErrorAction SilentlyContinue } catch { }
                    if ($thumb -and $thumb.Trim() -ne "") {
                        $thumbNorm = ($thumb -replace '\s', '').ToUpper()
                        $certObj   = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                                        Where-Object { ($_.Thumbprint -replace '\s', '').ToUpper() -eq $thumbNorm }
                        if ($certObj) {
                            $daysLeft   = (New-TimeSpan -Start (Get-Date) -End $certObj.NotAfter).Days
                            $thumbShort = $thumbNorm.Substring(0, [Math]::Min(12, $thumbNorm.Length))
                            Write-Info "  $iName [$iState] thumb: ${thumbShort}...  scade: $($certObj.NotAfter.ToString('yyyy-MM-dd')) ($daysLeft gg)"
                            Write-DiagCheck -Result ($daysLeft -gt 0) -Label "Certificato non scaduto: $iName"
                            if ($cfg.Notifications.CertificateExpiry.NotifyBeforeDays) {
                                $threshold = [int]$cfg.Notifications.CertificateExpiry.NotifyBeforeDays
                                Write-DiagCheck -AsWarn -Result ($daysLeft -gt $threshold) `
                                    -Label "Certificato sopra soglia rinnovo ($daysLeft gg rimasti, soglia: $threshold gg) - $iName"
                            }
                        } else {
                            $thumbShort = $thumbNorm.Substring(0, [Math]::Min(12, $thumbNorm.Length))
                            Write-DiagCheck -Result $false -Label "Certificato nello store per $iName" `
                                -Detail "Thumb ${thumbShort}... non trovato in LocalMachine\My"
                        }
                    } else {
                        Write-Info "  $iName [$iState] nessun thumbprint configurato"
                    }
                }
            }
        } catch {
            Write-DiagCheck -AsWarn -Result $false -Label "Accesso istanze BC" -Detail $_.Exception.Message
        }
    }

    # ---- Summary ----
    Write-Host ""
    $sumColor = if ($script:dFail -gt 0) { "Red" } elseif ($script:dWarn -gt 0) { "Yellow" } else { "Green" }
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor $sumColor
    Write-Host ("  |  PASS: {0,-5}  WARN: {1,-5}  FAIL: {2,-5}              |" -f $script:dPass, $script:dWarn, $script:dFail) -ForegroundColor $sumColor
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor $sumColor
    Write-Host ""
}

# ============================================================
# INSTALL WIZARD
# ============================================================
function Invoke-Install {
    Write-Banner
    Write-Host "  Benvenuto nel wizard di installazione di CERTAMENT." -ForegroundColor White
    Write-Host "  Rispondere alle domande seguenti per configurare lo strumento." -ForegroundColor Gray
    Write-Host "  I valori tra parentesi quadre sono i default: premi Invio per accettarli." -ForegroundColor Gray

    # ---------- Step 1: Install path ----------
    Write-Step 1 6 "Percorso di installazione"
    Write-Info "Dove installare CERTAMENT su questo server?"
    $installPath = Read-Value -Prompt "Percorso" -Default "C:\CERTAMENT"
    Write-Info "Nome cliente (tag usato in notifiche e heartbeat)."
    $customerName = Read-Value -Prompt "Nome cliente" -Default $env:COMPUTERNAME

    # ---------- Step 2: PFX drop folder ----------
    Write-Step 2 6 "Cartella PFX"
    Write-Info "Percorso della cartella dove verra depositato il file .pfx rinnovato."
    Write-Info "CERTAMENT cerchera il .pfx piu recente in questa cartella."
    $pfxPath = Read-Value -Prompt "Cartella PFX" -Default "C:\_install"

    Write-Info "Password PFX: il cliente puo creare un file 'password.txt' nella cartella PFX."
    Write-Info "CERTAMENT lo leggera e lo eliminera dopo l'uso."
    Write-Info "In alternativa, inserire una password di fallback qui (oppure lasciare vuoto)."
    $pfxPassword = Read-Value -Prompt "Password PFX fallback (opzionale)" -Default "" -AllowEmpty

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

    Write-Info "Heartbeat Azure per monitoraggio del tool (consigliato)."
    $heartbeatEnabled = Read-YesNo -Prompt "Abilitare heartbeat Azure?" -Default $true
    $heartbeatUrl = ""
    $heartbeatTimeoutSec = 10
    if ($heartbeatEnabled) {
        $heartbeatUrl = Read-Value -Prompt "URL endpoint heartbeat Azure" -AllowEmpty
        if ([string]::IsNullOrWhiteSpace($heartbeatUrl)) {
            Write-Warn "URL heartbeat non specificato: heartbeat disabilitato."
            $heartbeatEnabled = $false
        }
        else {
            $timeoutRaw = Read-Value -Prompt "Timeout heartbeat (secondi)" -Default "10"
            while ($timeoutRaw -notmatch '^\d+$' -or [int]$timeoutRaw -le 0) {
                Write-Warn "Inserire un numero intero positivo."
                $timeoutRaw = Read-Value -Prompt "Timeout heartbeat (secondi)" -Default "10"
            }
            $heartbeatTimeoutSec = [int]$timeoutRaw
        }
    }

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

    Write-Host "  +-----------------------------------------------------+" -ForegroundColor White
    Write-Host ("  |  Percorso installazione : {0}" -f $installPath.PadRight(27)) -ForegroundColor White
    Write-Host ("  |  Nome cliente           : {0}" -f ($customerName.Substring(0, [Math]::Min(27, $customerName.Length))).PadRight(27)) -ForegroundColor White
    Write-Host ("  |  Cartella PFX           : {0}" -f $pfxPath.PadRight(27)) -ForegroundColor White
    Write-Host ("  |  Password PFX           : {0}" -f ($(if ($pfxPassword) {"Fallback nel config"} else {"Solo password.txt"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  |  Sito IIS               : {0}" -f ($iisSiteName.Substring(0, [Math]::Min(27, $iisSiteName.Length))).PadRight(27)) -ForegroundColor White
    Write-Host ("  |  Riavvio IIS            : {0}" -f ($(if ($iisRestart) {"Si"} else {"No"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  |  Webhook Customer       : {0}" -f ($(if ($webhookCustomer) {"Configurato"} else {"Disabilitato"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  |  Webhook Internal       : {0}" -f ($(if ($webhookInternal) {"Configurato"} else {"Disabilitato"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  |  Heartbeat Azure        : {0}" -f ($(if ($heartbeatEnabled) {"Si ($heartbeatTimeoutSec sec)"} else {"No"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  |  Soglia scadenza        : {0} giorni" -f $notifyDays.PadRight(21)) -ForegroundColor White
    Write-Host ("  |  Scheduled Task         : {0}" -f ($(if ($createTask) {"Si, alle $taskTime"} else {"No"}).PadRight(27))) -ForegroundColor White
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor White
    Write-Host ""

    $confirm = Read-YesNo -Prompt "Procedere con l'installazione?" -Default $true
    if (-not $confirm) {
        Write-Host ""
        Write-Warn "Installazione annullata."
        return
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

    foreach ($file in @('_MAINCertManager.ps1', 'config.example.json', 'Install-Certament.ps1')) {
        $src = Join-Path $sourceDir $file
        if (Test-Path $src) {
            Copy-Item -Path $src -Destination $installPath -Force
            Write-Ok "Copiato: $file"
        }
    }
    foreach ($folder in @('modules','tools')) {
        $src = Join-Path $sourceDir $folder
        $dst = Join-Path $installPath $folder
        if (Test-Path $src) {
            $nestedDst = Join-Path $dst $folder
            if (Test-Path $nestedDst) {
                Remove-Item -Path $nestedDst -Recurse -Force -ErrorAction SilentlyContinue
            }

            Get-ChildItem -Path $src -Force | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $dst -Recurse -Force
            }
            Write-Ok "Copiato: $folder\"
        }
    }

    # --- Write config.json ---
    $configPath = Join-Path $installPath "config.json"
    $enableWebhook = ($webhookCustomer -ne "" -or $webhookInternal -ne "")

    $configObj = [ordered]@{
        Context = [ordered]@{
            CustomerName = $customerName
        }
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
                NotifyBeforeDays           = [int]$notifyDays
                EnableCustomerNotification = $true
            }
        }
        Heartbeat = [ordered]@{
            Enabled                 = $heartbeatEnabled
            Url                     = $heartbeatUrl
            TimeoutSec              = [int]$heartbeatTimeoutSec
            NotifyInternalOnFailure = $true
        }
    }

    $configObj | ConvertTo-Json -Depth 6 | Set-Content -Path $configPath -Encoding UTF8
    Write-Ok "config.json scritto: $configPath"

    # --- Scheduled Task ---
    if ($createTask) {
        $taskName   = "CERTAMENT"
        $scriptPath = Join-Path $installPath "_MAINCertManager.ps1"
        $psExe      = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        $taskFile   = Join-Path $env:WINDIR "System32\Tasks\$taskName"

        # ---- Phase 1: Nuke any zombie task/folder from previous broken attempts ----
        try {
            $scheduler = New-Object -ComObject Schedule.Service
            $scheduler.Connect()
            $rootFolder = $scheduler.GetFolder("\")
            try { $rootFolder.DeleteTask($taskName, 0) } catch { }
            try { $rootFolder.DeleteFolder($taskName, 0) } catch { }
        }
        catch { }
        finally {
            if ($scheduler) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler) | Out-Null; $scheduler = $null }
        }

        if (Test-Path $taskFile) {
            Write-Info "Pulizia artefatti task corrotti..."
            try {
                Stop-Service -Name Schedule -Force -ErrorAction Stop
                Start-Sleep -Seconds 2
                Remove-Item -Path $taskFile -Recurse -Force -ErrorAction Stop
                Write-Info "Artefatti rimossi."
            }
            catch { Write-Warn "Pulizia file task fallita: $_" }
            finally {
                Start-Service -Name Schedule -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }

        # ---- Phase 2: Register via COM ----
        $taskCreated = $false
        try {
            $scheduler = New-Object -ComObject Schedule.Service
            $scheduler.Connect()
            $rootFolder = $scheduler.GetFolder("\")

            $taskDef = $scheduler.NewTask(0)
            $taskDef.RegistrationInfo.Description = "CERTAMENT - Gestione automatica certificati Business Central"
            $taskDef.Settings.Enabled                    = $true
            $taskDef.Settings.StartWhenAvailable         = $true
            $taskDef.Settings.StopIfGoingOnBatteries     = $false
            $taskDef.Settings.DisallowStartIfOnBatteries = $false
            $taskDef.Settings.ExecutionTimeLimit          = "PT30M"

            $execAction = $taskDef.Actions.Create(0)
            $execAction.Path             = $psExe
            $execAction.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
            $execAction.WorkingDirectory = $installPath

            $dailyTrigger = $taskDef.Triggers.Create(2)
            $triggerDate   = [DateTime]::Today.Add([TimeSpan]::Parse($taskTime))
            $dailyTrigger.StartBoundary = $triggerDate.ToString("yyyy-MM-ddTHH:mm:ss")
            $dailyTrigger.DaysInterval  = 1
            $dailyTrigger.Enabled       = $true

            $rootFolder.RegisterTaskDefinition($taskName, $taskDef, 6, "SYSTEM", $null, 5) | Out-Null
            $taskCreated = $true
        }
        catch { Write-Warn "COM RegisterTaskDefinition fallito: $_" }
        finally {
            if ($scheduler) { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler) | Out-Null; $scheduler = $null }
        }

        # ---- Phase 3: Fallback with cmdlet if COM failed ----
        if (-not $taskCreated) {
            Write-Info "Tentativo con Register-ScheduledTask..."
            try {
                $action    = New-ScheduledTaskAction -Execute $psExe `
                                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
                                -WorkingDirectory $installPath
                $trigger   = New-ScheduledTaskTrigger -Daily -At $taskTime
                $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
                $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
                                -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                                -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

                Register-ScheduledTask -TaskName $taskName `
                    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                    -Description "CERTAMENT - Gestione automatica certificati Business Central" `
                    -ErrorAction Stop | Out-Null
                $taskCreated = $true
            }
            catch { Write-Warn "Register-ScheduledTask fallito: $_" }
        }

        # ---- Phase 4: Verify or show manual instructions ----
        if ($taskCreated) {
            $verify = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($verify) {
                Write-Ok "Scheduled Task '$taskName' registrato (powershell.exe, ogni giorno alle $taskTime)."
            } else {
                Write-Warn "Registrazione completata ma la task non appare. Verificare in Task Scheduler (F5 per refresh)."
            }
        } else {
            Write-Err "Impossibile registrare lo Scheduled Task automaticamente."
            Write-Warn "Registrare manualmente da un PowerShell elevato:"
            Write-Host ""
            Write-Host "      `$action    = New-ScheduledTaskAction -Execute '$psExe' -Argument '-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"' -WorkingDirectory '$installPath'" -ForegroundColor DarkYellow
            Write-Host "      `$trigger   = New-ScheduledTaskTrigger -Daily -At '$taskTime'" -ForegroundColor DarkYellow
            Write-Host "      `$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest" -ForegroundColor DarkYellow
            Write-Host "      Register-ScheduledTask -TaskName '$taskName' -Action `$action -Trigger `$trigger -Principal `$principal" -ForegroundColor DarkYellow
            Write-Host ""
        }
    }

    # ============================================================
    # DONE
    # ============================================================
    Write-Host ""
    Write-Host "  +======================================================+" -ForegroundColor Green
    Write-Host "  |          Installazione completata!                  |" -ForegroundColor Green
    Write-Host "  +======================================================+" -ForegroundColor Green
    Write-Host ""
    Write-Info "Percorso: $installPath"
    Write-Info "Per la diagnostica post-installazione:"
    Write-Host "      powershell -File `"$(Join-Path $installPath 'Install-Certament.ps1')`"" -ForegroundColor White
    Write-Host "      (Selezionare opzione 2 - Verifica installazione)" -ForegroundColor Gray
    Write-Host ""
    Write-Info "Per eseguire manualmente:"
    Write-Host "      powershell -File `"$(Join-Path $installPath '_MAINCertManager.ps1')`"" -ForegroundColor White
    Write-Host ""
    Write-Info "Ricordarsi di copiare il file .pfx in: $pfxPath"
    Write-Host ""

    if ($WaitAtEnd) {
        Read-Host "Premi Invio per chiudere"
    }
}

# ============================================================
# MAIN MENU
# ============================================================
Write-Banner
Write-Host "  Selezionare un'operazione:" -ForegroundColor White
Write-Host ""
Write-Host "     [1]  Installa CERTAMENT" -ForegroundColor White
Write-Host "     [2]  Verifica installazione (diagnostica)" -ForegroundColor White
Write-Host "     [0]  Esci" -ForegroundColor Gray
Write-Host ""
$menuChoice = Read-Host "      Scelta"
Write-Host ""

switch ($menuChoice.Trim()) {
    "1"     { Invoke-Install }
    "2"     { Invoke-Diagnostics }
    "0"     { exit 0 }
    default { Write-Warn "Scelta non valida. Uscita."; exit 1 }
}
