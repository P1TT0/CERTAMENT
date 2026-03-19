function Update-IISBinding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$NewThumbprint,

        [string]$SiteName = "Microsoft Dynamics 365 Business Central Web Client",

        [switch]$RestartIIS
    )

    if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "Microsoft.Web.Administration" })) {
        $dllPath = "C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll"
        if (Test-Path $dllPath) {
            [void][Reflection.Assembly]::LoadFrom($dllPath)
        }
        else {
            Write-Error "Microsoft.Web.Administration.dll non trovata. Verificare che IIS Management Tools sia installato."
            return
        }
    }

    $newNorm = ($NewThumbprint -replace '\s', '').ToUpper()

    Write-Host "Update-IISBinding: aggiornamento binding per '$SiteName'..."

    try {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop |
            Where-Object { ($_.Thumbprint -replace '\s', '').ToUpper() -eq $newNorm }
    }
    catch {
        Write-Error "Errore accesso store certificati: $($_.Exception.Message)"
        return
    }

    if (-not $cert) {
        Write-Error ("Certificato con thumbprint {0} non trovato in Cert:\LocalMachine\My" -f $newNorm)
        return
    }

    $newHash = $cert.GetCertHash()

    try {
        $sm = New-Object Microsoft.Web.Administration.ServerManager
    }
    catch {
        Write-Error "Impossibile creare ServerManager. Eseguire come Administrator con IIS installato."
        return
    }

    $site = $sm.Sites[$SiteName]
    if (-not $site) {
        Write-Warning ("Sito '{0}' non trovato in IIS." -f $SiteName)
        return
    }

    $results = @()

    foreach ($binding in $site.Bindings) {
        if ($binding.Protocol -ne 'https') { continue }

        $bindingInfo = $binding.BindingInformation
        $oldThumb = ""
        if ($binding.CertificateHash) {
            $oldThumb = ([System.BitConverter]::ToString($binding.CertificateHash) -replace '-', '').ToUpper()
        }

        $status = [PSCustomObject]@{
            Site     = $SiteName
            Binding  = $bindingInfo
            OldThumb = $oldThumb
            NewThumb = $newNorm
            Updated  = $false
            Result   = ""
        }

        if ($oldThumb -eq $newNorm) {
            $status.Result = "AlreadyUpToDate"
            Write-Host ("    Binding {0} gia aggiornato." -f $bindingInfo)
            $results += $status
            continue
        }

        try {
            Write-Host ("    Aggiorno binding {0}..." -f $bindingInfo)
            $binding.CertificateHash = $newHash
            $binding.CertificateStoreName = "My"
            $sm.CommitChanges()

            $status.Updated = $true
            $status.Result = "Updated"
            Write-Host "    Aggiornato."
        }
        catch {
            $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
            $status.Result = "Error: $errMsg"
            Write-Warning ("    Errore binding {0}: {1}" -f $bindingInfo, $errMsg)
        }

        $results += $status
    }

    if ($RestartIIS.IsPresent) {
        try {
            Write-Host "Riavvio IIS..."
            iisreset /noforce | Out-Null
            Write-Host "IIS riavviato."
        }
        catch {
            Write-Warning ("Errore durante iisreset: {0}" -f $_.Exception.Message)
        }
    }

    return $results
}

Export-ModuleMember -Function Update-IISBinding
