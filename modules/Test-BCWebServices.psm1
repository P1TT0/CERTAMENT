function Test-BCWebServices {
    [CmdletBinding()]
    param (
        [int]$TimeoutSec = 10
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

    $results = @()

    foreach ($inst in $instances) {
        $name = $inst.ServerInstance
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
            try {
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
                $status = [PSCustomObject]@{
                    Instance = $name
                    Url      = $url
                    Status   = "OK"
                    Response = "$($resp.StatusCode) $($resp.StatusDescription)"
                    Error    = $null
                }
                Write-Host "    OK ($($resp.StatusCode))"
            }
            catch {
                $errmsg = $_.Exception.Message
                if ($errmsg -match '401|403') {
                    $status = [PSCustomObject]@{
                        Instance = $name
                        Url      = $url
                        Status   = "OK (Auth Required)"
                        Response = $errmsg
                        Error    = $null
                    }
                    Write-Host "    WS risponde (autenticazione richiesta)."
                }
                else {
                    $status = [PSCustomObject]@{
                        Instance = $name
                        Url      = $url
                        Status   = "ERROR"
                        Response = $null
                        Error    = $errmsg
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
