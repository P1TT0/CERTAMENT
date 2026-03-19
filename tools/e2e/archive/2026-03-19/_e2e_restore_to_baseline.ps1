param(
    [string]$OriginalThumbprint = 'A5891105744CD279BAB93194C2A5032CD59AEB62',
    [string]$BackupPfxPath = 'C:\_install\e2e2_bak\2027CERT.pfx',
    [string]$BackupPfxPassword = '',
    [string]$BackupPasswordFile = '',
    [string[]]$BCInstances = @('PROD_NUP', 'PROD_NUP2'),
    [string]$BCModulePath = 'C:\Program Files\Microsoft Dynamics 365 Business Central\260\Service\Microsoft.Dynamics.Nav.Management.psm1',
    [string]$IISSiteName = 'Microsoft Dynamics 365 Business Central Web Client',
    [string]$ConfigPath = 'C:\CERTAMENT\config.json',
    [string]$ConfigBackupPath = 'C:\CERTAMENT\config.json.e2e2_bak',
    [int]$NotifyBeforeDays = 30,
    [string]$PfxPasswordFallback = '',
    [string]$TaskName = 'CERTAMENT',
    [string]$DailyRunTime = '06:00'
)

$ErrorActionPreference = 'Stop'
$originalThumbNormalized = ($OriginalThumbprint -replace '\s', '').ToUpper()

Write-Host '=== RESTORE ORIGINAL CERT IN STORE (if needed) ==='
$originalCertificate = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    ($_.Thumbprint -replace '\s', '').ToUpper() -eq $originalThumbNormalized
}

if (-not $originalCertificate) {
    if (-not (Test-Path $BackupPfxPath)) {
        throw 'Original cert missing in store and backup PFX not found.'
    }

    if ([string]::IsNullOrWhiteSpace($BackupPfxPassword) -and -not [string]::IsNullOrWhiteSpace($BackupPasswordFile) -and (Test-Path $BackupPasswordFile)) {
        $BackupPfxPassword = (Get-Content -Path $BackupPasswordFile -Raw -ErrorAction Stop).Trim()
    }

    if ([string]::IsNullOrWhiteSpace($BackupPfxPassword)) {
        throw 'Backup PFX password missing. Pass -BackupPfxPassword or -BackupPasswordFile.'
    }

    $secureBackupPassword = ConvertTo-SecureString $BackupPfxPassword -AsPlainText -Force
    Import-PfxCertificate -FilePath $BackupPfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $secureBackupPassword -Exportable | Out-Null
    Write-Host 'Original cert imported from backup PFX.'
}

Write-Host "`n=== RESTORE BC THUMBPRINTS ==="
Import-Module $BCModulePath -WarningAction SilentlyContinue -ErrorAction Stop
foreach ($instanceName in $BCInstances) {
    Set-NAVServerConfiguration -ServerInstance $instanceName -KeyName 'ServicesCertificateThumbprint' -KeyValue $originalThumbNormalized -ErrorAction Stop
    Restart-NAVServerInstance -ServerInstance $instanceName -ErrorAction Stop | Out-Null
    Write-Host ($instanceName + ' restored and restarted.')
}

Write-Host "`n=== RESTORE IIS BINDING ==="
$iisAssemblyPath = 'C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll'
[void][Reflection.Assembly]::LoadFrom($iisAssemblyPath)
$serverManager = New-Object Microsoft.Web.Administration.ServerManager
$site = $serverManager.Sites[$IISSiteName]
if (-not $site) {
    throw ('IIS site not found: ' + $IISSiteName)
}

$certificate = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    ($_.Thumbprint -replace '\s', '').ToUpper() -eq $originalThumbNormalized
}
$certificateHash = $certificate.GetCertHash()

foreach ($binding in $site.Bindings) {
    if ($binding.Protocol -ne 'https') { continue }
    $binding.CertificateHash = $certificateHash
    $binding.CertificateStoreName = 'My'
}

$serverManager.CommitChanges()
iisreset /restart | Out-Null
Write-Host 'IIS restored.'

Write-Host "`n=== RESTORE CONFIG ==="
if (Test-Path $ConfigBackupPath) {
    Copy-Item $ConfigBackupPath $ConfigPath -Force
}

if (-not (Test-Path $ConfigPath)) {
    throw ('Config not found: ' + $ConfigPath)
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($config.Notifications -and $config.Notifications.CertificateExpiry) {
    $config.Notifications.CertificateExpiry.NotifyBeforeDays = [int]$NotifyBeforeDays
}
if ($config.Pfx) {
    $config.Pfx.Password = $PfxPasswordFallback
}

$config | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath -Encoding UTF8
Write-Host ('Config restored: NotifyBeforeDays=' + $NotifyBeforeDays + ', Pfx.Password updated.')

Write-Host "`n=== RESTORE TASK SCHEDULE ==="
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At $DailyRunTime
Set-ScheduledTask -TaskName $TaskName -Trigger $dailyTrigger | Out-Null
Write-Host ('Task restored to daily ' + $DailyRunTime)

Write-Host "`n=== POST-CHECK ==="
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ('NextRun: ' + $taskInfo.NextRunTime)
