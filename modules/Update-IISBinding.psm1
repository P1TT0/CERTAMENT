
function Update-IISBinding {



    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$NewThumbprint,

        [switch]$RestartIIS
    )
if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "Microsoft.Web.Administration" })) {
    $dllPath = "C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll"
    if (Test-Path $dllPath) {
        [void][Reflection.Assembly]::LoadFrom($dllPath)
    } else {
        Write-Error " Microsoft.Web.Administration.dll non trovata in $dllPath. Assicurati che IIS Management Tools sia installato."
        return
    }
}


    $newNorm = ($NewThumbprint -replace '\s','').ToUpper()

    Write-Host "`n Update-IISBinding: avvio aggiornamento binding per Business Central..." -ForegroundColor Cyan

    try {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop |
                Where-Object { ($_.Thumbprint -replace '\s','').ToUpper() -eq $newNorm }
    } catch {
        Write-Error " Errore accesso store certificati: $($_.Exception.Message)"
        return
    }

    if (-not $cert) {
        Write-Error (" Certificato con thumbprint {0} non trovato in Cert:\LocalMachine\My" -f $newNorm)
        return
    }

    $newHash = $cert.GetCertHash()

    try {
        $sm = New-Object Microsoft.Web.Administration.ServerManager
    } catch {
        Write-Error " Impossibile creare ServerManager (Microsoft.Web.Administration). Assicurati di eseguire come Administrator e che IIS sia installato."
        return
    }

    $siteName = "Microsoft Dynamics 365 Business Central Web Client"
    $site = $sm.Sites[$siteName]

    if (-not $site) {
        Write-Warning ("️ Sito '{0}' non trovato in IIS. Verifica il nome del sito." -f $siteName)
        return
    }

    $results = @()

    foreach ($binding in $site.Bindings) {
        if ($binding.Protocol -ne 'https') { continue }

        $bindingInfo = $binding.BindingInformation

        $oldThumb = ""
        if ($binding.CertificateHash) {
            $oldThumb = ([System.BitConverter]::ToString($binding.CertificateHash) -replace '-','').ToUpper()
        }

        $status = [PSCustomObject]@{
            Site      = $siteName
            Binding   = $bindingInfo
            OldThumb  = $oldThumb
            NewThumb  = $newNorm
            Updated   = $false
            Result    = ""
        }

        if ($oldThumb -eq $newNorm) {
            $status.Result = "AlreadyUpToDate"
            Write-Host ("    Binding {0} già aggiornato (thumb {1})." -f $bindingInfo, $newNorm)
            $results += $status
            continue
        }

        try {
            Write-Host ("    Aggiorno binding {0} (old: {1})..." -f $bindingInfo, ($oldThumb -ne "" ? $oldThumb : "<none>"))

            $binding.CertificateHash = $newHash
            $binding.CertificateStoreName = "My"

            $sm.CommitChanges()

            $status.Updated = $true
            $status.Result  = "Updated"
            Write-Host "    Aggiornato con successo."
        }
        catch {
            $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
            $status.Result = "Error: $errMsg"
            Write-Warning ("    Errore aggiornamento binding {0}: {1}" -f $bindingInfo, $errMsg)
        }

        $results += $status
    }

    if ($RestartIIS.IsPresent) {
        try {
            Write-Host "`n️ Riavvio IIS..."
            iisreset /noforce | Out-Null
            Write-Host " IIS riavviato."
        } catch {
            Write-Warning ("️ Errore durante iisreset: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Host "`nℹ️ Nota: se le applicazioni non vedono immediatamente il nuovo certificato, valuta un riavvio mirato dell'app pool o 'iisreset'."
    }

    Write-Host "`n Update-IISBinding: completato."
    return $results
}

Export-ModuleMember -Function Update-IISBinding

