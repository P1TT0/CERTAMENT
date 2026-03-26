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

# The big block logo lines (used by both static and animated)
function Get-LogoLines {
    # ANSI Shadow block font for "CERTAMENT" built with [char] codes for PS 5.1 safety
    $F  = [char]0x2588  # Full block
    $TL = [char]0x2554  # Top-left double
    $TR = [char]0x2557  # Top-right double
    $BL = [char]0x255A  # Bottom-left double
    $BR = [char]0x255D  # Bottom-right double
    $H  = [char]0x2550  # Horizontal double
    $V  = [char]0x2551  # Vertical double
    $s  = ' '

    # Each letter as 6-line array, standard ANSI Shadow proportions
    $C = @(
        "$s$F$F$F$F$F$F$TL",
        "$F$F$TL$H$H$H$H$BR",
        "$F$F$V$s$s$s$s$s",
        "$F$F$V$s$s$s$s$s",
        "$BL$F$F$F$F$F$F$TL",
        "$s$BL$H$H$H$H$H$BR"
    )
    $E = @(
        "$F$F$F$F$F$F$F$TL",
        "$F$F$TL$H$H$H$H$BR",
        "$F$F$F$F$F$TL$s$s",
        "$F$F$TL$H$H$BR$s$s",
        "$F$F$F$F$F$F$F$TL",
        "$BL$H$H$H$H$H$H$BR"
    )
    $R = @(
        "$F$F$F$F$F$F$TL$s",
        "$F$F$TL$H$H$F$F$TL",
        "$F$F$F$F$F$F$TL$BR",
        "$F$F$TL$H$F$F$TL$s",
        "$F$F$V$s$s$F$F$V",
        "$BL$H$BR$s$s$BL$H$BR"
    )
    $T = @(
        "$F$F$F$F$F$F$F$F$TL",
        "$BL$H$H$F$F$TL$H$H$BR",
        "$s$s$s$F$F$V$s$s$s",
        "$s$s$s$F$F$V$s$s$s",
        "$s$s$s$F$F$V$s$s$s",
        "$s$s$s$BL$H$BR$s$s$s"
    )
    $A = @(
        "$s$F$F$F$F$F$TL$s",
        "$F$F$TL$H$H$F$F$TL",
        "$F$F$F$F$F$F$F$V",
        "$F$F$TL$H$H$F$F$V",
        "$F$F$V$s$s$F$F$V",
        "$BL$H$BR$s$s$BL$H$BR"
    )
    $M = @(
        "$F$F$TL$s$s$s$F$F$TL",
        "$F$F$F$F$TL$F$F$F$F$V",
        "$F$F$TL$F$F$TL$F$F$V",
        "$F$F$V$BL$F$TL$F$F$V",
        "$F$F$V$s$BL$BR$F$F$V",
        "$BL$H$BR$s$s$s$BL$H$BR"
    )
    $N = @(
        "$F$F$TL$s$s$F$F$TL",
        "$F$F$F$TL$s$F$F$V",
        "$F$F$TL$F$TL$F$F$V",
        "$F$F$V$BL$F$F$F$V",
        "$F$F$V$s$BL$F$F$V",
        "$BL$H$BR$s$s$BL$H$BR"
    )
    # "Certament" = C E R T A M E N T
    $gap = '  '
    $lines = @()
    for ($row = 0; $row -lt 6; $row++) {
        $lines += $C[$row] + $gap + $E[$row] + $gap + $R[$row] + $gap + $T[$row] + $gap + $A[$row] + $gap + $M[$row] + $gap + $E[$row] + $gap + $N[$row] + $gap + $T[$row]
    }
    return $lines
}

function Get-LogoLineColors {
    return @('Cyan','Cyan','White','White','Cyan','DarkCyan')
}

function Write-BannerLines {
    param([switch]$NoNewlineBefore)
    $logoLines  = Get-LogoLines
    $logoColors = Get-LogoLineColors
    $maxLen = 0; foreach ($ll in $logoLines) { if ($ll.Length -gt $maxLen) { $maxLen = $ll.Length } }
    $hLine  = [string]::new([char]0x2550, [Math]::Min($maxLen, 90))
    if (-not $NoNewlineBefore) { Write-Host "" }
    for ($i = 0; $i -lt $logoLines.Count; $i++) {
        Write-Host "  $($logoLines[$i])" -ForegroundColor $logoColors[$i]
    }
    Write-Host ""
    Write-Host "  $hLine" -ForegroundColor DarkGray
    Write-Host "   Automated Certificate Manager for BC + IIS                              v1.0" -ForegroundColor Gray
    Write-Host "   $env:COMPUTERNAME  $([char]0x00B7)  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor DarkGray
    Write-Host "  $hLine" -ForegroundColor DarkGray
    Write-Host ''
}

function Write-AnimatedBanner {
    Clear-Host
    try { $Host.UI.RawUI.WindowTitle = "CERTAMENT - Certificate Manager" } catch {}

    $logoLines  = Get-LogoLines
    $logoColors = Get-LogoLineColors
    $maxLen = 0; foreach ($ll in $logoLines) { if ($ll.Length -gt $maxLen) { $maxLen = $ll.Length } }
    $width  = $maxLen + 4
    $hLen   = [Math]::Min($maxLen, 90)
    $hLine  = [string]::new([char]0x2550, $hLen)

    # --- Phase 0: Blank space to position logo ---
    $topPad = 2
    for ($p = 0; $p -lt $topPad; $p++) { Write-Host "" }

    # --- Phase 1: Matrix rain teaser ---
    $matrixChars = '01{}[]<>/\|$#@%&*=+~^CERTAMENT'.ToCharArray()
    $rainRows = $logoLines.Count
    $rainColors = @('DarkGreen','Green','DarkCyan','DarkGreen','Green')
    $startPos = $Host.UI.RawUI.CursorPosition

    # Reserve space
    for ($r = 0; $r -lt $rainRows; $r++) { Write-Host (' ' * $width) }

    # Rain animation frames
    for ($frame = 0; $frame -lt 8; $frame++) {
        for ($r = 0; $r -lt $rainRows; $r++) {
            $pos = $startPos
            $pos.Y = $startPos.Y + $r
            $pos.X = 0
            $Host.UI.RawUI.CursorPosition = $pos

            $line = ""
            for ($c = 0; $c -lt $width; $c++) {
                if ((Get-Random -Minimum 0 -Maximum 100) -lt (15 + $frame * 10)) {
                    $line += $matrixChars[(Get-Random -Minimum 0 -Maximum $matrixChars.Count)]
                } else {
                    $line += ' '
                }
            }
            $color = $rainColors[(Get-Random -Minimum 0 -Maximum $rainColors.Count)]
            Write-Host $line -ForegroundColor $color -NoNewline
        }
        Start-Sleep -Milliseconds 60
    }

    # --- Phase 2: Flash white then clear ---
    for ($r = 0; $r -lt $rainRows; $r++) {
        $pos = $startPos
        $pos.Y = $startPos.Y + $r
        $pos.X = 0
        $Host.UI.RawUI.CursorPosition = $pos
        Write-Host ([string]::new([char]0x2588, $width)) -ForegroundColor White -NoNewline
    }
    Start-Sleep -Milliseconds 100

    for ($r = 0; $r -lt $rainRows; $r++) {
        $pos = $startPos
        $pos.Y = $startPos.Y + $r
        $pos.X = 0
        $Host.UI.RawUI.CursorPosition = $pos
        Write-Host (' ' * $width) -NoNewline
    }
    Start-Sleep -Milliseconds 80

    # --- Phase 3: Center-out wipe reveal ---
    $center = [int]($maxLen / 2)
    $revealSteps = $center + 2

    for ($step = 0; $step -lt $revealSteps; $step += 3) {
        $left  = [Math]::Max(0, $center - $step)
        $right = [Math]::Min($maxLen, $center + $step)

        for ($r = 0; $r -lt $logoLines.Count; $r++) {
            $pos = $startPos
            $pos.Y = $startPos.Y + $r
            $pos.X = 0
            $Host.UI.RawUI.CursorPosition = $pos

            $ln = $logoLines[$r]
            if ($ln.Length -lt $maxLen) { $ln = $ln.PadRight($maxLen) }

            $visible = (' ' * $left) + $ln.Substring($left, [Math]::Min($right - $left, $ln.Length - $left))
            $visible = $visible.PadRight($maxLen)
            Write-Host "  $visible" -ForegroundColor $logoColors[$r] -NoNewline
        }
        Start-Sleep -Milliseconds 16
    }

    # Final full logo
    for ($r = 0; $r -lt $logoLines.Count; $r++) {
        $pos = $startPos
        $pos.Y = $startPos.Y + $r
        $pos.X = 0
        $Host.UI.RawUI.CursorPosition = $pos
        $ln = $logoLines[$r].PadRight($width)
        Write-Host "  $ln" -ForegroundColor $logoColors[$r] -NoNewline
    }

    # --- Phase 4: Color pulse ---
    $pulseColors = @('DarkCyan','Cyan','White','Cyan','DarkCyan')
    foreach ($pc in $pulseColors) {
        for ($r = 0; $r -lt $logoLines.Count; $r++) {
            $pos = $startPos
            $pos.Y = $startPos.Y + $r
            $pos.X = 0
            $Host.UI.RawUI.CursorPosition = $pos
            $ln = $logoLines[$r].PadRight($width)
            Write-Host "  $ln" -ForegroundColor $pc -NoNewline
        }
        Start-Sleep -Milliseconds 70
    }

    # Final stable with correct per-line colors
    for ($r = 0; $r -lt $logoLines.Count; $r++) {
        $pos = $startPos
        $pos.Y = $startPos.Y + $r
        $pos.X = 0
        $Host.UI.RawUI.CursorPosition = $pos
        $ln = $logoLines[$r].PadRight($width)
        Write-Host "  $ln" -ForegroundColor $logoColors[$r] -NoNewline
    }
    Start-Sleep -Milliseconds 100

    # Move cursor below logo
    $endPos = $startPos
    $endPos.Y = $startPos.Y + $logoLines.Count
    $endPos.X = 0
    $Host.UI.RawUI.CursorPosition = $endPos
    Write-Host ""

    # --- Phase 5: Separator line sweep ---
    $partialLine = ""
    $stepSize = 6
    for ($c = 0; $c -lt $hLen; $c += $stepSize) {
        $len = [Math]::Min($stepSize, $hLen - $c)
        $partialLine += [string]::new([char]0x2550, $len)
        $linePos = $Host.UI.RawUI.CursorPosition
        $linePos.X = 0
        $Host.UI.RawUI.CursorPosition = $linePos
        Write-Host "  $partialLine" -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 8
    }
    Write-Host ""

    # --- Phase 6: Typewriter info ---
    $infoText   = "   Automated Certificate Manager for BC + IIS                              v1.0"
    $serverText = "   $env:COMPUTERNAME  $([char]0x00B7)  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

    foreach ($ch in $infoText.ToCharArray()) {
        Write-Host $ch -NoNewline -ForegroundColor Gray
        Start-Sleep -Milliseconds 4
    }
    Write-Host ""
    foreach ($ch in $serverText.ToCharArray()) {
        Write-Host $ch -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 4
    }
    Write-Host ""
    Write-Host "  $hLine" -ForegroundColor DarkGray
    Write-Host ''
}

function Write-Banner {
    Clear-Host
    try { $Host.UI.RawUI.WindowTitle = "CERTAMENT - Certificate Manager" } catch {}
    Write-BannerLines
}

function Write-Step {
    param([int]$n, [int]$total, [string]$label)
    Write-Host ""
    $filled = [string]::new([char]0x2588, $n)
    $empty  = [string]::new([char]0x2591, $total - $n)
    Write-Host "  [$filled$empty] " -NoNewline -ForegroundColor DarkCyan
    Write-Host "Step $n/$total" -ForegroundColor DarkGray
    Write-Host "  $([char]0x25BA) $label" -ForegroundColor Yellow
    Write-Host ""
}

# Draws the wizard header: banner + mini-recap of collected values + current step
function Write-WizardScreen {
    param([int]$StepNum, [int]$StepTotal, [string]$StepLabel, [hashtable]$Collected)
    Clear-Host
    try { $Host.UI.RawUI.WindowTitle = "CERTAMENT - Certificate Manager" } catch {}
    Write-BannerLines -NoNewlineBefore

    # Show compact recap of previously collected values
    if ($Collected -and $Collected.Count -gt 0) {
        $tV = [char]0x2502
        Write-Host "  Configurazione raccolta:" -ForegroundColor DarkGray
        foreach ($key in $Collected.Keys) {
            $val = $Collected[$key]
            $displayVal = if ([string]::IsNullOrWhiteSpace($val)) { "-" } else { $val }
            if ($displayVal.Length -gt 40) { $displayVal = $displayVal.Substring(0,37) + "..." }
            Write-Host "  $tV " -NoNewline -ForegroundColor DarkCyan
            Write-Host "$key" -NoNewline -ForegroundColor DarkGray
            Write-Host " : " -NoNewline -ForegroundColor DarkGray
            Write-Host "$displayVal" -ForegroundColor White
        }
        Write-Host ""
    }

    # Current step header
    $filled = [string]::new([char]0x2588, $StepNum)
    $empty  = [string]::new([char]0x2591, $StepTotal - $StepNum)
    Write-Host "  [$filled$empty] " -NoNewline -ForegroundColor DarkCyan
    Write-Host "Step $StepNum/$StepTotal" -ForegroundColor DarkGray
    Write-Host "  $([char]0x25BA) $StepLabel" -ForegroundColor Yellow
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
    $notificationsEnabled = $true
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

            if ($cfg.Notifications -and $cfg.Notifications.PSObject.Properties['EnableWebhook'] -and $cfg.Notifications.EnableWebhook -eq $false) {
                $notificationsEnabled = $false
                Write-Info "  Notifications.EnableWebhook=false: test webhook disabilitati."
            }
            if ($notificationsEnabled) {
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

    if (-not $notificationsEnabled) {
        Write-Info "  Notifiche disabilitate da config: test webhook saltati."
    }
    else {
        if ($notifCmd -and $webhookTable.ContainsKey('Internal')) {
            $testTitle = "CERTAMENT - Test diagnostica Internal"
            $testMsg = "Test webhook Internal da diagnostica CERTAMENT su $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
            $sentInternal = Send-Notification -Title $testTitle -Message $testMsg -Target "Internal" -Webhooks $webhookTable
            Write-DiagCheck -Result ([bool]$sentInternal) -Label "Invio notifica test Internal"
        }

        if ($notifCmd -and $webhookTable.ContainsKey('Customer')) {
            $testTitle = "CERTAMENT - Test diagnostica Customer"
            $testMsg = "Test webhook Customer da diagnostica CERTAMENT su $env:COMPUTERNAME ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))"
            $sentCustomer = Send-Notification -Title $testTitle -Message $testMsg -Target "Customer" -Webhooks $webhookTable
            Write-DiagCheck -Result ([bool]$sentCustomer) -Label "Invio notifica test Customer"
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

            if ($notifCmd -and $notificationsEnabled -and $webhookTable.ContainsKey('Internal')) {
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
    Write-DiagCheck -AsWarn -Result ($null -ne $task) -Label "Task 'CERTAMENT' registrato"
    if ($task) {
        Write-DiagCheck -AsWarn -Result ($task.State -in @('Ready', 'Running')) -Label "Task stato: $($task.State)"
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
            Write-DiagCheck -AsWarn -Result ($httpsCount -gt 0) -Label "Binding HTTPS presenti per il sito ($httpsCount)"
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

                $runWsCheck = Read-YesNo -Prompt "Eseguire anche test reachability web service BC?" -Default $false
                if ($runWsCheck) {
                    $wsResults = Test-BCWebServices -TimeoutSec 15
                    if ($wsResults) {
                        $wsErrors = @($wsResults | Where-Object { $_.Status -eq 'ERROR' })
                        $wsSkipped = @($wsResults | Where-Object { $_.Status -like 'SKIPPED*' })

                        foreach ($wsResult in $wsResults) {
                            $wsDetail = if ($wsResult.Response) { [string]$wsResult.Response } elseif ($wsResult.Error) { [string]$wsResult.Error } else { 'Nessun dettaglio' }
                            Write-Info "  WS $($wsResult.Instance): $($wsResult.Status) - $wsDetail"
                        }

                        Write-DiagCheck -AsWarn -Result ($wsResults.Count -gt 0) -Label "Test web service BC eseguito" -Detail "$($wsResults.Count) endpoint controllati"
                        Write-DiagCheck -AsWarn -Result ($wsErrors.Count -eq 0) -Label "Endpoint web service BC raggiungibili"
                        Write-DiagCheck -AsWarn -Result ($wsSkipped.Count -eq 0) -Label "URL web service BC validi"
                    }
                    else {
                        Write-DiagCheck -AsWarn -Result $false -Label "Test web service BC eseguito" -Detail "Nessun risultato restituito"
                    }
                }
                else {
                    Write-Info "  Test web service BC saltato."
                }
            }
        } catch {
            Write-DiagCheck -AsWarn -Result $false -Label "Accesso istanze BC" -Detail $_.Exception.Message
        }
    }

    # ---- Summary ----
    Write-Host ""
    $sumColor = if ($script:dFail -gt 0) { "Red" } elseif ($script:dWarn -gt 0) { "Yellow" } else { "Green" }
    $bH = [string]::new([char]0x2550, 53)
    Write-Host "  $([char]0x2554)$bH$([char]0x2557)" -ForegroundColor $sumColor
    Write-Host ("  $([char]0x2551)  PASS: {0,-5}  $([char]0x00B7)  WARN: {1,-5}  $([char]0x00B7)  FAIL: {2,-5}        $([char]0x2551)" -f $script:dPass, $script:dWarn, $script:dFail) -ForegroundColor $sumColor
    Write-Host "  $([char]0x255A)$bH$([char]0x255D)" -ForegroundColor $sumColor
    Write-Host ""
}

# ============================================================
# INSTALL WIZARD
# ============================================================
function Invoke-Install {
    $collected = [ordered]@{}

    # ---------- Step 1: Install path ----------
    Write-WizardScreen -StepNum 1 -StepTotal 6 -StepLabel "Percorso di installazione" -Collected $collected
    Write-Info "Dove installare CERTAMENT su questo server?"
    $installPath = Read-Value -Prompt "Percorso" -Default "C:\CERTAMENT"
    $collected["Percorso"] = $installPath
    Write-Info "Nome cliente (tag usato in notifiche e heartbeat)."
    $customerName = Read-Value -Prompt "Nome cliente" -Default $env:COMPUTERNAME
    $collected["Cliente"] = $customerName

    # ---------- Step 2: PFX drop folder ----------
    Write-WizardScreen -StepNum 2 -StepTotal 6 -StepLabel "Cartella PFX" -Collected $collected
    Write-Info "Percorso della cartella dove verra depositato il file .pfx rinnovato."
    Write-Info "CERTAMENT cerchera il .pfx piu recente in questa cartella."
    $pfxPath = Read-Value -Prompt "Cartella PFX" -Default "C:\_install"
    $collected["Cartella PFX"] = $pfxPath

    Write-Info "Password PFX: il cliente puo creare un file 'password.txt' nella cartella PFX."
    Write-Info "CERTAMENT lo leggera e lo eliminera dopo l'uso."
    Write-Info "In alternativa, inserire una password di fallback qui (oppure lasciare vuoto)."
    $pfxPassword = Read-Value -Prompt "Password PFX fallback (opzionale)" -Default "" -AllowEmpty
    $collected["Pwd PFX"] = if ($pfxPassword) { "Fallback config" } else { "Solo password.txt" }

    # ---------- Step 3: IIS ----------
    Write-WizardScreen -StepNum 3 -StepTotal 6 -StepLabel "Configurazione IIS" -Collected $collected
    Write-Info "Nome del sito IIS Business Central (esatto, case-sensitive)."
    $iisSiteName = Read-Value -Prompt "Nome sito IIS" -Default "Microsoft Dynamics 365 Business Central Web Client"
    $collected["Sito IIS"] = $iisSiteName
    $iisRestart = Read-YesNo -Prompt "Riavviare IIS dopo aggiornamento del binding?" -Default $true
    $collected["Restart IIS"] = if ($iisRestart) { "Si" } else { "No" }

    # ---------- Step 4: Notifications ----------
    Write-WizardScreen -StepNum 4 -StepTotal 6 -StepLabel "Notifiche Teams (Power Automate webhook)" -Collected $collected
    Write-Info "Le notifiche vengono inviate tramite webhook a Microsoft Teams."
    Write-Info "Lasciare vuoto per disabilitare le notifiche."

    $webhookCustomer = Read-Value -Prompt "Webhook Customer (Teams)" -AllowEmpty
    $collected["WH Customer"] = if ($webhookCustomer) { "Configurato" } else { "Disabilitato" }
    $webhookInternal = Read-Value -Prompt "Webhook Internal (Teams)" -AllowEmpty
    $collected["WH Internal"] = if ($webhookInternal) { "Configurato" } else { "Disabilitato" }

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
    $collected["Heartbeat"] = if ($heartbeatEnabled) { "Si ($heartbeatTimeoutSec sec)" } else { "No" }

    Write-Info "Quanti giorni prima della scadenza avviare il processo di rinnovo?"
    $notifyDays = Read-Value -Prompt "Giorni soglia scadenza" -Default "30"
    while ($notifyDays -notmatch '^\d+$') {
        Write-Warn "Inserire un numero intero."
        $notifyDays = Read-Value -Prompt "Giorni soglia scadenza" -Default "30"
    }
    $collected["Soglia gg"] = "$notifyDays giorni"

    # ---------- Step 5: Scheduled Task ----------
    Write-WizardScreen -StepNum 5 -StepTotal 6 -StepLabel "Scheduled Task" -Collected $collected
    $createTask = Read-YesNo -Prompt "Registrare uno Scheduled Task per l'esecuzione automatica?" -Default $true
    $taskTime = "06:00"
    if ($createTask) {
        Write-Info "A che ora eseguire CERTAMENT ogni giorno?"
        $taskTime = Read-TimeValue -Prompt "Orario esecuzione (HH:mm)" -Default "06:00"
    }
    $collected["Task"] = if ($createTask) { "Si, alle $taskTime" } else { "No" }

    # ---------- Step 6: Confirm ----------
    Write-WizardScreen -StepNum 6 -StepTotal 6 -StepLabel "Riepilogo" -Collected $collected

    $tH = [string]::new([char]0x2500, 53)
    $tV = [char]0x2502
    Write-Host "  $([char]0x250C)$tH$([char]0x2510)" -ForegroundColor DarkCyan
    Write-Host ("  $tV  Percorso installazione : {0}" -f $installPath.PadRight(27)) -ForegroundColor White
    Write-Host ("  $tV  Nome cliente           : {0}" -f ($customerName.Substring(0, [Math]::Min(27, $customerName.Length))).PadRight(27)) -ForegroundColor White
    Write-Host ("  $tV  Cartella PFX           : {0}" -f $pfxPath.PadRight(27)) -ForegroundColor White
    Write-Host ("  $tV  Password PFX           : {0}" -f ($(if ($pfxPassword) {"Fallback nel config"} else {"Solo password.txt"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  $tV  Sito IIS               : {0}" -f ($iisSiteName.Substring(0, [Math]::Min(27, $iisSiteName.Length))).PadRight(27)) -ForegroundColor White
    Write-Host ("  $tV  Riavvio IIS            : {0}" -f ($(if ($iisRestart) {"Si"} else {"No"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  $tV  Webhook Customer       : {0}" -f ($(if ($webhookCustomer) {"Configurato"} else {"Disabilitato"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  $tV  Webhook Internal       : {0}" -f ($(if ($webhookInternal) {"Configurato"} else {"Disabilitato"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  $tV  Heartbeat Azure        : {0}" -f ($(if ($heartbeatEnabled) {"Si ($heartbeatTimeoutSec sec)"} else {"No"}).PadRight(27))) -ForegroundColor White
    Write-Host ("  $tV  Soglia scadenza        : {0} giorni" -f $notifyDays.PadRight(21)) -ForegroundColor White
    Write-Host ("  $tV  Scheduled Task         : {0}" -f ($(if ($createTask) {"Si, alle $taskTime"} else {"No"}).PadRight(27))) -ForegroundColor White
    Write-Host "  $([char]0x2514)$tH$([char]0x2518)" -ForegroundColor DarkCyan
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
            Path     = $pfxPath
            Password = $pfxPassword
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
    $cH = [string]::new([char]0x2550, 56)
    Write-Host "  $([char]0x2554)$cH$([char]0x2557)" -ForegroundColor Green
    Write-Host "  $([char]0x2551)$(' ' * 56)$([char]0x2551)" -ForegroundColor Green
    Write-Host "  $([char]0x2551)       INSTALLAZIONE COMPLETATA CON SUCCESSO        $([char]0x2551)" -ForegroundColor Green
    Write-Host "  $([char]0x2551)$(' ' * 56)$([char]0x2551)" -ForegroundColor Green
    Write-Host "  $([char]0x255A)$cH$([char]0x255D)" -ForegroundColor Green
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
Write-AnimatedBanner
Write-Host "  Selezionare un'operazione:" -ForegroundColor White
Write-Host ""
Write-Host "      [1]  Installa CERTAMENT" -ForegroundColor Cyan
Write-Host "      [2]  Verifica installazione (diagnostica)" -ForegroundColor White
Write-Host "      [0]  Esci" -ForegroundColor DarkGray
Write-Host ""
$hRule = [string]::new([char]0x2500, 63)
Write-Host "  $hRule" -ForegroundColor DarkGray
Write-Host ""
$menuChoice = Read-Host "      Scelta"
Write-Host ""

switch ($menuChoice.Trim()) {
    "1"     { Invoke-Install }
    "2"     { Invoke-Diagnostics }
    "0"     { exit 0 }
    default { Write-Warn "Scelta non valida. Uscita."; exit 1 }
}
