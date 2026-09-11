using namespace System.Net
. "$PSScriptRoot\..\shared\Storage.ps1"
param($Request,$TriggerMetadata)
try {
    Assert-HeartbeatToken $Request
    $payload=$Request.Body
    if($payload -is [string]){$payload=$payload|ConvertFrom-Json}
    foreach($name in @('schemaVersion','version','runId','customer','server','status','stage','detail','timestampUtc','durationSec','certificateDaysRemaining','notificationStatus')){if($null -eq $payload.$name){throw "Missing heartbeat field: $name"}}
    $latest=Get-TableHandle $env:CERTAMENT_LATEST_TABLE
    $history=Get-TableHandle $env:CERTAMENT_HISTORY_TABLE
    $state=Get-HeartbeatState $payload
    $props=@{Customer=[string]$payload.customer;Version=[string]$payload.version;Status=[string]$state;RunStatus=[string]$payload.status;Stage=[string]$payload.stage;Detail=[string]$payload.detail;TimestampUtc=[string]$payload.timestampUtc;DurationSec=[double]$payload.durationSec;CertificateDaysRemaining=[double]$payload.certificateDaysRemaining;NotificationStatus=[string]$payload.notificationStatus;RunId=[string]$payload.runId;SchemaVersion=[string]$payload.schemaVersion}
    $latestRow=Get-AzTableRow -table $latest -partitionKey 'server' -rowKey ([string]$payload.server) -ErrorAction SilentlyContinue
    if($null -ne $latestRow){Remove-AzTableRow -table $latest -partitionKey 'server' -rowKey ([string]$payload.server)|Out-Null}
    Add-AzTableRow -table $latest -partitionKey 'server' -rowKey ([string]$payload.server) -property $props|Out-Null
    Add-AzTableRow -table $history -partitionKey ([string]$payload.server) -rowKey ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmssfff')+'_'+[guid]::NewGuid().ToString('N')) -property $props|Out-Null
    Push-OutputBinding -Name Response -Value (New-JsonResponse 202 @{accepted=$true;server=$payload.server;status=$state})
} catch { Push-OutputBinding -Name Response -Value (New-JsonResponse 400 @{accepted=$false;error=$_.Exception.Message}) }
