function Update-BCServiceCert {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$NewThumbprint,

        # When provided, only update instances currently configured with this thumbprint.
        # Instances using a different certificate are left untouched (Result = 'Skipped').
        [Parameter(Mandatory = $false)]
        [string]$OldThumbprint = ""
    )

    Write-Host "Aggiornamento certificati nei servizi BC..."

    $results = @()
    $oldNorm = if ($OldThumbprint) { ($OldThumbprint -replace '\s', '').ToUpper() } else { "" }

    try {
        $instances = Get-NAVServerInstance -ErrorAction Stop
    }
    catch {
        Write-Warning "Impossibile enumerare le istanze Business Central: $($_.Exception.Message)"
        return $null
    }

    foreach ($instance in $instances) {
        $name = $instance.ServerInstance
        Write-Host "  Istanza: $name"

        $entry = [PSCustomObject]@{
            Instance      = $name
            PreviousThumb = $null
            NewThumb      = $NewThumbprint
            Result        = 'NotProcessed'
            ErrorMessage  = $null
        }

        # Skip disabled services (StartupType = Disabled)
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') {
                Write-Host "    Servizio disabilitato, salto."
                $entry.Result = 'DisabledSkipped'
                $results += $entry
                continue
            }
        }
        catch { }

        try {
            $currentThumb = Get-NAVServerConfiguration -ServerInstance $name -KeyName "ServicesCertificateThumbprint" -ErrorAction Stop
            $entry.PreviousThumb = $currentThumb

            if (-not $currentThumb) {
                Write-Host "    Nessun certificato configurato, salto."
                $entry.Result = 'NoThumbConfigured'
                $results += $entry
                continue
            }

            $currNorm = ($currentThumb -replace '\s', '').ToUpper()
            $newNorm = ($NewThumbprint -replace '\s', '').ToUpper()

            # If OldThumbprint filter is provided, skip instances using a different certificate.
            if ($oldNorm -and $currNorm -ne $oldNorm) {
                Write-Host ("    Certificato diverso ({0}), istanza non pertinente - salto." -f $currNorm)
                $entry.Result = 'Skipped'
                $results += $entry
                continue
            }

            if ($currNorm -eq $newNorm) {
                Write-Host "    Gia aggiornato."
                $entry.Result = 'AlreadyUpToDate'
                $results += $entry
                continue
            }

            Write-Host ("    Aggiorno thumbprint da [{0}] a [{1}]..." -f $currentThumb, $NewThumbprint)

            Set-NAVServerConfiguration -ServerInstance $name `
                -KeyName 'ServicesCertificateThumbprint' `
                -KeyValue $NewThumbprint `
                -ErrorAction Stop

            Restart-NAVServerInstance -ServerInstance $name -ErrorAction Stop

            Write-Host "    Istanza aggiornata e riavviata."
            $entry.Result = 'UpdatedAndRestarted'
            $results += $entry
        }
        catch {
            $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
            Write-Warning ("    Errore istanza {0}: {1}" -f $name, $errMsg)
            $entry.Result = 'Error'
            $entry.ErrorMessage = $errMsg
            $results += $entry
            continue
        }
    }

    return $results
}

Export-ModuleMember -Function Update-BCServiceCert
