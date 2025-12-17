function Get-PfxDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    $pfxFiles = Get-ChildItem -Path $Path -Filter *.pfx -File -ErrorAction SilentlyContinue
    if (-not $pfxFiles) {
        Write-Error " Nessun file .pfx trovato in $Path"
        return $null
    }

    $certs = @()

    foreach ($file in $pfxFiles) {
        try {
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `
                -ArgumentList $file.FullName, $Password, `
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable

            $certs += [PSCustomObject]@{
                FilePath     = $file.FullName
                Thumbprint   = $cert.Thumbprint
                Subject      = $cert.Subject
                Issuer       = $cert.Issuer
                NotBefore    = $cert.NotBefore
                NotAfter     = $cert.NotAfter
                HasPrivateKey= $cert.HasPrivateKey
            }
        }
        catch {
            Write-Warning "️ Errore nel leggere $($file.FullName): $_"
        }
    }

    if (-not $certs) {
        Write-Error " Nessun certificato valido trovato nei PFX"
        return $null
    }

    $latestCert = $certs | Sort-Object NotAfter -Descending | Select-Object -First 1

    return $latestCert
}

