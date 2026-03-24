<#
.SYNOPSIS
    CERTAMENT interactive uninstaller.

.DESCRIPTION
    Removes installed CERTAMENT components: Scheduled Task, install folder,
    and optionally PFX/log artefacts. Requires Administrator privileges.

.EXAMPLE
    .\Uninstall-Certament.ps1
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ============================================================
# Helpers
# ============================================================
function Write-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +======================================================+" -ForegroundColor Red
    Write-Host "  |          CERTAMENT  -  Uninstaller v1.0             |" -ForegroundColor Red
    Write-Host "  |    Rimozione completa dell'installazione            |" -ForegroundColor Red
    Write-Host "  +======================================================+" -ForegroundColor Red
    Write-Host ""
}

function Write-Ok   { param([string]$msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info { param([string]$msg) Write-Host "  [i]  $msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$msg) Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$msg) Write-Host "  [X]  $msg" -ForegroundColor Red }

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { "[S/n]" } else { "[s/N]" }
    $raw = Read-Host "      $Prompt $hint"
    if ($raw.Trim() -eq "") { return $Default }
    return ($raw.Trim() -imatch '^s')
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
# Require Administrator
# ============================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  CERTAMENT Uninstaller richiede privilegi di Amministratore." -ForegroundColor Red
    Write-Host "  Rilancio con elevazione..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"") -Verb RunAs
    exit
}

# ============================================================
# Detect installation
# ============================================================
Write-Banner

$taskInstallPath = Get-CertamentTaskInstallPath
$defaultPath = if ($taskInstallPath) {
    $taskInstallPath
} elseif (Test-Path "C:\CERTAMENT\config.json") {
    "C:\CERTAMENT"
} else {
    "C:\CERTAMENT"
}

# Check if task exists
$taskExists = $null -ne (Get-ScheduledTask -TaskName "CERTAMENT" -ErrorAction SilentlyContinue)

# Check if install folder exists
$folderExists = Test-Path $defaultPath

if (-not $taskExists -and -not $folderExists) {
    Write-Warn "Nessuna installazione CERTAMENT rilevata."
    Write-Info "Task 'CERTAMENT' non trovata e $defaultPath non esiste."
    Write-Host ""
    Read-Host "  Premi Invio per chiudere"
    exit 0
}

# ============================================================
# Show what was found
# ============================================================
Write-Host "  Installazione rilevata:" -ForegroundColor White
Write-Host ""

if ($taskExists) {
    $taskInfo = Get-ScheduledTask -TaskName "CERTAMENT" -ErrorAction SilentlyContinue
    $taskState = $taskInfo.State
    Write-Info "Scheduled Task 'CERTAMENT' presente (stato: $taskState)"
}

if ($folderExists) {
    Write-Info "Cartella installazione: $defaultPath"
    # Read config for PFX path info
    $pfxPath = $null
    $configFile = Join-Path $defaultPath "config.json"
    if (Test-Path $configFile) {
        try {
            $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
            $pfxPath = $cfg.Pfx.Path
            $customerName = $cfg.Context.CustomerName
            Write-Info "Cliente: $customerName"
            if ($pfxPath) {
                Write-Info "Cartella PFX configurata: $pfxPath"
            }
        } catch { }
    }
}

Write-Host ""
Write-Host "  +-------------------------------------------------+" -ForegroundColor Yellow
Write-Host "  |  ATTENZIONE: Questa operazione e' irreversibile |" -ForegroundColor Yellow
Write-Host "  +-------------------------------------------------+" -ForegroundColor Yellow
Write-Host ""

if (-not (Read-YesNo -Prompt "Procedere con la disinstallazione?" -Default $false)) {
    Write-Info "Disinstallazione annullata."
    Write-Host ""
    Read-Host "  Premi Invio per chiudere"
    exit 0
}

# ============================================================
# Phase 1: Remove Scheduled Task
# ============================================================
Write-Host ""
Write-Host "  --- Fase 1: Rimozione Scheduled Task ---" -ForegroundColor Yellow
Write-Host ""

if ($taskExists) {
    try {
        # Stop if running
        $taskInfo = Get-ScheduledTask -TaskName "CERTAMENT" -ErrorAction SilentlyContinue
        if ($taskInfo.State -eq 'Running') {
            Write-Info "Task in esecuzione, arresto in corso..."
            Stop-ScheduledTask -TaskName "CERTAMENT" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        # Remove via COM first (handles edge cases better)
        try {
            $scheduler = New-Object -ComObject Schedule.Service
            $scheduler.Connect()
            $rootFolder = $scheduler.GetFolder("\")
            $rootFolder.DeleteTask("CERTAMENT", 0)
            Write-Ok "Scheduled Task rimossa (COM)."
        }
        catch {
            # Fallback to cmdlet
            Unregister-ScheduledTask -TaskName "CERTAMENT" -Confirm:$false -ErrorAction Stop
            Write-Ok "Scheduled Task rimossa (cmdlet)."
        }
        finally {
            if ($scheduler) {
                [System.Runtime.InteropServices.Marshal]::ReleaseComObject($scheduler) | Out-Null
                $scheduler = $null
            }
        }

        # Clean up orphan task file
        $taskFile = Join-Path $env:WINDIR "System32\Tasks\CERTAMENT"
        if (Test-Path $taskFile) {
            Remove-Item -Path $taskFile -Force -ErrorAction SilentlyContinue
            Write-Info "File task orfano rimosso."
        }
    }
    catch {
        Write-Err "Errore rimozione task: $_"
    }
} else {
    Write-Info "Nessuna Scheduled Task da rimuovere."
}

# ============================================================
# Phase 2: Remove install folder
# ============================================================
Write-Host ""
Write-Host "  --- Fase 2: Rimozione cartella installazione ---" -ForegroundColor Yellow
Write-Host ""

if ($folderExists) {
    # Show folder contents summary
    $fileCount = (Get-ChildItem -Path $defaultPath -Recurse -File -ErrorAction SilentlyContinue).Count
    $logCount  = (Get-ChildItem -Path (Join-Path $defaultPath "logs") -Recurse -File -ErrorAction SilentlyContinue).Count
    Write-Info "Cartella: $defaultPath ($fileCount file totali, $logCount log)"

    if (Read-YesNo -Prompt "Eliminare la cartella $defaultPath e tutto il suo contenuto?" -Default $true) {
        try {
            # Make sure we're not inside the folder we're deleting
            Set-Location $env:SYSTEMDRIVE

            Remove-Item -Path $defaultPath -Recurse -Force -ErrorAction Stop
            Write-Ok "Cartella $defaultPath rimossa."
        }
        catch {
            Write-Err "Errore rimozione cartella: $_"
            Write-Warn "Potrebbe essere necessario chiudere tutti i processi e riprovare."
        }
    } else {
        Write-Info "Cartella mantenuta."
    }
} else {
    Write-Info "Cartella $defaultPath non presente."
}

# ============================================================
# Phase 3: Optional PFX folder cleanup
# ============================================================
Write-Host ""
Write-Host "  --- Fase 3: Pulizia cartella PFX (opzionale) ---" -ForegroundColor Yellow
Write-Host ""

if ($pfxPath -and (Test-Path $pfxPath)) {
    $pfxFiles = Get-ChildItem -Path $pfxPath -Filter "*.pfx" -ErrorAction SilentlyContinue
    $pwdFiles = Get-ChildItem -Path $pfxPath -Filter "password.txt" -ErrorAction SilentlyContinue
    $archiveDir = Join-Path $pfxPath "archive"
    $hasArchive = Test-Path $archiveDir

    if ($pfxFiles -or $pwdFiles -or $hasArchive) {
        Write-Info "Contenuto cartella PFX ($pfxPath):"
        if ($pfxFiles)   { Write-Info "  - $($pfxFiles.Count) file .pfx" }
        if ($pwdFiles)   { Write-Info "  - password.txt presente" }
        if ($hasArchive) { Write-Info "  - cartella archive/ presente" }

        if (Read-YesNo -Prompt "Eliminare i file PFX e password dalla cartella $pfxPath?" -Default $false) {
            try {
                if ($pfxFiles) {
                    $pfxFiles | Remove-Item -Force -ErrorAction SilentlyContinue
                    Write-Ok "File .pfx rimossi."
                }
                if ($pwdFiles) {
                    $pwdFiles | Remove-Item -Force -ErrorAction SilentlyContinue
                    Write-Ok "password.txt rimosso."
                }
                if ($hasArchive -and (Read-YesNo -Prompt "Eliminare anche la cartella archive/?" -Default $false)) {
                    Remove-Item -Path $archiveDir -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Ok "Cartella archive/ rimossa."
                }
            }
            catch {
                Write-Err "Errore pulizia PFX: $_"
            }
        } else {
            Write-Info "Cartella PFX mantenuta."
        }
    } else {
        Write-Info "Cartella PFX vuota o non contiene file rilevanti."
    }
} else {
    Write-Info "Nessuna cartella PFX da pulire."
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host "  |          Disinstallazione completata                 |" -ForegroundColor Green
Write-Host "  +======================================================+" -ForegroundColor Green
Write-Host ""
Write-Info "CERTAMENT e' stato rimosso dal sistema."
Write-Info "I certificati installati nello store NON vengono rimossi."
Write-Info "Per rimuovere un certificato: .\tools\Remove-Cert.ps1 -Thumbprint <THUMBPRINT>"
Write-Host ""
Read-Host "  Premi Invio per chiudere"
