function Get-BCThumbprint {



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

$thumbprint = Get-BCThumbprint
if ($thumbprint) {
    Write-Output $thumbprint
} else {
    Write-Warning " Nessun certificato trovato."
}

