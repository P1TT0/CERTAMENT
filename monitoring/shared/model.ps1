$script:HeartbeatRequiredFields=@('schemaVersion','tool','version','runId','customer','server','status','stage','timestampUtc','InstallationId')
$script:HeartbeatOptionalFields=@('detail','durationSec','certificateDaysRemaining','notificationStatus')
$script:HeartbeatStatuses=@('Started','Healthy','AwaitingPfx','Completed','CompletedWithWarnings','Error')
$script:NotificationStatuses=@('NotAttempted','Sent','Failed','Disabled')
$script:FreshnessWarningHours=30
$script:FreshnessCriticalHours=48
function Get-HeartbeatRequiredFields { @($script:HeartbeatRequiredFields) }
function Get-HeartbeatOptionalFields { @($script:HeartbeatOptionalFields) }
function Get-HeartbeatStatuses { @($script:HeartbeatStatuses) }
function Get-NotificationStatuses { @($script:NotificationStatuses) }
