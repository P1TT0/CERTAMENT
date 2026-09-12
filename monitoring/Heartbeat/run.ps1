param($Request,$TriggerMetadata)
. "$PSScriptRoot\..\shared\Storage.ps1"
try {
    try { Assert-HeartbeatToken $Request } catch [UnauthorizedAccessException] { Push-OutputBinding -Name Response -Value (New-MonitoringResponse 401 @{error='Unauthorized'}); return }
    try { $payload=ConvertTo-PayloadObject $Request.Body;Assert-HeartbeatPayload $payload } catch { Push-OutputBinding -Name Response -Value (New-MonitoringResponse 400 @{error='Invalid heartbeat payload.'}); return }
    try {
        $state=Get-HeartbeatClassification $payload
        Save-LatestHeartbeat (Get-TableHandle $env:CERTAMENT_LATEST_TABLE) $payload $state
        Save-HistoryHeartbeat (Get-TableHandle $env:CERTAMENT_HISTORY_TABLE) $payload $state
        Push-OutputBinding -Name Response -Value (New-MonitoringResponse 202 @{accepted=$true;installationId=$payload.InstallationId;status=$state})
    } catch { Write-Error $_; Push-OutputBinding -Name Response -Value (New-MonitoringResponse 500 @{error='Storage operation failed.'}); return }
} catch { Write-Error $_; Push-OutputBinding -Name Response -Value (New-MonitoringResponse 500 @{error='Monitoring service failure.'}) }
