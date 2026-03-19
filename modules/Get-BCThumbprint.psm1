function Get-BCThumbprint {
    [CmdletBinding()]
    param()

    $instances = Get-NAVServerInstance

    foreach ($instance in $instances) {
        try {
            $thumbprint = Get-NAVServerConfiguration -ServerInstance $instance.ServerInstance -KeyName "ServicesCertificateThumbprint"
        }
        catch {
            continue
        }

        if ($thumbprint -and $thumbprint.Trim() -ne "") {
            return $thumbprint.Trim()
        }
    }

    return $null
}

Export-ModuleMember -Function Get-BCThumbprint
