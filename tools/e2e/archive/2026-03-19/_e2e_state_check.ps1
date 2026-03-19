param(
  [string]$TaskName = "CERTAMENT",
  [string]$ConfigPath = "C:\CERTAMENT\config.json",
  [string]$PfxDropPath = "C:\_install",
  [string]$InstalledSubFolder = "installed",
  [string]$PasswordFileName = "password.txt",
  [string[]]$BCInstances = @("PROD_NUP", "PROD_NUP2"),
  [string]$BCModulePath = "C:\Program Files\Microsoft Dynamics 365 Business Central\260\Service\Microsoft.Dynamics.Nav.Management.psm1",
  [string]$IISSiteName = "Microsoft Dynamics 365 Business Central Web Client"
)

$ErrorActionPreference = 'Stop'

Write-Host '=== TASK STATUS ==='
$scheduledTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
if ($scheduledTask) {
  Write-Host ('State      : ' + $scheduledTask.State)
  Write-Host ('LastRun    : ' + $taskInfo.LastRunTime)
  Write-Host ('NextRun    : ' + $taskInfo.NextRunTime)
  Write-Host ('LastResult : ' + $taskInfo.LastTaskResult)
  $action = $scheduledTask.Actions | Select-Object -First 1
  Write-Host ('Action     : ' + $action.Execute + ' ' + $action.Arguments)
}
else {
  Write-Host ('Task non trovato: ' + $TaskName)
}

Write-Host "`n=== CONFIG STATE ==="
if (Test-Path $ConfigPath) {
  $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
  Write-Host ('NotifyBeforeDays: ' + $config.Notifications.CertificateExpiry.NotifyBeforeDays)
  Write-Host ('Pfx.Password len: ' + ([string]$config.Pfx.Password).Length)
  Write-Host ('Pfx.Path        : ' + $config.Pfx.Path)
}
else {
  Write-Host ('Config non trovato: ' + $ConfigPath)
}

Write-Host "`n=== PFX FOLDERS ==="
Write-Host ('[' + $PfxDropPath + ' *.pfx]')
Get-ChildItem $PfxDropPath -Filter '*.pfx' -File -ErrorAction SilentlyContinue |
  Select-Object Name, LastWriteTime | Format-Table -AutoSize

$installedPath = Join-Path $PfxDropPath $InstalledSubFolder
Write-Host ('[' + $installedPath + ' *.pfx]')
if (Test-Path $installedPath) {
  Get-ChildItem $installedPath -Filter '*.pfx' -File -ErrorAction SilentlyContinue |
    Select-Object Name, LastWriteTime | Format-Table -AutoSize
}
else {
  Write-Host 'Installed folder non presente'
}

$passwordFilePath = Join-Path $PfxDropPath $PasswordFileName
Write-Host ('password file present: ' + (Test-Path $passwordFilePath))

Write-Host "`n=== BC + IIS THUMBPRINTS ==="
Import-Module $BCModulePath -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
foreach ($instanceName in $BCInstances) {
  $thumbprint = Get-NAVServerConfiguration -ServerInstance $instanceName -KeyName 'ServicesCertificateThumbprint' -ErrorAction SilentlyContinue
  Write-Host ($instanceName + ' -> ' + $thumbprint)
}

Import-Module WebAdministration -ErrorAction SilentlyContinue
$bindings = @(Get-WebBinding -Name $IISSiteName -Protocol https -ErrorAction SilentlyContinue)
if ($bindings.Count -eq 0) {
  Write-Host ('Nessun binding https trovato per sito: ' + $IISSiteName)
}
else {
  foreach ($binding in $bindings) {
    Write-Host ('IIS ' + $binding.bindingInformation + ' -> ' + $binding.certificateHash)
  }
}
