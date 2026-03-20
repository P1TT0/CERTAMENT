function Test-SslThumbprint {
    [CmdletBinding()]
    param([string]$Url)

    try {
        $uri = [System.Uri]$Url
        if ($uri.Scheme -ne 'https') { return $null }
        $hostname = $uri.Host
        $port = if ($uri.Port -gt 0) { $uri.Port } else { 443 }

        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($hostname, $port)
        $ssl = New-Object System.Net.Security.SslStream(
            $tcp.GetStream(), $false,
            { param($s,$c,$ch,$e) return $true }
        )
        $ssl.AuthenticateAsClient($hostname)
        $certHash = $ssl.RemoteCertificate.GetCertHash()
        $thumb = ([System.BitConverter]::ToString($certHash) -replace '-', '').ToUpper()
        $ssl.Dispose()
        $tcp.Dispose()
        return $thumb
    }
    catch {
        return $null
    }
}

function Test-BCWebServices {
    [CmdletBinding()]
    param (
        [int]$TimeoutSec = 10,
        [string]$ExpectedThumbprint = ''
    )

    if (-not (Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue)) {
        $bcPath = Get-ChildItem -Path "C:\Program Files\Microsoft Dynamics 365 Business Central" `
            -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" `
            -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName -ErrorAction SilentlyContinue

        if ($bcPath) {
            try { Import-Module $bcPath -Force -ErrorAction Stop }
            catch { Write-Warning "Impossibile importare modulo BC: $($_.Exception.Message)"; return $null }
        }
        else {
            Write-Warning "Modulo Business Central non trovato."
            return $null
        }
    }

    try {
        $instances = Get-NAVServerInstance -ErrorAction Stop
    }
    catch {
        Write-Warning "Errore durante Get-NAVServerInstance: $($_.Exception.Message)"
        return $null
    }

    $expectedNorm = if ($ExpectedThumbprint) { ($ExpectedThumbprint -replace '\s', '').ToUpper() } else { '' }
    $results = @()

    foreach ($inst in $instances) {
        $name = $inst.ServerInstance

        # Skip istanze senza thumbprint configurato
        $instThumb = $null
        try { $instThumb = Get-NAVServerConfiguration -ServerInstance $name -KeyName "ServicesCertificateThumbprint" -ErrorAction SilentlyContinue } catch {}
        if (-not $instThumb -or $instThumb.Trim() -eq '') {
            Write-Host "  Skip $name (nessun thumbprint configurato)" -ForegroundColor Gray
            continue
        }

        Write-Host "  Test istanza: $name"

        $odataUrl = $null
        $soapUrl = $null

        try { $odataUrl = Get-NAVServerConfiguration -ServerInstance $name -KeyName "PublicODataBaseUrl" -ErrorAction SilentlyContinue } catch {}
        try { $soapUrl = Get-NAVServerConfiguration -ServerInstance $name -KeyName "PublicSOAPBaseUrl" -ErrorAction SilentlyContinue } catch {}

        if (-not $odataUrl -and $inst.PSObject.Properties.Match('PublicODataBaseUrl')) { $odataUrl = $inst.PublicODataBaseUrl }
        if (-not $soapUrl -and $inst.PSObject.Properties.Match('PublicSOAPBaseUrl')) { $soapUrl = $inst.PublicSOAPBaseUrl }

        $urls = @()
        if ($odataUrl -and $odataUrl.Trim()) { $urls += $odataUrl.Trim() }
        if ($soapUrl -and $soapUrl.Trim()) { $urls += $soapUrl.Trim() }

        if (-not $urls) {
            Write-Warning "Nessun URL pubblico configurato per istanza $name."
            continue
        }

        foreach ($url in $urls) {
            Write-Host "    Test: $url"

            $uriObj = $null
            $isValidUrl = [System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uriObj) -and `
                ($uriObj.Scheme -eq 'http' -or $uriObj.Scheme -eq 'https')
            if (-not $isValidUrl) {
                Write-Warning "    URL non valido (skip): $url"
                $results += [PSCustomObject]@{
                    Instance      = $name
                    Url           = $url
                    Status        = "SKIPPED (Invalid URL)"
                    Response      = $null
                    Error         = $null
                    SslThumbprint = $null
                    SslMatch      = $null
                }
                continue
            }

            # SSL certificate verification
            $sslThumb = Test-SslThumbprint -Url $url
            $sslMatch = $null
            if ($sslThumb -and $expectedNorm) {
                $sslMatch = ($sslThumb -eq $expectedNorm)
                $matchLabel = if ($sslMatch) { 'MATCH' } else { 'MISMATCH' }
                Write-Host "    SSL cert: $sslThumb [$matchLabel]"
            }
            elseif ($sslThumb) {
                Write-Host "    SSL cert: $sslThumb"
            }

            # HTTP connectivity check
            try {
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
                $status = [PSCustomObject]@{
                    Instance      = $name
                    Url           = $url
                    Status        = "OK"
                    Response      = "$($resp.StatusCode) $($resp.StatusDescription)"
                    Error         = $null
                    SslThumbprint = $sslThumb
                    SslMatch      = $sslMatch
                }
                Write-Host "    OK ($($resp.StatusCode))"
            }
            catch {
                $errmsg = $_.Exception.Message
                if ($errmsg -match '401|403') {
                    $status = [PSCustomObject]@{
                        Instance      = $name
                        Url           = $url
                        Status        = "OK (Auth Required)"
                        Response      = $errmsg
                        Error         = $null
                        SslThumbprint = $sslThumb
                        SslMatch      = $sslMatch
                    }
                    Write-Host "    WS risponde (autenticazione richiesta)."
                }
                else {
                    $status = [PSCustomObject]@{
                        Instance      = $name
                        Url           = $url
                        Status        = "ERROR"
                        Response      = $null
                        Error         = $errmsg
                        SslThumbprint = $sslThumb
                        SslMatch      = $sslMatch
                    }
                    Write-Warning "    Errore: $errmsg"
                }
            }
            $results += $status
        }
    }

    return $results
}

Export-ModuleMember -Function Test-BCWebServices
