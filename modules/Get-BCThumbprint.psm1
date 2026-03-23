function Get-BCThumbprint {
    [CmdletBinding()]
    param()

    $instances = Get-NAVServerInstance

    # Build a map: thumbprint -> list of instance names
    $thumbInstanceMap = @{}

    foreach ($instance in $instances) {
        # Skip disabled services (StartupType = Disabled)
        try {
            $svc = Get-Service -Name $instance.ServerInstance -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') {
                Write-Host ("  Istanza {0}: servizio disabilitato, esclusa." -f $instance.ServerInstance)
                continue
            }
        }
        catch { }

        try {
            $thumbprint = Get-NAVServerConfiguration -ServerInstance $instance.ServerInstance -KeyName "ServicesCertificateThumbprint"
        }
        catch {
            continue
        }

        if ($thumbprint -and $thumbprint.Trim() -ne "") {
            $thumb = $thumbprint.Trim().ToUpper()
            if (-not $thumbInstanceMap.ContainsKey($thumb)) {
                $thumbInstanceMap[$thumb] = @()
            }
            $thumbInstanceMap[$thumb] += $instance.ServerInstance
        }
    }

    if ($thumbInstanceMap.Count -eq 0) {
        return $null
    }

    $result = @(foreach ($thumb in $thumbInstanceMap.Keys) {
        [PSCustomObject]@{
            Thumbprint = $thumb
            Instances  = $thumbInstanceMap[$thumb]
        }
    })

    if ($result.Count -gt 1) {
        Write-Host ("Rilevati {0} certificati distinti tra le istanze BC:" -f $result.Count)
        foreach ($entry in $result) {
            Write-Host ("  [{0}] -> istanze: {1}" -f $entry.Thumbprint, ($entry.Instances -join ', '))
        }
    }

    return $result
}

Export-ModuleMember -Function Get-BCThumbprint
