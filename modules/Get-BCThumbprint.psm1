function Get-BCThumbprint {
    [CmdletBinding()]
    param()

    $instances = Get-NAVServerInstance
    $found = @()

    foreach ($instance in $instances) {
        try {
            $thumbprint = Get-NAVServerConfiguration -ServerInstance $instance.ServerInstance -KeyName "ServicesCertificateThumbprint"
        }
        catch {
            continue
        }

        if ($thumbprint -and $thumbprint.Trim() -ne "") {
            $found += [PSCustomObject]@{
                Instance   = $instance.ServerInstance
                Thumbprint = $thumbprint.Trim().ToUpper()
            }
        }
    }

    if ($found.Count -eq 0) {
        return $null
    }

    # Warn on cross-instance inconsistency
    $uniqueThumbs = @($found | Select-Object -ExpandProperty Thumbprint -Unique)
    if ($uniqueThumbs.Count -gt 1) {
        Write-Warning "Thumbprint INCONSISTENTI tra istanze BC:"
        $found | ForEach-Object { Write-Warning ("  {0} -> {1}" -f $_.Instance, $_.Thumbprint) }
    }

    return $found[0].Thumbprint
}

Export-ModuleMember -Function Get-BCThumbprint
