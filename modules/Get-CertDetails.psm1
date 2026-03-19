function Get-CertDetails {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true, Mandatory = $true)]
        [string]$Thumbprint,

        [int]$WarningDays = 30
    )

    process {
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $Thumbprint.ToUpper() }
        if (-not $cert) {
            Write-Error "Certificato $Thumbprint non trovato nello store LocalMachine\My"
            return
        }

        [PSCustomObject]@{
            Thumbprint       = $cert.Thumbprint
            Subject          = $cert.Subject
            Issuer           = $cert.Issuer
            NotBefore        = $cert.NotBefore
            NotAfter         = $cert.NotAfter
            DaysRemaining    = (New-TimeSpan -Start (Get-Date) -End $cert.NotAfter).Days
            ExpiringSoon     = ((New-TimeSpan -Start (Get-Date) -End $cert.NotAfter).Days -le $WarningDays)
            EnhancedKeyUsage = ($cert.EnhancedKeyUsageList | ForEach-Object { $_.FriendlyName }) -join ', '
            DnsNames         = ($cert.DnsNameList | ForEach-Object { $_.Unicode }) -join ', '
            SerialNumber     = $cert.SerialNumber
            HasPrivateKey    = $cert.HasPrivateKey
            Archived         = $cert.Archived
            FriendlyName     = $cert.FriendlyName
            StoreLocation    = "LocalMachine\My"
        }
    }
}

Export-ModuleMember -Function Get-CertDetails
