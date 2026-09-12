function ConvertTo-StorageKeyPart {
    param([Parameter(Mandatory)][string]$Value)
    $bytes=[Text.Encoding]::UTF8.GetBytes($Value.Trim())
    $hash=[Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([Convert]::ToBase64String($hash)-replace '[^A-Za-z0-9_-]','_')
}
function Get-LatestPartitionKey { param([string]$InstallationId); return 'installation_'+(ConvertTo-StorageKeyPart $InstallationId) }
function Get-LatestRowKey { 'latest' }
function Get-HistoryPartitionKey { param([string]$InstallationId); return (Get-LatestPartitionKey $InstallationId) }
function Get-HistoryRowKey { param([datetime]$TimestampUtc,[string]$RunId); return (($TimestampUtc.ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ'))+'_'+(ConvertTo-StorageKeyPart $RunId)) }
