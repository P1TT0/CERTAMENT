param($Request,$TriggerMetadata)
. "$PSScriptRoot\..\shared\Storage.ps1"
try{$table=Get-TableHandle $env:CERTAMENT_HISTORY_TABLE;$rows=@(Get-AzTableRow -table $table|Sort-Object TimestampUtc -Descending|Select-Object -First 20);Push-OutputBinding -Name Response -Value (New-MonitoringResponse 200 $rows)}catch{Write-Error $_;Push-OutputBinding -Name Response -Value (New-MonitoringResponse 500 @{error='Storage operation failed.'})}
