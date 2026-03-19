param(
    [ValidateSet('Menu','Prepare','Status','CreateTestPfx','ActivatePfx','Restore','FinalCheck','Help')]
    [string]$Action = 'Menu',
    [string]$InstallRoot = 'C:\CERTAMENT',
    [string]$PfxDropPath = 'C:\_install',
    [string]$TaskName = 'CERTAMENT',
    [ValidateRange(1, 36500)]
    [int]$NotifyBeforeDays = 9999,
    [ValidateRange(1, 1440)]
    [int]$TaskIntervalMinutes = 5,
    [ValidateRange(1, 168)]
    [int]$TaskDurationHours = 24,
    [string]$BackupFolderName = 'e2e_tester_backup',
    [string]$SelectedPfx = '',
    [SecureString]$PfxSecret = $null,
    [string]$SecretFilePath = '',
    [string]$SubjectDns = 'bc.cert.pitto',
    [datetime]$NotAfter = (Get-Date).AddYears(3),
    [string]$OutputPfxPath = '',
    [string]$OriginalThumbprint = 'A5891105744CD279BAB93194C2A5032CD59AEB62',
    [string]$TestThumbprint = '',
    [string[]]$BCInstances = @('PROD_NUP', 'PROD_NUP2'),
    [string]$IISSiteName = 'Microsoft Dynamics 365 Business Central Web Client',
    [string]$DailyRunTime = '06:00',
    [string[]]$ExpectedPfxNames = @('2026CERT.pfx', '2027CERT.pfx')
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Eseguire lo script come Administrator.'
    }
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][SecureString]$SecureValue)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Resolve-PfxSecretPlain {
    param(
        [SecureString]$SecureSecret,
        [string]$SecretFilePath
    )

    if ($SecureSecret) {
        return ConvertTo-PlainText -SecureValue $SecureSecret
    }

    if (-not [string]::IsNullOrWhiteSpace($SecretFilePath) -and (Test-Path $SecretFilePath)) {
        return (Get-Content -Path $SecretFilePath -Raw -ErrorAction Stop).Trim()
    }

    return ''
}

function Get-LatestArchiveFolder {
    param([Parameter(Mandatory = $true)][string]$ArchiveRoot)

    if (-not (Test-Path $ArchiveRoot)) {
        throw "Cartella archive non trovata: $ArchiveRoot"
    }

    $folders = @(Get-ChildItem -Path $ArchiveRoot -Directory | Sort-Object Name -Descending)
    if ($folders.Count -eq 0) {
        throw "Nessuna sottocartella archive trovata in: $ArchiveRoot"
    }

    return $folders[0].FullName
}

function Resolve-E2EScriptMap {
    param([Parameter(Mandatory = $true)][string]$ArchiveFolder)

    $map = [ordered]@{
        TaskSetup       = Join-Path $ArchiveFolder '_e2e_task_setup.ps1'
        StateCheck      = Join-Path $ArchiveFolder '_e2e_state_check.ps1'
        VerifyPfx       = Join-Path $ArchiveFolder '_e2e_verify_2029.ps1'
        RestoreBaseline = Join-Path $ArchiveFolder '_e2e_restore_to_baseline.ps1'
        FinalCheck      = Join-Path $ArchiveFolder '_e2e_final.ps1'
    }

    foreach ($path in $map.Values) {
        if (-not (Test-Path $path)) {
            throw "Script archivio mancante: $path"
        }
    }

    return $map
}

function Invoke-ArchivedScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [hashtable]$ArgumentMap = @{}
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Script non trovato: $ScriptPath"
    }

    & $ScriptPath @ArgumentMap
}

$archiveRoot = Join-Path $PSScriptRoot 'archive'
$archiveFolder = Get-LatestArchiveFolder -ArchiveRoot $archiveRoot
$scriptMap = Resolve-E2EScriptMap -ArchiveFolder $archiveFolder
$configPath = Join-Path $InstallRoot 'config.json'
$backupFolderPath = Join-Path $PfxDropPath $BackupFolderName

function Invoke-PrepareForE2E {
    Assert-Admin

    if (-not (Test-Path $InstallRoot)) {
        throw "InstallRoot non trovato: $InstallRoot"
    }

    if (-not (Test-Path $PfxDropPath)) {
        New-Item -ItemType Directory -Path $PfxDropPath -Force | Out-Null
    }

    if (-not (Test-Path $backupFolderPath)) {
        New-Item -ItemType Directory -Path $backupFolderPath -Force | Out-Null
    }

    if (-not (Test-Path $configPath)) {
        throw "Config non trovato: $configPath"
    }

    $backupSuffix = Get-Date -Format 'yyyyMMdd_HHmmss'
    $configBackupPath = "$configPath.e2e_tester_backup_$backupSuffix"
    Copy-Item -Path $configPath -Destination $configBackupPath -Force

    $dropPfxFiles = @(Get-ChildItem -Path $PfxDropPath -Filter '*.pfx' -File -ErrorAction SilentlyContinue)
    foreach ($file in $dropPfxFiles) {
        Move-Item -Path $file.FullName -Destination (Join-Path $backupFolderPath $file.Name) -Force
    }

    $passwordTxtPath = Join-Path $PfxDropPath 'password.txt'
    if (Test-Path $passwordTxtPath) {
        Move-Item -Path $passwordTxtPath -Destination (Join-Path $backupFolderPath ("password_{0}.txt" -f $backupSuffix)) -Force
    }

    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    if (-not $config.Notifications) {
        $config | Add-Member -NotePropertyName Notifications -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $config.Notifications.CertificateExpiry) {
        $config.Notifications | Add-Member -NotePropertyName CertificateExpiry -NotePropertyValue ([pscustomobject]@{})
    }
    if (-not $config.Pfx) {
        $config | Add-Member -NotePropertyName Pfx -NotePropertyValue ([pscustomobject]@{})
    }

    $config.Notifications.CertificateExpiry.NotifyBeforeDays = [int]$NotifyBeforeDays
    $config.Pfx.Password = ''
    $config.Pfx.Path = $PfxDropPath

    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8

    Invoke-ArchivedScript -ScriptPath $scriptMap.TaskSetup -ArgumentMap @{
        TaskName = $TaskName
        IntervalMinutes = $TaskIntervalMinutes
        DurationHours = $TaskDurationHours
        StartAt = (Get-Date).AddMinutes(1)
    }

    Write-Host ''
    Write-Host 'Prepare completato.' -ForegroundColor Green
    Write-Host "Config backup: $configBackupPath"
    Write-Host "Backup PFX folder: $backupFolderPath"
    Write-Host "NotifyBeforeDays: $NotifyBeforeDays"
    Write-Host "Task cadence: ogni $TaskIntervalMinutes minuti"
}

function New-E2ETestPfx {
    Assert-Admin

    $resolvedSecret = Resolve-PfxSecretPlain -SecureSecret $PfxSecret -SecretFilePath $SecretFilePath

    if ([string]::IsNullOrWhiteSpace($resolvedSecret)) {
        throw 'Secret mancante. Passare -PfxSecret o -SecretFilePath.'
    }

    if (-not (Test-Path $backupFolderPath)) {
        New-Item -ItemType Directory -Path $backupFolderPath -Force | Out-Null
    }

    $targetPfxPath = $OutputPfxPath
    if ([string]::IsNullOrWhiteSpace($targetPfxPath)) {
        $targetPfxPath = Join-Path $backupFolderPath ("CERTAMENT_E2E_{0}.pfx" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }

    $targetFolder = Split-Path -Path $targetPfxPath -Parent
    if (-not (Test-Path $targetFolder)) {
        New-Item -ItemType Directory -Path $targetFolder -Force | Out-Null
    }

    $certificate = New-SelfSignedCertificate -DnsName $SubjectDns -CertStoreLocation 'Cert:\LocalMachine\My' -NotAfter $NotAfter -FriendlyName ("CERTAMENT E2E TEST {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
    $securePassword = ConvertTo-SecureString $resolvedSecret -AsPlainText -Force
    Export-PfxCertificate -Cert $certificate -FilePath $targetPfxPath -Password $securePassword | Out-Null

    $pfxData = Get-PfxData -FilePath $targetPfxPath -Password $securePassword
    $endCertificate = $pfxData.EndEntityCertificates

    Remove-Item -Path ("Cert:\LocalMachine\My\{0}" -f $certificate.Thumbprint) -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host 'PFX test creato.' -ForegroundColor Green
    Write-Host "Path     : $targetPfxPath"
    Write-Host "Thumb    : $($endCertificate.Thumbprint)"
    Write-Host "Scadenza : $($endCertificate.NotAfter)"
    Write-Host "Soggetto : $($endCertificate.Subject)"
}

function Set-E2EPfxDrop {
    if ([string]::IsNullOrWhiteSpace($SelectedPfx)) {
        throw 'SelectedPfx mancante. Indicare il file PFX da attivare in drop folder.'
    }

    if (-not (Test-Path $SelectedPfx)) {
        throw "PFX selezionato non trovato: $SelectedPfx"
    }

    $resolvedSecret = Resolve-PfxSecretPlain -SecureSecret $PfxSecret -SecretFilePath $SecretFilePath

    if ([string]::IsNullOrWhiteSpace($resolvedSecret)) {
        throw 'Secret mancante. Passare -PfxSecret o -SecretFilePath.'
    }

    if (-not (Test-Path $PfxDropPath)) {
        New-Item -ItemType Directory -Path $PfxDropPath -Force | Out-Null
    }

    $destinationPfx = Join-Path $PfxDropPath (Split-Path -Path $SelectedPfx -Leaf)
    Copy-Item -Path $SelectedPfx -Destination $destinationPfx -Force

    $secretDropFilePath = Join-Path $PfxDropPath 'password.txt'
    Set-Content -Path $secretDropFilePath -Value $resolvedSecret -Encoding UTF8 -NoNewline

    Write-Host ''
    Write-Host 'PFX attivato in drop folder.' -ForegroundColor Green
    Write-Host "PFX       : $destinationPfx"
    Write-Host "Secret    : $secretDropFilePath"
}

function Show-E2EStatus {
    Invoke-ArchivedScript -ScriptPath $scriptMap.StateCheck -ArgumentMap @{
        TaskName = $TaskName
        ConfigPath = $configPath
        PfxDropPath = $PfxDropPath
        BCInstances = $BCInstances
        IISSiteName = $IISSiteName
    }
}

function Restore-E2EBaseline {
    Assert-Admin

    $configBackupPath = ''
    $configBackups = @(Get-ChildItem -Path $InstallRoot -Filter 'config.json.e2e_tester_backup_*' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($configBackups.Count -gt 0) {
        $configBackupPath = $configBackups[0].FullName
    }
    elseif (Test-Path (Join-Path $InstallRoot 'config.json.e2e2_bak')) {
        $configBackupPath = Join-Path $InstallRoot 'config.json.e2e2_bak'
    }

    $backupPfxPath = ''
    $pfxCandidates = @(
        (Join-Path $backupFolderPath '2027CERT.pfx'),
        (Join-Path $PfxDropPath 'e2e2_bak\2027CERT.pfx'),
        (Join-Path $PfxDropPath '2027CERT.pfx')
    )
    foreach ($candidate in $pfxCandidates) {
        if (Test-Path $candidate) {
            $backupPfxPath = $candidate
            break
        }
    }

    $restoreArgs = @{
        OriginalThumbprint = $OriginalThumbprint
        BCInstances = $BCInstances
        IISSiteName = $IISSiteName
        ConfigPath = $configPath
        NotifyBeforeDays = 30
        PfxPasswordFallback = ''
        TaskName = $TaskName
        DailyRunTime = $DailyRunTime
    }

    if (-not [string]::IsNullOrWhiteSpace($configBackupPath)) {
        $restoreArgs['ConfigBackupPath'] = $configBackupPath
    }
    if (-not [string]::IsNullOrWhiteSpace($backupPfxPath)) {
        $restoreArgs['BackupPfxPath'] = $backupPfxPath
    }
    $resolvedSecret = Resolve-PfxSecretPlain -SecureSecret $PfxSecret -SecretFilePath $SecretFilePath
    if (-not [string]::IsNullOrWhiteSpace($resolvedSecret)) {
        $restoreArgs['BackupPfxPassword'] = $resolvedSecret
    }
    if (-not [string]::IsNullOrWhiteSpace($SecretFilePath) -and (Test-Path $SecretFilePath)) {
        $restoreArgs['BackupPasswordFile'] = $SecretFilePath
    }

    Invoke-ArchivedScript -ScriptPath $scriptMap.RestoreBaseline -ArgumentMap $restoreArgs
}

function Invoke-E2EFinalCheck {
    Invoke-ArchivedScript -ScriptPath $scriptMap.FinalCheck -ArgumentMap @{
        OriginalThumbprint = $OriginalThumbprint
        TestThumbprint = $TestThumbprint
        BCInstances = $BCInstances
        IISSiteName = $IISSiteName
        ConfigPath = $configPath
        ExpectedNotifyBeforeDays = 30
        PfxDropPath = $PfxDropPath
        ExpectedPfxNames = $ExpectedPfxNames
    }
}

function Show-HelpText {
    Write-Host ''
    Write-Host 'CERTAMENT E2E Tester'
    Write-Host ''
    Write-Host 'Azioni disponibili:'
    Write-Host '  -Action Prepare'
    Write-Host '  -Action Status'
    Write-Host '  -Action CreateTestPfx -SecretFilePath <file> [-OutputPfxPath <path>]'
    Write-Host '  -Action ActivatePfx -SelectedPfx <path> -SecretFilePath <file>'
    Write-Host '  -Action Restore [-SecretFilePath <file>]'
    Write-Host '  -Action FinalCheck [-TestThumbprint <thumb>]'
    Write-Host ''
}

function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '=== CERTAMENT E2E Tester ===' -ForegroundColor Cyan
        Write-Host '1) Prepare E2E'
        Write-Host '2) Status'
        Write-Host '3) Create test PFX'
        Write-Host '4) Activate PFX + password.txt'
        Write-Host '5) Restore baseline'
        Write-Host '6) Final check'
        Write-Host '7) Help'
        Write-Host '0) Exit'
        $choice = Read-Host 'Scelta'

        switch ($choice.Trim()) {
            '1' {
                Invoke-PrepareForE2E
            }
            '2' {
                Show-E2EStatus
            }
            '3' {
                $pwdSecure = Read-Host 'Password nuovo PFX' -AsSecureString
                $script:PfxSecret = $pwdSecure
                $subjectInput = Read-Host "Subject DNS [$SubjectDns]"
                if (-not [string]::IsNullOrWhiteSpace($subjectInput)) {
                    $script:SubjectDns = $subjectInput.Trim()
                }
                $dateInput = Read-Host ("NotAfter [{0}]" -f $NotAfter.ToString('yyyy-MM-dd'))
                if (-not [string]::IsNullOrWhiteSpace($dateInput)) {
                    $script:NotAfter = [datetime]::Parse($dateInput)
                }
                New-E2ETestPfx
            }
            '4' {
                $defaultPfx = ''
                $candidatePfx = @(Get-ChildItem -Path $backupFolderPath -Filter '*.pfx' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
                if ($candidatePfx.Count -gt 0) {
                    $defaultPfx = $candidatePfx[0].FullName
                }
                $pathInput = Read-Host "PFX da attivare [$defaultPfx]"
                if ([string]::IsNullOrWhiteSpace($pathInput)) {
                    $script:SelectedPfx = $defaultPfx
                }
                else {
                    $script:SelectedPfx = $pathInput.Trim()
                }
                $pwdSecure = Read-Host 'Password PFX' -AsSecureString
                $script:PfxSecret = $pwdSecure
                Set-E2EPfxDrop
            }
            '5' {
                Restore-E2EBaseline
            }
            '6' {
                Invoke-E2EFinalCheck
            }
            '7' {
                Show-HelpText
            }
            '0' {
                return
            }
            default {
                Write-Host 'Scelta non valida.' -ForegroundColor Yellow
            }
        }
    }
}

switch ($Action) {
    'Menu'         { Show-Menu }
    'Prepare'      { Invoke-PrepareForE2E }
    'Status'       { Show-E2EStatus }
    'CreateTestPfx'{ New-E2ETestPfx }
    'ActivatePfx'  { Set-E2EPfxDrop }
    'Restore'      { Restore-E2EBaseline }
    'FinalCheck'   { Invoke-E2EFinalCheck }
    'Help'         { Show-HelpText }
}
