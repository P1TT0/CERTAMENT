function New-MonitoringResponse {
    param([int]$StatusCode,[object]$Body)
    [HttpResponseContext]@{StatusCode=$StatusCode;Body=($Body|ConvertTo-Json -Depth 12);Headers=@{'Content-Type'='application/json'}}
}
function Assert-HeartbeatToken {
    param([object]$Request)
    $expected=[string]$env:CERTAMENT_HEARTBEAT_TOKEN;$provided=[string]$Request.Headers['x-certament-token']
    if([string]::IsNullOrWhiteSpace($expected)){throw [UnauthorizedAccessException]::new('Heartbeat token is not configured.')}
    if([string]::IsNullOrWhiteSpace($provided) -or $provided -cne $expected){throw [UnauthorizedAccessException]::new('Unauthorized heartbeat request.')}
}
function ConvertTo-PayloadObject($Body){if($Body -is [string]){return ($Body|ConvertFrom-Json)};return $Body}
function Assert-HeartbeatPayload($Payload){
    foreach($name in (Get-HeartbeatRequiredFields)){if($null -eq $Payload.$name -or [string]::IsNullOrWhiteSpace([string]$Payload.$name)){throw "Missing heartbeat field: $name"}}
    if([string]$Payload.tool -ne 'CERTAMENT'){throw 'Invalid heartbeat tool.'}
    if((Get-HeartbeatStatuses)-notcontains [string]$Payload.status){throw 'Invalid heartbeat status.'}
    $null=[DateTime]::Parse([string]$Payload.timestampUtc).ToUniversalTime()
}
function Get-HeartbeatClassification($Payload){$age=([DateTime]::UtcNow-[DateTime]::Parse([string]$Payload.timestampUtc).ToUniversalTime()).TotalHours;$days=if($null -ne $Payload.certificateDaysRemaining){[double]$Payload.certificateDaysRemaining}else{999999};if([string]$Payload.status -eq 'Error' -or $age -gt $script:FreshnessCriticalHours){'Critical'}elseif([string]$Payload.status -eq 'CompletedWithWarnings' -or [string]$Payload.status -eq 'AwaitingPfx' -or $age -gt $script:FreshnessWarningHours -or $days -le 30){'Warning'}else{'Healthy'}}
