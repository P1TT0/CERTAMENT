function Update-BCServiceCert {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$NewThumbprint
    )

    Write-Host "`n Aggiornamento certificati nei servizi BC..."

    $results = @()

    try {
        $instances = Get-NAVServerInstance -ErrorAction Stop
    }
    catch {
        Write-Warning "️ Impossibile enumerare le istanze Business Central: $($_.Exception.Message)"
        return $null
    }

    foreach ($instance in $instances) {
        $name = $instance.ServerInstance
        Write-Host "`n️ Istanza: $name"

        $entry = [PSCustomObject]@{
            Instance        = $name
            PreviousThumb   = $null
            NewThumb        = $NewThumbprint
            Result          = 'NotProcessed'
            ErrorMessage    = $null
        }

        try {
            $currentThumb = Get-NAVServerConfiguration -ServerInstance $name -KeyName "ServicesCertificateThumbprint" -ErrorAction Stop

            $entry.PreviousThumb = $currentThumb

            if (-not $currentThumb) {
                Write-Host "   ℹ️ Nessun certificato configurato → salto."
                $entry.Result = 'NoThumbConfigured'
                $results += $entry
                continue
            }

            $currNorm = ($currentThumb -replace '\s','').ToUpper()
            $newNorm  = ($NewThumbprint -replace '\s','').ToUpper()

            if ($currNorm -eq $newNorm) {
                Write-Host "    Già aggiornato al certificato corretto."
                $entry.Result = 'AlreadyUpToDate'
                $results += $entry
                continue
            }

            Write-Host ("    Aggiorno thumbprint da [{0}] a [{1}]..." -f $currentThumb, $NewThumbprint)

            $setParams = @{
                ServerInstance = $name
                KeyName        = 'ServicesCertificateThumbprint'
                KeyValue       = $NewThumbprint
            }

            Set-NAVServerConfiguration @setParams -ErrorAction Stop

            Restart-NAVServerInstance -ServerInstance $name -ErrorAction Stop

            Write-Host "    Istanza aggiornata e riavviata con successo."
            $entry.Result = 'UpdatedAndRestarted'
            $results += $entry
        }
        catch {
            $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
            Write-Warning ("    Errore durante l'aggiornamento dell'istanza {0}: {1}" -f $name, $errMsg)
            $entry.Result = 'Error'
            $entry.ErrorMessage = $errMsg
            $results += $entry
            continue
        }
    }

    return $results
}


