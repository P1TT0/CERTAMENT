function Send-Notification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [ValidateSet("Customer", "Internal")]
        [string]$Target,

        [Parameter(Mandatory)]
        [hashtable]$Webhooks
    )

    $uri = $Webhooks[$Target]
    if (-not $uri) {
        Write-Warning "Nessun webhook configurato per '$Target'. Notifica ignorata."
        return
    }

    $payload = @{
        type        = "message"
        attachments = @(
            @{
                contentType = "application/vnd.microsoft.card.adaptive"
                content     = @{
                    '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                    type      = "AdaptiveCard"
                    version   = "1.4"
                    body      = @(
                        @{
                            type   = "TextBlock"
                            text   = $Title
                            weight = "Bolder"
                            size   = "Medium"
                        },
                        @{
                            type = "TextBlock"
                            text = ($Message -replace '\n', "`n")
                            wrap = $true
                        }
                    )
                }
            }
        )
    } | ConvertTo-Json -Depth 6

    try {
        Invoke-RestMethod -Method POST -Uri $uri -ContentType "application/json; charset=utf-8" -Body $payload -ErrorAction Stop
        Write-Host "Notifica inviata a ${Target}: ${Title}"
    }
    catch {
        Write-Warning "Errore nell'invio notifica a ${Target}: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Send-Notification
