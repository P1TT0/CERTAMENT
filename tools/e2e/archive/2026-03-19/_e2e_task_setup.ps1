param(
	[string]$TaskName = "CERTAMENT",
	[ValidateRange(1, 1440)]
	[int]$IntervalMinutes = 5,
	[ValidateRange(1, 168)]
	[int]$DurationHours = 24,
	[datetime]$StartAt = (Get-Date).AddMinutes(1)
)

Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null

$trigger = New-ScheduledTaskTrigger -Once -At $StartAt `
	-RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
	-RepetitionDuration (New-TimeSpan -Hours $DurationHours)

Set-ScheduledTask -TaskName $TaskName -Trigger $trigger | Out-Null

$updatedTask = Get-ScheduledTask -TaskName $TaskName
$taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
Write-Host "Task updated: State=$($updatedTask.State)"
Write-Host "Next run: $($taskInfo.NextRunTime)"
Write-Host "Trigger: every $IntervalMinutes minutes for $DurationHours hours"
