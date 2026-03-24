<#
.SYNOPSIS
    Selettore manuale certificato per CERTAMENT.
.DESCRIPTION
    Mostra i certificati presenti in Cert:\LocalMachine\My con chiave privata,
    permette di selezionarne uno da una lista e lo applica ai servizi
    Business Central e ai binding IIS usando i moduli gia presenti in CERTAMENT.
    Esegue anche una verifica finale di BC, IIS e servizi web.
.EXAMPLE
    .\Set-CertamentCertificate.ps1

.EXAMPLE
    .\Set-CertamentCertificate.ps1 -ListOnly

.EXAMPLE
    .\Set-CertamentCertificate.ps1 -SelectionIndex 2

.EXAMPLE
    # Forza installazione anche se il certificato e' scaduto (solo per test)
    .\Set-CertamentCertificate.ps1 -AllowExpired
#>
param(
    [string]$InstallRoot = (Split-Path -Parent $PSScriptRoot),
    [int]$SelectionIndex = 0,
    [switch]$ListOnly,
    [switch]$SkipWebServiceCheck,
    [switch]$AllowExpired,
    [int]$MaxWaitSec = 300
)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Eseguire lo script come Amministratore (Run As Administrator).'
    }
}

function Read-CertamentConfig {
    $configPath = Join-Path $InstallRoot 'config.json'
    if (-not (Test-Path $configPath)) {
        return [PSCustomObject]@{
            IIS = [PSCustomObject]@{
                SiteName = 'Microsoft Dynamics 365 Business Central Web Client'
                RestartAfterUpdate = $true
            }
        }
    }

    $raw = Get-Content $configPath -Raw
    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        $sanitized = (($raw -split "`r?`n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`r`n"
        return ($sanitized | ConvertFrom-Json)
    }
}

function Import-CertamentModule {
    param([string]$ModuleName)

    $modulePath = Join-Path $InstallRoot (Join-Path 'modules' ($ModuleName + '.psm1'))
    if (-not (Test-Path $modulePath)) {
        throw "Modulo non trovato: $modulePath"
    }

    Import-Module $modulePath -Force -ErrorAction Stop
}

function Import-BCModuleSafe {
    if (Get-Command Get-NAVServerInstance -ErrorAction SilentlyContinue) {
        return
    }

    $candidates = @(Get-ChildItem 'C:\Program Files\Microsoft Dynamics 365 Business Central' -Recurse -Filter 'Microsoft.Dynamics.Nav.Management.psm1' -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { if ($_.FullName -match '\\Admin\\') { 1 } else { 0 } } }, @{ Expression = 'LastWriteTime'; Descending = $true })

    if ($candidates.Count -eq 0) {
        throw 'Modulo Business Central non trovato.'
    }

    foreach ($candidate in $candidates) {
        try {
            Remove-Module Microsoft.Dynamics.Nav.Management -ErrorAction SilentlyContinue
            Import-Module $candidate.FullName -Force -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            if (Get-Command Get-NAVServerInstance -ErrorAction SilentlyContinue) {
                return
            }
        }
        catch {
        }
    }

    throw 'Impossibile importare il modulo Business Central.'
}

function Get-ConfiguredBCInstances {
    $entries = @()

    foreach ($instance in @(Get-NAVServerInstance)) {
        $thumb = $null
        try {
            $thumb = Get-NAVServerConfiguration -ServerInstance $instance.ServerInstance -KeyName 'ServicesCertificateThumbprint' -ErrorAction SilentlyContinue
        }
        catch {
        }

        $entries += [PSCustomObject]@{
            Instance   = $instance.ServerInstance
            State      = $instance.State
            Thumbprint = if ($thumb) { ($thumb -replace '\s', '').ToUpper() } else { '' }
        }
    }

    return $entries
}

function Get-CurrentIISThumbprint {
    param([string]$SiteName)

    if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Web.Administration' })) {
        $dllPath = 'C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll'
        if (Test-Path $dllPath) {
            [void][Reflection.Assembly]::LoadFrom($dllPath)
        }
    }

    $sm = New-Object Microsoft.Web.Administration.ServerManager
    $site = $sm.Sites[$SiteName]
    if (-not $site) {
        return $null
    }

    foreach ($binding in $site.Bindings) {
        if ($binding.Protocol -ne 'https') { continue }
        if (-not $binding.CertificateHash) { continue }

        return ([System.BitConverter]::ToString($binding.CertificateHash) -replace '-', '').ToUpper()
    }

    return $null
}

function Get-SelectableCertificates {
    param([string[]]$CurrentThumbprints)

    $now = Get-Date
    $certificates = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop |
        Where-Object { $_.HasPrivateKey } |
        Sort-Object @{ Expression = 'NotAfter'; Descending = $true }, @{ Expression = 'Subject'; Descending = $false })

    $items = @()
    $index = 1

    foreach ($certificate in $certificates) {
        $thumbprint = ($certificate.Thumbprint -replace '\s', '').ToUpper()
        $tags = @()

        if ($CurrentThumbprints -contains $thumbprint) { $tags += 'CURRENT' }
        if ($certificate.NotAfter -lt $now) { $tags += 'EXPIRED' }
        if ($certificate.NotBefore -gt $now) { $tags += 'NOT-YET-VALID' }

        $items += [PSCustomObject]@{
            Index        = $index
            Thumbprint   = $thumbprint
            NotAfter     = $certificate.NotAfter
            Subject      = $certificate.Subject
            FriendlyName = $certificate.FriendlyName
            Tags         = ($tags -join ', ')
        }
        $index++
    }

    return $items
}

function Show-CertificateList {
    param([object[]]$Certificates)

    Write-Host ''
    Write-Host 'Certificati disponibili in LocalMachine\My:' -ForegroundColor Cyan
    foreach ($certificate in $Certificates) {
        $line = ('[{0,2}] {1} | {2} | {3}' -f $certificate.Index, $certificate.NotAfter.ToString('yyyy-MM-dd'), $certificate.Thumbprint, $certificate.Subject)
        Write-Host $line
        if (-not [string]::IsNullOrWhiteSpace($certificate.FriendlyName)) {
            Write-Host ('     FriendlyName: {0}' -f $certificate.FriendlyName) -ForegroundColor DarkGray
        }
        if (-not [string]::IsNullOrWhiteSpace($certificate.Tags)) {
            Write-Host ('     Tag: {0}' -f $certificate.Tags) -ForegroundColor Yellow
        }
    }
}

function Resolve-SelectedCertificate {
    param(
        [object[]]$Certificates,
        [int]$SelectionIndex
    )

    if ($Certificates.Count -eq 0) {
        throw 'Nessun certificato selezionabile trovato in Cert:\LocalMachine\My.'
    }

    if ($SelectionIndex -gt 0) {
        $selected = @($Certificates | Where-Object { $_.Index -eq $SelectionIndex } | Select-Object -First 1)
        if ($selected.Count -eq 0) {
            throw "Indice non valido: $SelectionIndex"
        }
        return $selected[0]
    }

    while ($true) {
        $raw = Read-Host 'Seleziona il certificato da applicare (numero)'
        $value = 0
        if (-not [int]::TryParse($raw, [ref]$value)) {
            Write-Warning 'Inserire un numero valido.'
            continue
        }

        $selected = @($Certificates | Where-Object { $_.Index -eq $value } | Select-Object -First 1)
        if ($selected.Count -eq 0) {
            Write-Warning 'Indice non presente nella lista.'
            continue
        }

        return $selected[0]
    }
}

function Test-BCPostUpdate {
    param([string]$ExpectedThumbprint)

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $errors = @()

    foreach ($instance in @(Get-NAVServerInstance)) {
        $name = $instance.ServerInstance

        # Skip disabled services (StartupType = Disabled)
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') { continue }
        }
        catch { }

        $hasThumb = $false

        try {
            $thumb = Get-NAVServerConfiguration -ServerInstance $name -KeyName 'ServicesCertificateThumbprint' -ErrorAction Stop
            if ($thumb -and $thumb.Trim() -ne '') {
                $hasThumb = $true
                $thumbNorm = ($thumb -replace '\s', '').ToUpper()
                if ($thumbNorm -ne $expectedNorm) {
                    $errors += "$name : thumbprint $thumbNorm (atteso $expectedNorm)"
                }
            }
        }
        catch {
            $errors += "$name : errore lettura thumbprint - $($_.Exception.Message)"
        }

        if ($hasThumb -and $instance.State -and $instance.State -ne 'Running') {
            $errors += "$name : stato $($instance.State) (atteso Running)"
        }
    }

    return $errors
}

function Test-IISPostUpdate {
    param(
        [string]$ExpectedThumbprint,
        [string]$SiteName
    )

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $errors = @()

    if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Web.Administration' })) {
        $dllPath = 'C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll'
        if (Test-Path $dllPath) {
            [void][Reflection.Assembly]::LoadFrom($dllPath)
        }
        else {
            return @('Microsoft.Web.Administration.dll non trovata')
        }
    }

    $sm = New-Object Microsoft.Web.Administration.ServerManager
    $site = $sm.Sites[$SiteName]
    if (-not $site) {
        return @("Sito '$SiteName' non trovato in IIS")
    }

    foreach ($binding in $site.Bindings) {
        if ($binding.Protocol -ne 'https') { continue }

        $bindingInfo = $binding.BindingInformation
        if ($binding.CertificateHash) {
            $currentThumb = ([System.BitConverter]::ToString($binding.CertificateHash) -replace '-', '').ToUpper()
            if ($currentThumb -ne $expectedNorm) {
                $errors += "Binding $bindingInfo : thumbprint $currentThumb (atteso $expectedNorm)"
            }
        }
        else {
            $errors += "Binding $bindingInfo : nessun certificato associato"
        }
    }

    return $errors
}

function Wait-ForWebServicesManual {
    param(
        [string]$ExpectedThumbprint,
        [int]$MaxWaitSec
    )

    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        Write-Host ("Verifica servizi web (tentativo {0}, max {1}s)..." -f $attempt, $MaxWaitSec)
        $results = Test-BCWebServices -TimeoutSec 15 -ExpectedThumbprint $ExpectedThumbprint
        if ($results) {
            $errors = @($results | Where-Object { $_.Status -eq 'ERROR' })
            $sslMismatches = @($results | Where-Object { $_.SslMatch -eq $false })
            if ($errors.Count -eq 0 -and $sslMismatches.Count -eq 0) {
                return [PSCustomObject]@{
                    Results = $results
                    Errors = @()
                    Success = $true
                }
            }
        }

        if ((Get-Date).AddSeconds(20) -ge $deadline) { break }
        Start-Sleep -Seconds 20
    }

    $finalResults = Test-BCWebServices -TimeoutSec 15 -ExpectedThumbprint $ExpectedThumbprint
    $finalErrors = @()
    if ($finalResults) {
        $finalErrors += @($finalResults | Where-Object { $_.Status -eq 'ERROR' } | ForEach-Object { "$($_.Instance) [$($_.Url)]: $($_.Error)" })
        $finalErrors += @($finalResults | Where-Object { $_.SslMatch -eq $false } | ForEach-Object { "$($_.Instance) [$($_.Url)]: SSL cert $($_.SslThumbprint) (atteso $ExpectedThumbprint)" })
    }
    else {
        $finalErrors += 'Test-BCWebServices non ha restituito risultati.'
    }

    return [PSCustomObject]@{
        Results = $finalResults
        Errors = $finalErrors
        Success = ($finalErrors.Count -eq 0)
    }
}

Assert-Admin

$config = Read-CertamentConfig
$iisSiteName = if ($config.IIS -and $config.IIS.SiteName) { [string]$config.IIS.SiteName } else { 'Microsoft Dynamics 365 Business Central Web Client' }
$restartIIS = $true
if ($config.IIS -and $null -ne $config.IIS.RestartAfterUpdate) {
    $restartIIS = [bool]$config.IIS.RestartAfterUpdate
}

Import-CertamentModule -ModuleName 'Update-BCServiceCert'
Import-CertamentModule -ModuleName 'Update-IISBinding'
Import-CertamentModule -ModuleName 'Test-BCWebServices'
Import-BCModuleSafe

$bcInstances = Get-ConfiguredBCInstances
$currentThumbs = @($bcInstances | Where-Object { $_.Thumbprint } | Select-Object -ExpandProperty Thumbprint -Unique)
$currentIisThumb = Get-CurrentIISThumbprint -SiteName $iisSiteName
if ($currentIisThumb) {
    $currentThumbs += $currentIisThumb
    $currentThumbs = @($currentThumbs | Select-Object -Unique)
}

Write-Host ''
Write-Host 'Stato corrente:' -ForegroundColor Cyan
$bcInstances | Format-Table -AutoSize
Write-Host ("IIS site: {0}" -f $iisSiteName)
Write-Host ("IIS thumbprint corrente: {0}" -f $(if ($currentIisThumb) { $currentIisThumb } else { '(non rilevato)' }))

$certificates = Get-SelectableCertificates -CurrentThumbprints $currentThumbs
Show-CertificateList -Certificates $certificates

if ($ListOnly.IsPresent) {
    return
}

$selected = Resolve-SelectedCertificate -Certificates $certificates -SelectionIndex $SelectionIndex

Write-Host ''
Write-Host 'Certificato selezionato:' -ForegroundColor Cyan
Write-Host ("  Subject    : {0}" -f $selected.Subject)
Write-Host ("  Thumbprint : {0}" -f $selected.Thumbprint)
Write-Host ("  Scadenza   : {0}" -f $selected.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'))

# Block expired cert unless -AllowExpired is explicitly passed
if ($selected.NotAfter -lt (Get-Date)) {
    Write-Host ''
    Write-Host '!! ATTENZIONE: Il certificato selezionato e'' GIA'' SCADUTO !!' -ForegroundColor Red
    Write-Host ("   Scaduto il: {0}" -f $selected.NotAfter.ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor Red
    if (-not $AllowExpired.IsPresent) {
        Write-Host '   Operazione bloccata. Usare -AllowExpired per forzare (solo per test).' -ForegroundColor Red
        return
    }
    Write-Warning 'Flag -AllowExpired presente. Procedura forzata nonostante certificato scaduto.'
}

$confirm = Read-Host 'Confermi applicazione a BC + IIS? [S/N]'
if ($confirm.Trim().ToUpper() -notin @('S', 'SI', 'Y', 'YES')) {
    Write-Host 'Operazione annullata.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host 'Aggiornamento Business Central...' -ForegroundColor Cyan
$bcResults = Update-BCServiceCert -NewThumbprint $selected.Thumbprint
if ($bcResults) { $bcResults | Format-Table -AutoSize }

Write-Host ''
Write-Host 'Aggiornamento IIS...' -ForegroundColor Cyan
$iisResults = Update-IISBinding -NewThumbprint $selected.Thumbprint -SiteName $iisSiteName -RestartIIS:$restartIIS
if ($iisResults) { $iisResults | Format-Table -AutoSize }

Write-Host ''
Write-Host 'Verifica finale...' -ForegroundColor Cyan
Start-Sleep -Seconds 15

$bcErrors = Test-BCPostUpdate -ExpectedThumbprint $selected.Thumbprint
$iisErrors = Test-IISPostUpdate -ExpectedThumbprint $selected.Thumbprint -SiteName $iisSiteName

$wsCheck = $null
if (-not $SkipWebServiceCheck.IsPresent) {
    $wsCheck = Wait-ForWebServicesManual -ExpectedThumbprint $selected.Thumbprint -MaxWaitSec $MaxWaitSec
}

$allErrors = @()
$allErrors += $bcErrors
$allErrors += $iisErrors
if ($wsCheck -and -not $wsCheck.Success) {
    $allErrors += $wsCheck.Errors
}

if ($wsCheck -and $wsCheck.Results) {
    Write-Host ''
    $wsCheck.Results | Format-Table -AutoSize
}

Write-Host ''
if ($allErrors.Count -eq 0) {
    Write-Host 'Applicazione completata con successo.' -ForegroundColor Green
}
else {
    Write-Host 'Applicazione completata con errori da verificare:' -ForegroundColor Red
    $allErrors | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Red }
    exit 1
}