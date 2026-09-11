. "$PSScriptRoot\..\shared\Storage.ps1"
param($Request,$TriggerMetadata)
try{$table=Get-TableHandle $env:CERTAMENT_HISTORY_TABLE;$rows=@(Get-AzTableRow -table $table -top 20);Push-OutputBinding -Name Response -Value (New-JsonResponse 200 @($rows|Sort-Object TimestampUtc -Descending|Select-Object -First 20))}catch{Push-OutputBinding -Name Response -Value (New-JsonResponse 500 @{error=$_.Exception.Message})}
