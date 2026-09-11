function New-JsonResponse {
    param([int]$StatusCode,[object]$Body)
    return [HttpResponseContext]@{
        StatusCode = $StatusCode
        Body = ($Body | ConvertTo-Json -Depth 12)
        Headers = @{ 'Content-Type' = 'application/json' }
    }
}

function Assert-HeartbeatToken {
    param([object]$Request)
    $expected=[string]$env:CERTAMENT_HEARTBEAT_TOKEN
    if([string]::IsNullOrWhiteSpace($expected)){throw 'CERTAMENT_HEARTBEAT_TOKEN is not configured.'}
    $provided=[string]$Request.Headers['x-certament-token']
    if([string]::IsNullOrWhiteSpace($provided) -or $provided -cne $expected){throw 'Unauthorized heartbeat request.'}
}

function Get-TableHandle {
    param([string]$Name)
    $ctx=New-AzStorageContext -ConnectionString $env:AzureWebJobsStorage
    $table=Get-AzStorageTable -Name $Name -Context $ctx -ErrorAction SilentlyContinue
    if($null -eq $table){$table=New-AzStorageTable -Name $Name -Context $ctx}
    return $table.CloudTable
}

function Get-HeartbeatState {
    param([object]$Payload)
    $now=[DateTime]::UtcNow
    $stamp=[DateTime]::Parse([string]$Payload.timestampUtc).ToUniversalTime()
    $age=($now-$stamp).TotalHours
    $status=[string]$Payload.status
    if($status -eq 'Error' -or $age -gt 48){$state='Critical'}elseif($status -match 'Warning|Awaiting|Failed' -or $age -gt 30 -or ([double]$Payload.certificateDaysRemaining -ge 0 -and [double]$Payload.certificateDaysRemaining -le 30)){$state='Warning'}else{$state='Healthy'}
    return $state
}
