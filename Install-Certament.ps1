<#
.SYNOPSIS
    Install CERTAMENT on a client server.

.DESCRIPTION
    Copies CERTAMENT files to the install path, creates config.json from
    template if not present, and registers a Windows Scheduled Task for
    daily automatic execution.

.PARAMETER InstallPath
    Destination directory. Defaults to C:\CERTAMENT.

.PARAMETER TaskTime
    Time of day to run the scheduled task (HH:mm). Defaults to "06:00".

.PARAMETER SkipTask
    Skip scheduled task creation (install files only).

.EXAMPLE
    .\Install-Certament.ps1
    .\Install-Certament.ps1 -InstallPath "D:\Tools\CERTAMENT" -TaskTime "03:00"
#>
[CmdletBinding()]
param(
    [string]$InstallPath = "C:\CERTAMENT",
    [string]$TaskTime = "06:00",
    [switch]$SkipTask
)

# Require admin
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "L'installazione richiede privilegi di Amministratore."
    exit 1
}

$sourceDir = $PSScriptRoot

Write-Host "============================================================"
Write-Host "  CERTAMENT - Installazione"
Write-Host "============================================================"
Write-Host "Origine:      $sourceDir"
Write-Host "Destinazione: $InstallPath"
Write-Host ""

# --- Copy files ---
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

$filesToCopy = @(
    '_MAINCertManager.ps1',
    'config.example.json'
)

$foldersToCopy = @('modules', 'tools')

foreach ($file in $filesToCopy) {
    $src = Join-Path $sourceDir $file
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $InstallPath -Force
        Write-Host "  Copiato: $file"
    }
    else {
        Write-Warning "  Non trovato: $file"
    }
}

foreach ($folder in $foldersToCopy) {
    $src = Join-Path $sourceDir $folder
    $dst = Join-Path $InstallPath $folder
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $dst -Recurse -Force
        Write-Host "  Copiato: $folder\"
    }
}

# Create logs directory
$logsDir = Join-Path $InstallPath "logs"
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Write-Host "  Creata: logs\"
}

# --- Config ---
$configDst = Join-Path $InstallPath "config.json"
if (-not (Test-Path $configDst)) {
    $exampleSrc = Join-Path $InstallPath "config.example.json"
    if (Test-Path $exampleSrc) {
        Copy-Item -Path $exampleSrc -Destination $configDst
        Write-Host ""
        Write-Host "ATTENZIONE: config.json creato da template." -ForegroundColor Yellow
        Write-Host "Modificare $configDst con i valori corretti prima di eseguire." -ForegroundColor Yellow
    }
}
else {
    Write-Host "  config.json gia presente, non sovrascritto."
}

# --- Scheduled Task ---
if (-not $SkipTask) {
    Write-Host ""
    Write-Host "Registrazione Scheduled Task..."

    $taskName = "CERTAMENT"
    $scriptPath = Join-Path $InstallPath "_MAINCertManager.ps1"

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
        -WorkingDirectory $InstallPath

    $trigger = New-ScheduledTaskTrigger -Daily -At $TaskTime

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopOnIdleEnd `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    # Remove existing task if present
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "  Task precedente rimosso."
    }

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "CERTAMENT - Gestione automatica certificati Business Central" | Out-Null

    Write-Host "  Task '$taskName' registrato (esecuzione giornaliera alle $TaskTime)."
}

Write-Host ""
Write-Host "============================================================"
Write-Host "  Installazione completata."
Write-Host "============================================================"
Write-Host ""
Write-Host "Prossimi passi:" -ForegroundColor Cyan
Write-Host "  1. Modificare $configDst con password PFX e webhook URL"
Write-Host "  2. Copiare il file PFX nella cartella configurata"
Write-Host "  3. Eseguire manualmente per test:"
Write-Host "     powershell -File `"$scriptPath`""
Write-Host ""
