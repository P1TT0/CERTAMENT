$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'monitoring\shared\model.ps1')
. (Join-Path $root 'monitoring\shared\keys.ps1')
. (Join-Path $root 'monitoring\shared\validation.ps1')
Describe 'Monitoring model' {
    It 'accepts a valid heartbeat with optional fields omitted' {
        $p=[pscustomobject]@{schemaVersion=1;tool='CERTAMENT';version='1.0.0';runId='r1';InstallationId='i1';customer='c';server='s';status='Healthy';stage='MainEnd';timestampUtc='2026-09-12T10:00:00Z'}
        {Assert-HeartbeatPayload $p}|Should Not Throw
    }
    It 'rejects missing required fields' {
        $p=[pscustomobject]@{schemaVersion=1;tool='CERTAMENT';version='1.0.0';runId='r1';customer='c';server='s';status='Healthy';stage='MainEnd'}
        $threw=$false;try{Assert-HeartbeatPayload $p}catch{$threw=$true};$threw|Should Be $true
    }
    It 'rejects a payload missing only InstallationId' {
        $p=[pscustomobject]@{schemaVersion=1;tool='CERTAMENT';version='1.0.0';runId='r1';customer='c';server='s';status='Healthy';stage='MainEnd';timestampUtc='2026-09-12T10:00:00Z'}
        $threw=$false;try{Assert-HeartbeatPayload $p}catch{$threw=$true};$threw|Should Be $true
    }
    It 'rejects an invalid status' {
        $p=[pscustomobject]@{schemaVersion=1;tool='CERTAMENT';version='1.0.0';runId='r1';InstallationId='i1';customer='c';server='s';status='NotAStatus';stage='MainEnd';timestampUtc='2026-09-12T10:00:00Z'}
        $threw=$false;try{Assert-HeartbeatPayload $p}catch{$threw=$true};$threw|Should Be $true
    }
    It 'rejects an invalid tool' {
        $p=[pscustomobject]@{schemaVersion=1;tool='OTHER';version='1.0.0';runId='r1';InstallationId='i1';customer='c';server='s';status='Healthy';stage='MainEnd';timestampUtc='2026-09-12T10:00:00Z'}
        $threw=$false;try{Assert-HeartbeatPayload $p}catch{$threw=$true};$threw|Should Be $true
    }
    It 'classifies stale and critical heartbeats' {
        $warning=[pscustomobject]@{status='Healthy';timestampUtc=(Get-Date).ToUniversalTime().AddHours(-31).ToString('o')}
        $critical=[pscustomobject]@{status='Healthy';timestampUtc=(Get-Date).ToUniversalTime().AddHours(-49).ToString('o')}
        (Get-HeartbeatClassification $warning)|Should Be 'Warning';(Get-HeartbeatClassification $critical)|Should Be 'Critical'
    }
    It 'classifies a fresh healthy heartbeat as Healthy' {
        $healthy=[pscustomobject]@{status='Healthy';timestampUtc=(Get-Date).ToUniversalTime().ToString('o')}
        (Get-HeartbeatClassification $healthy)|Should Be 'Healthy'
    }
    It 'classifies an Error status as Critical even when fresh' {
        $errorFresh=[pscustomobject]@{status='Error';timestampUtc=(Get-Date).ToUniversalTime().ToString('o')}
        (Get-HeartbeatClassification $errorFresh)|Should Be 'Critical'
    }
    It 'classifies certificateDaysRemaining <= 30 as Warning even when fresh' {
        $expiringSoon=[pscustomobject]@{status='Healthy';timestampUtc=(Get-Date).ToUniversalTime().ToString('o');certificateDaysRemaining=30}
        (Get-HeartbeatClassification $expiringSoon)|Should Be 'Warning'
    }
}
Describe 'Monitoring storage keys' {
    It 'is deterministic and installation based' { $a=Get-LatestPartitionKey 'installation-a';$b=Get-LatestPartitionKey 'installation-a';$c=Get-LatestPartitionKey 'installation-b';$a|Should Be $b;$a|Should Not Be $c;(Get-HistoryRowKey ([datetime]'2026-09-12T10:00:00Z') 'run-1')|Should Match '20260912T100000000Z_' }
    It 'uses the same PartitionKey for Latest and History for the same InstallationId' {
        $latestPk=Get-LatestPartitionKey 'installation-a'
        $historyPk=Get-HistoryPartitionKey 'installation-a'
        $latestPk|Should Be $historyPk
    }
}
Describe 'Monitoring local contract' {
    It 'does not expose the heartbeat token in dashboard code' { Get-Content (Join-Path $root 'monitoring\dashboard\app.js') -Raw|Should Not Match 'CERTAMENT_HEARTBEAT_TOKEN' }
    It 'contains all API function definitions' { foreach($file in @('Heartbeat','Servers','History','Health')){Test-Path (Join-Path $root ("monitoring\$file\function.json"))|Should Be $true} }
}
