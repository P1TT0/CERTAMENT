function Get-OrCreateInstallationId {
    <#
    .SYNOPSIS
        Returns the persistent InstallationId from config, generating and
        persisting one the first time it is missing.
    #>
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)]$Config
    )

    $existing = $null
    if ($Config.Context -and $Config.Context.PSObject.Properties['InstallationId']) {
        $existing = [string]$Config.Context.InstallationId
    }
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        return $existing
    }

    $newId = [guid]::NewGuid().ToString()

    if (-not $Config.PSObject.Properties['Context']) {
        $Config | Add-Member -NotePropertyName Context -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $Config.Context.PSObject.Properties['InstallationId']) {
        $Config.Context | Add-Member -NotePropertyName InstallationId -NotePropertyValue $newId -Force
    }
    else {
        $Config.Context.InstallationId = $newId
    }

    $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
    return $newId
}

Export-ModuleMember -Function Get-OrCreateInstallationId
