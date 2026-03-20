<#
.SYNOPSIS
    CERTAMENT E2E Tester - testa l'intero ciclo di aggiornamento certificati.
.DESCRIPTION
    RunFull (default): esegue il test completo in autonomia.
    Status           : mostra lo stato corrente (task, BC/IIS thumbprint, drop folder).
    Restore          : ripristino di emergenza BC/IIS al certificato originale.
    Help             : mostra questo messaggio.
.EXAMPLE
    .\Certament-E2E-Tester.ps1
    .\Certament-E2E-Tester.ps1 -SecretFilePath C:\temp\pfxpwd.txt
    .\Certament-E2E-Tester.ps1 -Action Status
    .\Certament-E2E-Tester.ps1 -Action Restore
#>
param(
    [ValidateSet('RunFull', 'Status', 'Restore', 'Help')]
    [string]$Action = 'RunFull',

    # Cartella di installazione CERTAMENT
    [string]$InstallRoot = 'C:\CERTAMENT',

    # File .txt con la password dei PFX E2E (plain text, una riga).
    # Se omesso, viene usato config.Pfx.Password e in ultima istanza chiesta interattivamente.
    [string]$SecretFilePath = '',

    # PFX baseline del test E2E realistico (stato iniziale simulato).
    [string]$BaselinePfxPath = 'C:\_install\e2e2_bak\2026CERT.pfx',

    # PFX di aggiornamento del test E2E realistico (nuovo certificato atteso).
    [string]$UpdatePfxPath = 'C:\_install\e2e2_bak\2027CERT.pfx'
)

$ErrorActionPreference = 'Stop'

# =============================================================
# Helpers interni
# =============================================================

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Eseguire lo script come Amministratore (Run As Administrator).'
    }
}

function Read-CertamentConfig {
    $cp = Join-Path $InstallRoot 'config.json'
    if (-not (Test-Path $cp)) { throw "config.json non trovato: $cp" }
    return (Get-Content $cp -Raw | ConvertFrom-Json), $cp
}

function Resolve-PfxPassword {
    param(
        [string]$SecretFilePath,
        [string]$ConfigPassword = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($SecretFilePath) -and (Test-Path $SecretFilePath)) {
        return [PSCustomObject]@{
            Password = (Get-Content $SecretFilePath -Raw -ErrorAction Stop).Trim()
            Source   = "file: $SecretFilePath"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ConfigPassword)) {
        return [PSCustomObject]@{
            Password = $ConfigPassword.Trim()
            Source   = 'config.json: Pfx.Password'
        }
    }

    $secure = Read-Host 'Password PFX E2E' -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [PSCustomObject]@{
            Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            Source   = 'prompt interattivo'
        }
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Get-PfxCertificateInfo {
    param(
        [string]$PfxPath,
        [string]$Password
    )

    if (-not (Test-Path $PfxPath)) {
        throw "PFX non trovato: $PfxPath"
    }
    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw "Password PFX mancante per: $PfxPath"
    }

    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $pfxData = Get-PfxData -FilePath $PfxPath -Password $secure
    $cert = @($pfxData.EndEntityCertificates | Select-Object -First 1)
    if ($cert.Count -eq 0) {
        throw "Nessun certificato end-entity trovato nel PFX: $PfxPath"
    }

    return [PSCustomObject]@{
        Path       = $PfxPath
        Name       = Split-Path -Leaf $PfxPath
        Subject    = $cert[0].Subject
        Thumbprint = $cert[0].Thumbprint.ToUpper()
        NotAfter   = $cert[0].NotAfter
    }
}

function Ensure-CertFromPfxInStore {
    param(
        [string]$PfxPath,
        [string]$Password,
        [string]$ExpectedThumbprint
    )

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $existing = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        ($_.Thumbprint -replace '\s', '').ToUpper() -eq $expectedNorm
    } | Select-Object -First 1)

    if ($existing.Count -gt 0) {
        return [PSCustomObject]@{
            Thumbprint = $expectedNorm
            Imported   = $false
        }
    }

    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $imported = Import-PfxCertificate -FilePath $PfxPath -CertStoreLocation Cert:\LocalMachine\My -Password $secure -Exportable
    $importedThumb = ($imported.Thumbprint -replace '\s', '').ToUpper()
    if ($importedThumb -ne $expectedNorm) {
        throw ("Thumbprint importato inatteso per {0}: {1}" -f $PfxPath, $importedThumb)
    }

    return [PSCustomObject]@{
        Thumbprint = $expectedNorm
        Imported   = $true
    }
}

function Import-BCModuleSafe {
    if (Get-Command Get-NAVServerInstance -ErrorAction SilentlyContinue) { return }
    $candidates = @(
        Get-ChildItem 'C:\Program Files\Microsoft Dynamics 365 Business Central' `
            -Recurse -Filter 'Microsoft.Dynamics.Nav.Management.psm1' -ErrorAction SilentlyContinue |
        Sort-Object @{ Expression = { if ($_.FullName -match '\\Admin\\') { 1 } else { 0 } } },
                    @{ Expression = 'LastWriteTime'; Descending = $true }
    )
    if ($candidates.Count -eq 0) { throw 'Modulo BC Nav.Management non trovato.' }
    foreach ($c in $candidates) {
        try {
            Remove-Module Microsoft.Dynamics.Nav.Management -ErrorAction SilentlyContinue
            Import-Module $c.FullName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            if (Get-Command Get-NAVServerInstance -ErrorAction SilentlyContinue) { return }
        } catch {}
    }
    throw 'Impossibile importare il modulo BC.'
}

function Get-LiveBCThumbprint {
    foreach ($inst in @(Get-NAVServerInstance)) {
        try {
            $t = Get-NAVServerConfiguration -ServerInstance $inst.ServerInstance `
                 -KeyName ServicesCertificateThumbprint -ErrorAction SilentlyContinue
            if ($t -and $t.Trim() -ne '') { return $t.Trim().ToUpper() }
        } catch {}
    }
    return $null
}

function Get-LiveIISThumbprint {
    param([string]$SiteName)
    try {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $b = @(Get-WebBinding -Name $SiteName -Protocol https -ErrorAction SilentlyContinue)
        if ($b.Count -eq 0) { return $null }
        $h = ($b[0].certificateHash -replace '[^0-9A-Fa-f]', '').ToUpper()
        if ($h -ne '') { return $h }
    } catch {}
    return $null
}

function Set-BCThumbprint {
    param([string]$Thumbprint)
    $norm = $Thumbprint.ToUpper()
    foreach ($inst in @(Get-NAVServerInstance)) {
        try {
            $curr = Get-NAVServerConfiguration -ServerInstance $inst.ServerInstance `
                    -KeyName ServicesCertificateThumbprint -ErrorAction SilentlyContinue
            if (-not $curr -or $curr.Trim() -eq '') {
                Write-Host ("    {0}: skip (nessun thumbprint configurato)." -f $inst.ServerInstance) -ForegroundColor Gray
                continue
            }
            if (($curr -replace '\s','').ToUpper() -eq $norm) {
                Write-Host ("    {0}: gia aggiornato." -f $inst.ServerInstance) -ForegroundColor Gray
                continue
            }
            Set-NAVServerConfiguration -ServerInstance $inst.ServerInstance `
                -KeyName ServicesCertificateThumbprint -KeyValue $norm -ErrorAction Stop
            Restart-NAVServerInstance -ServerInstance $inst.ServerInstance -ErrorAction Stop
            Write-Host ("    {0}: aggiornato e riavviato." -f $inst.ServerInstance) -ForegroundColor Green
        } catch {
            Write-Warning ("    {0}: errore: {1}" -f $inst.ServerInstance, $_.Exception.Message)
        }
    }
}

function Set-IISThumbprint {
    param([string]$Thumbprint, [string]$SiteName)
    $norm = $Thumbprint.ToUpper()
    $dll  = 'C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll'
    if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.Web.Administration' })) {
        [void][Reflection.Assembly]::LoadFrom($dll)
    }
    $cert = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint.ToUpper() -eq $norm })
    if ($cert.Count -eq 0) { throw "Certificato $norm non trovato in LocalMachine\My" }
    $sm   = New-Object Microsoft.Web.Administration.ServerManager
    $site = $sm.Sites[$SiteName]
    if (-not $site) { throw "Sito IIS non trovato: $SiteName" }
    foreach ($b in $site.Bindings) {
        if ($b.Protocol -ne 'https') { continue }
        $b.CertificateHash      = $cert[0].GetCertHash()
        $b.CertificateStoreName = 'My'
    }
    $sm.CommitChanges()
    Write-Host ("    IIS binding -> $norm") -ForegroundColor Green
}

function Test-WebServicesHealth {
    param([string]$ExpectedThumbprint = '')
    $modulePath = Join-Path $InstallRoot 'modules\Test-BCWebServices.psm1'
    if (-not (Test-Path $modulePath)) {
        Write-Warning "Modulo Test-BCWebServices non trovato: $modulePath"
        return $null
    }
    Import-Module $modulePath -Force -ErrorAction SilentlyContinue
    if (-not (Get-Command Test-BCWebServices -ErrorAction SilentlyContinue)) {
        Write-Warning 'Funzione Test-BCWebServices non disponibile.'
        return $null
    }
    $wsParams = @{ TimeoutSec = 15 }
    if ($ExpectedThumbprint) { $wsParams['ExpectedThumbprint'] = $ExpectedThumbprint }
    $results = Test-BCWebServices @wsParams
    return $results
}

function Wait-ForWebServicesE2E {
    param(
        [int]$MaxWaitSec = 600,
        [int]$IntervalSec = 30,
        [string]$ExpectedThumbprint = ''
    )
    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        Write-Host ("    Polling WS (tentativo {0}, max {1}s)..." -f $attempt, $MaxWaitSec)
        $results = Test-WebServicesHealth -ExpectedThumbprint $ExpectedThumbprint
        if ($results) {
            $errors = @($results | Where-Object { $_.Status -eq 'ERROR' })
            $sslMismatches = @($results | Where-Object { $_.SslMatch -eq $false })
            if ($errors.Count -eq 0 -and $sslMismatches.Count -eq 0) {
                return $results
            }
            if ($errors.Count -gt 0) {
                $errSummary = ($errors | ForEach-Object { "$($_.Instance): $($_.Error)" }) -join '; '
                Write-Host "    Non ancora pronti: $errSummary"
            }
            if ($sslMismatches.Count -gt 0) {
                $sslSummary = ($sslMismatches | ForEach-Object { "$($_.Instance): SSL $($_.SslThumbprint)" }) -join '; '
                Write-Host "    SSL mismatch: $sslSummary"
            }
        }
        if ((Get-Date).AddSeconds($IntervalSec) -ge $deadline) { break }
        Start-Sleep -Seconds $IntervalSec
    }
    return $results
}

function Write-Phase { param([string]$Text) Write-Host ("`n=== $Text ===") -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host ("  [OK] $Text") -ForegroundColor Green }
function Write-Fail  { param([string]$Text) Write-Host ("  [!!] $Text") -ForegroundColor Red }

# =============================================================
# Action: Status
# =============================================================
function Invoke-Status {
    Write-Phase 'TASK'
    $task = Get-ScheduledTask -TaskName 'CERTAMENT' -ErrorAction SilentlyContinue
    $info = Get-ScheduledTaskInfo -TaskName 'CERTAMENT' -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host ("  Stato    : {0}" -f $task.State)
        Write-Host ("  Ultimo   : {0}" -f $info.LastRunTime)
        Write-Host ("  Prossimo : {0}" -f $info.NextRunTime)
        Write-Host ("  Codice   : {0}" -f $info.LastTaskResult)
    } else { Write-Warning '  Task CERTAMENT non trovato.' }

    Write-Phase 'CONFIG'
    $cfg, $_ = Read-CertamentConfig
    $cust = if ($cfg.Context -and $cfg.Context.CustomerName) { $cfg.Context.CustomerName } else { '(non impostato)' }
    Write-Host ("  Cliente          : {0}" -f $cust)
    Write-Host ("  NotifyBeforeDays : {0}" -f $cfg.Notifications.CertificateExpiry.NotifyBeforeDays)
    Write-Host ("  Pfx.Path         : {0}" -f $cfg.Pfx.Path)

    Write-Phase 'DROP FOLDER'
    $drop  = $cfg.Pfx.Path
    $pfxs  = @(Get-ChildItem $drop -Filter '*.pfx' -File -ErrorAction SilentlyContinue)
    if ($pfxs.Count -eq 0) { Write-Host '  (nessun PFX in drop folder)' -ForegroundColor Gray }
    else { $pfxs | ForEach-Object { Write-Host ("  {0}  [{1}]" -f $_.Name, $_.LastWriteTime) } }
    Write-Host ("  password.txt: {0}" -f $(if (Test-Path (Join-Path $drop 'password.txt')) { 'PRESENTE' } else { 'assente' }))

    Write-Phase 'THUMBPRINTS BC + IIS'
    Import-BCModuleSafe
    foreach ($inst in @(Get-NAVServerInstance)) {
        $t = Get-NAVServerConfiguration -ServerInstance $inst.ServerInstance `
             -KeyName ServicesCertificateThumbprint -ErrorAction SilentlyContinue
        Write-Host ("  {0,-12} -> {1}" -f $inst.ServerInstance, $t)
    }
    $iisSite = if ($cfg.IIS -and $cfg.IIS.SiteName) { $cfg.IIS.SiteName } else { 'Microsoft Dynamics 365 Business Central Web Client' }
    $iisT = Get-LiveIISThumbprint -SiteName $iisSite
    Write-Host ("  IIS :443      -> {0}" -f $(if ($iisT) { $iisT } else { '(non rilevato)' }))
    Write-Host ''
}

# =============================================================
# Action: Restore (emergenza)
# =============================================================
function Invoke-Restore {
    Assert-Admin
    Write-Phase 'RESTORE EMERGENZA'
    $cfg, $configPath = Read-CertamentConfig
    Import-BCModuleSafe
    $currentThumb = Get-LiveBCThumbprint
    Write-Host "  Thumbprint BC attuale: $currentThumb"

    $targetInput = Read-Host 'Thumbprint da ripristinare (invio = auto-rileva da store)'
    if ([string]::IsNullOrWhiteSpace($targetInput)) {
        $others = @(Get-ChildItem Cert:\LocalMachine\My |
                    Where-Object { $_.Thumbprint.ToUpper() -ne [string]$currentThumb })
        if ($others.Count -eq 1) {
            $targetThumb = $others[0].Thumbprint.ToUpper()
            Write-Host "  Auto-rilevato: $targetThumb  ($($others[0].Subject))"
        } else {
            Write-Host ''
            Write-Host '  Certificati disponibili in LocalMachine\My:'
            Get-ChildItem Cert:\LocalMachine\My | ForEach-Object {
                Write-Host ("    {0}  {1}  {2}" -f $_.Thumbprint, $_.NotAfter.ToString('yyyy-MM-dd'), $_.Subject)
            }
            throw 'Piu certificati trovati - specificare il thumbprint manualmente.'
        }
    } else {
        $targetThumb = $targetInput.Trim().ToUpper()
    }

    $iisSite = if ($cfg.IIS -and $cfg.IIS.SiteName) { $cfg.IIS.SiteName } else { 'Microsoft Dynamics 365 Business Central Web Client' }

    Write-Phase 'BC'
    Set-BCThumbprint -Thumbprint $targetThumb

    Write-Phase 'IIS'
    Set-IISThumbprint -Thumbprint $targetThumb -SiteName $iisSite
    iisreset /restart | Out-Null

    Write-Phase 'Config'
    $backups = @(Get-ChildItem $InstallRoot -Filter 'config.json.e2e_backup_*' -File |
                 Sort-Object LastWriteTime -Descending)
    if ($backups.Count -gt 0) {
        Copy-Item $backups[0].FullName $configPath -Force
        Write-Ok "Config ripristinato da: $($backups[0].Name)"
    } else {
        Write-Warning 'Nessun backup config trovato - config non ripristinato.'
    }
    Write-Ok 'Restore completato.'
}

# =============================================================
# Action: RunFull (default)
# =============================================================
function Invoke-RunFull {
    Assert-Admin

    Write-Host ''
    Write-Host '+--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '|    CERTAMENT E2E TEST - esecuzione completa      |' -ForegroundColor Cyan
    Write-Host '+--------------------------------------------------+' -ForegroundColor Cyan

    # ── 1. Leggi config ──────────────────────────────────────
    Write-Phase '1/7 - Lettura config'
    $cfg, $configPath = Read-CertamentConfig
    $pfxDrop    = $cfg.Pfx.Path
    $iisSite    = if ($cfg.IIS -and $cfg.IIS.SiteName) { $cfg.IIS.SiteName } `
                  else { 'Microsoft Dynamics 365 Business Central Web Client' }
    $mainScript = Join-Path $InstallRoot '_MAINCertManager.ps1'
    if (-not (Test-Path $mainScript)) { throw "_MAINCertManager.ps1 non trovato in $InstallRoot" }
    Write-Ok "Drop  : $pfxDrop"
    Write-Ok "IIS   : $iisSite"
    Write-Ok "Script: $mainScript"

    # ── 2. Modulo BC ─────────────────────────────────────────
    Write-Phase '2/7 - Modulo BC'
    Import-BCModuleSafe
    Write-Ok 'Modulo BC caricato.'

    # ── 3. Stato live iniziale ───────────────────────────────
    Write-Phase '3/7 - Stato live iniziale'
    $originalThumb = Get-LiveBCThumbprint
    if (-not $originalThumb) { throw 'Impossibile rilevare il thumbprint corrente da BC.' }
    Write-Ok "Thumbprint live iniziale: $originalThumb"

    # ── 4. Password + PFX reali ──────────────────────────────
    Write-Phase '4/7 - Password + PFX reali'
    $passwordInfo = Resolve-PfxPassword -SecretFilePath $SecretFilePath -ConfigPassword $cfg.Pfx.Password
    $secretPlain = [string]$passwordInfo.Password
    if ([string]::IsNullOrWhiteSpace($secretPlain)) { throw 'Password PFX non fornita.' }
    Write-Ok "Password risolta da: $($passwordInfo.Source)"

    $baselinePfx = Get-PfxCertificateInfo -PfxPath $BaselinePfxPath -Password $secretPlain
    $updatePfx = Get-PfxCertificateInfo -PfxPath $UpdatePfxPath -Password $secretPlain
    if ($baselinePfx.NotAfter -ge $updatePfx.NotAfter) {
        throw "Il PFX target non e' piu recente del baseline: $($baselinePfx.Name) -> $($updatePfx.Name)"
    }
    Write-Ok ("Baseline PFX: {0} | {1} | {2}" -f $baselinePfx.Name, $baselinePfx.Thumbprint, $baselinePfx.NotAfter.ToString('yyyy-MM-dd'))
    Write-Ok ("Target PFX  : {0} | {1} | {2}" -f $updatePfx.Name, $updatePfx.Thumbprint, $updatePfx.NotAfter.ToString('yyyy-MM-dd'))
    if ($originalThumb -ne $baselinePfx.Thumbprint) {
        Write-Host ("  Nota: lo stato live corrente non coincide col baseline E2E ({0}). A fine test verra ripristinato il thumbprint originale." -f $baselinePfx.Thumbprint) -ForegroundColor Yellow
    }

    $configBackup = $null
    $configOriginalRaw = $null
    $destPfx = $null
    $destPfxInstalled = $null
    $destPwd = $null
    $baselineImported = $false
    $updateImported = $false
    $newBCThumb = $null
    $newIISThumb = $null
    $bcOk = $false
    $iisOk = $false
    $wsPostChangeOk = $true
    $wsPostRestoreOk = $true
    $configRestored = $false
    $runError = $null

    try {
        # ── 5. Preparazione ──────────────────────────────────────
        Write-Phase '5/7 - Preparazione'
        $stamp        = Get-Date -Format 'yyyyMMdd_HHmmss'
        $configBackup = "$configPath.e2e_backup_$stamp"
        $configOriginalRaw = Get-Content $configPath -Raw
        Copy-Item $configPath $configBackup -Force
        Write-Ok "Config backup: $configBackup"

        $cfgObj = $configOriginalRaw | ConvertFrom-Json
        $cfgObj.Notifications.CertificateExpiry.NotifyBeforeDays = 9999
        $cfgObj | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
        Write-Ok 'NotifyBeforeDays = 9999 (forza aggiornamento).'

        $baselineEnsure = Ensure-CertFromPfxInStore -PfxPath $baselinePfx.Path -Password $secretPlain -ExpectedThumbprint $baselinePfx.Thumbprint
        $baselineImported = $baselineEnsure.Imported
        if ($baselineImported) {
            Write-Ok "Baseline importato in LocalMachine\\My."
        }

        $updateEnsure = Ensure-CertFromPfxInStore -PfxPath $updatePfx.Path -Password $secretPlain -ExpectedThumbprint $updatePfx.Thumbprint
        $updateImported = $updateEnsure.Imported
        if ($updateImported) {
            Write-Ok "Target importato in LocalMachine\\My."
        }

        Write-Host '  Allineo BC/IIS al baseline E2E...' -ForegroundColor Yellow
        Set-BCThumbprint -Thumbprint $baselinePfx.Thumbprint
        Set-IISThumbprint -Thumbprint $baselinePfx.Thumbprint -SiteName $iisSite
        iisreset /restart | Out-Null
        Start-Sleep -Seconds 15
        Write-Ok 'BC e IIS allineati al certificato baseline.'

        # Drop PFX target reale + password.txt
        $destPfx = Join-Path $pfxDrop $updatePfx.Name
        $destPfxInstalled = Join-Path (Join-Path $pfxDrop 'installed') (Split-Path -Path $destPfx -Leaf)
        $destPwd = Join-Path $pfxDrop 'password.txt'
        Copy-Item $updatePfx.Path $destPfx -Force
        Set-Content $destPwd -Value $secretPlain -Encoding UTF8 -NoNewline
        Write-Ok "PFX target in drop: $destPfx"
        Write-Ok 'password.txt creata.'

        # ── 6. Esecuzione CERTAMENT ──────────────────────────────
        Write-Phase '6/7 - Esecuzione CERTAMENT'
        Write-Host ''
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript
        $exitCode = $LASTEXITCODE
        Write-Host ''
        Write-Host ("  Exit code: $exitCode") -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } else { 'Yellow' })

        # ── 7. Verifica cambiamento ──────────────────────────────
        Write-Phase '7/7 - Verifica cambiamento'
        Import-BCModuleSafe
        $newBCThumb  = Get-LiveBCThumbprint
        $newIISThumb = Get-LiveIISThumbprint -SiteName $iisSite
        $bcOk  = ($newBCThumb  -and $newBCThumb.ToUpper()  -eq $updatePfx.Thumbprint)
        $iisOk = ($newIISThumb -and $newIISThumb.ToUpper() -eq $updatePfx.Thumbprint)

        Write-Host ''
        Write-Host '  live iniziale -> ' -NoNewline; Write-Host $originalThumb -ForegroundColor Gray
        Write-Host '  baseline E2E  -> ' -NoNewline; Write-Host $baselinePfx.Thumbprint -ForegroundColor Gray
        Write-Host '  target E2E    -> ' -NoNewline; Write-Host $updatePfx.Thumbprint -ForegroundColor Gray
        Write-Host ("  BC            -> {0}  {1}" -f $newBCThumb,  $(if ($bcOk)  { '[TARGET OK]' } else { '[TARGET NON APPLICATO]' })) `
            -ForegroundColor $(if ($bcOk)  { 'Green' } else { 'Red' })
        Write-Host ("  IIS           -> {0}  {1}" -f $newIISThumb, $(if ($iisOk) { '[TARGET OK]' } else { '[TARGET NON APPLICATO]' })) `
            -ForegroundColor $(if ($iisOk) { 'Green' } else { 'Red' })

        # Web services post-change (polling fino a 10 min con verifica SSL)
        Write-Host ''
        Write-Host '  Attesa servizi web post-aggiornamento (fino a 10 min)...'
        $wsPostChange = Wait-ForWebServicesE2E -MaxWaitSec 600 -IntervalSec 30 -ExpectedThumbprint $updatePfx.Thumbprint
        if ($wsPostChange) {
            $wsPostErrors = @($wsPostChange | Where-Object { $_.Status -eq 'ERROR' })
            $wsPostSslFail = @($wsPostChange | Where-Object { $_.SslMatch -eq $false })
            if ($wsPostErrors.Count -gt 0 -or $wsPostSslFail.Count -gt 0) {
                $wsPostErrors | ForEach-Object { Write-Fail "$($_.Instance) [$($_.Url)]: $($_.Error)" }
                $wsPostSslFail | ForEach-Object { Write-Fail "$($_.Instance) [$($_.Url)]: SSL cert $($_.SslThumbprint) (atteso $($updatePfx.Thumbprint))" }
                $wsPostChangeOk = $false
            } else {
                Write-Ok "Servizi web rispondono e SSL verificato dopo aggiornamento."
                $wsPostChangeOk = $true
            }
        } else {
            Write-Warning '  Test web services non eseguibile.'
            $wsPostChangeOk = $true
        }
    }
    catch {
        $runError = $_
        $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
        Write-Fail "E2E interrotto: $errMsg"
    }
    finally {
        Write-Phase 'Cleanup + Ripristino garantito'

        # Ripristino BC
        Write-Host ''
        Write-Host '  Ripristino BC...' -ForegroundColor Yellow
        try {
            Set-BCThumbprint -Thumbprint $originalThumb
            Write-Host '    BC ripristinato.' -ForegroundColor Green
        }
        catch {
            Write-Warning ("    BC restore: {0}" -f $_.Exception.Message)
        }

        # Ripristino IIS
        Write-Host '  Ripristino IIS...' -ForegroundColor Yellow
        try {
            Set-IISThumbprint -Thumbprint $originalThumb -SiteName $iisSite
            iisreset /restart | Out-Null
            Write-Host '    IIS reset eseguito.' -ForegroundColor Green
        }
        catch {
            Write-Warning ("    IIS restore: {0}" -f $_.Exception.Message)
        }

        # Ripristino config (backup file, fallback snapshot memoria)
        Write-Host '  Ripristino config...' -ForegroundColor Yellow
        try {
            if ($configBackup -and (Test-Path $configBackup)) {
                Copy-Item $configBackup $configPath -Force
                $configRestored = $true
                Write-Host '    Config ripristinato da backup file.' -ForegroundColor Green
            }
            elseif (-not [string]::IsNullOrWhiteSpace($configOriginalRaw)) {
                Set-Content $configPath -Value $configOriginalRaw -Encoding UTF8
                $configRestored = $true
                Write-Host '    Config ripristinato da snapshot in memoria.' -ForegroundColor Green
            }
            else {
                Write-Warning '    Nessun backup disponibile per il config.'
            }
        }
        catch {
            Write-Warning ("    Config restore: {0}" -f $_.Exception.Message)
        }

        # Verifica servizi web post-ripristino (polling fino a 10 min con SSL)
        Write-Host '  Attesa servizi web post-ripristino (fino a 10 min)...' -ForegroundColor Yellow
        Start-Sleep -Seconds 15
        try {
            $wsPostRestore = Wait-ForWebServicesE2E -MaxWaitSec 600 -IntervalSec 30 -ExpectedThumbprint $originalThumb
            if ($wsPostRestore) {
                $wsRestoreErrors = @($wsPostRestore | Where-Object { $_.Status -eq 'ERROR' })
                $wsRestoreSslFail = @($wsPostRestore | Where-Object { $_.SslMatch -eq $false })
                if ($wsRestoreErrors.Count -gt 0 -or $wsRestoreSslFail.Count -gt 0) {
                    $wsRestoreErrors | ForEach-Object { Write-Warning ("    {0} [{1}]: {2}" -f $_.Instance, $_.Url, $_.Error) }
                    $wsRestoreSslFail | ForEach-Object { Write-Warning ("    {0} [{1}]: SSL cert {2} (atteso {3})" -f $_.Instance, $_.Url, $_.SslThumbprint, $originalThumb) }
                    $wsPostRestoreOk = $false
                } else {
                    Write-Host '    Servizi web OK e SSL verificato dopo ripristino.' -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Warning ("    Verifica WS post-restore: {0}" -f $_.Exception.Message)
        }

        # Pulizia
        if ($destPwd -and (Test-Path $destPwd)) {
            Remove-Item $destPwd -Force -ErrorAction SilentlyContinue
        }
        if ($destPfx -and (Test-Path $destPfx)) {
            Remove-Item $destPfx -Force -ErrorAction SilentlyContinue
        }
        if ($destPfxInstalled -and (Test-Path $destPfxInstalled)) {
            Remove-Item $destPfxInstalled -Force -ErrorAction SilentlyContinue
        }
        if ($updateImported -and $updatePfx.Thumbprint -and $updatePfx.Thumbprint -ne $originalThumb) {
            Remove-Item "Cert:\LocalMachine\My\$($updatePfx.Thumbprint)" -Force -ErrorAction SilentlyContinue
        }
        if ($baselineImported -and $baselinePfx.Thumbprint -and $baselinePfx.Thumbprint -ne $originalThumb) {
            Remove-Item "Cert:\LocalMachine\My\$($baselinePfx.Thumbprint)" -Force -ErrorAction SilentlyContinue
        }
        Write-Host '  Pulizia completata.' -ForegroundColor Gray
    }

    # ── Riepilogo finale ─────────────────────────────────────
    $pass  = $bcOk -and $iisOk -and $wsPostChangeOk -and $wsPostRestoreOk -and $configRestored -and (-not $runError)
    $originalShort = if ($originalThumb) { $originalThumb.Substring(0,[Math]::Min(36,$originalThumb.Length)) } else { 'N/D' }
    $targetShort = $updatePfx.Thumbprint.Substring(0,[Math]::Min(36,$updatePfx.Thumbprint.Length))
    $color = if ($pass) { 'Green' } else { 'Red' }
    Write-Host ''
    Write-Host '+--------------------------------------------------+' -ForegroundColor $color
    Write-Host ('|  RISULTATO: {0,-38}|' -f $(if ($pass) { 'PASS - Test superato!' } else { 'FAIL - vedere dettagli sopra' })) -ForegroundColor $color
    Write-Host '|                                                  |' -ForegroundColor $color
    Write-Host ("|  Originale : {0,-36}|" -f $originalShort) -ForegroundColor $color
    Write-Host ("|  Target    : {0,-36}|" -f $targetShort) -ForegroundColor $color
    Write-Host ("|  BC camb.  : {0,-36}|" -f $(if ($bcOk)  { 'SI' } else { 'NO' })) -ForegroundColor $color
    Write-Host ("|  IIS camb. : {0,-36}|" -f $(if ($iisOk) { 'SI' } else { 'NO' })) -ForegroundColor $color
    Write-Host ("|  Config OK : {0,-36}|" -f $(if ($configRestored) { 'SI' } else { 'NO' })) -ForegroundColor $color
    Write-Host ("|  WS cambio : {0,-36}|" -f $(if ($wsPostChangeOk) { 'OK' } else { 'ERRORI' })) -ForegroundColor $color
    Write-Host ("|  WS restore: {0,-36}|" -f $(if ($wsPostRestoreOk) { 'OK' } else { 'ERRORI' })) -ForegroundColor $color
    if ($runError) {
        $errorSummary = if ($runError.Exception) { $runError.Exception.Message } else { $runError.ToString() }
        $errorSummary = $errorSummary.Substring(0,[Math]::Min(36,$errorSummary.Length))
        Write-Host ("|  Errore    : {0,-36}|" -f $errorSummary) -ForegroundColor $color
    }
    Write-Host '+--------------------------------------------------+' -ForegroundColor $color
    Write-Host ''
}

# =============================================================
# Action: Help
# =============================================================
function Show-Help {
    Write-Host ''
    Write-Host 'CERTAMENT E2E Tester'
    Write-Host '===================='
    Write-Host 'Verifica il ciclo completo di aggiornamento certificati BC + IIS.'
    Write-Host ''
    Write-Host 'Utilizzo:'
    Write-Host '  .\Certament-E2E-Tester.ps1'
    Write-Host '      -> Test completo (chiede password PFX interattiva)'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -SecretFilePath C:\temp\pfxpwd.txt'
    Write-Host '      -> Test completo con password letta da file'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action Status'
    Write-Host '      -> Stato corrente: task, thumbprint BC/IIS, drop folder'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action Restore'
    Write-Host '      -> Ripristino emergenza: riporta BC/IIS al certificato originale'
    Write-Host ''
    Write-Host 'Cosa fa RunFull automaticamente:'
    Write-Host '  1) Legge config.json da InstallRoot'
    Write-Host '  2) Carica il modulo BC e rileva il thumbprint live iniziale'
    Write-Host '  3) Risolve la password PFX (file -> config -> prompt)'
    Write-Host '  4) Legge i PFX reali 2026CERT.pfx e 2027CERT.pfx'
    Write-Host '  5) Backup config + forza NotifyBeforeDays = 9999'
    Write-Host '  6) Imposta BC/IIS sul baseline 2026CERT e deposita 2027CERT nel drop folder'
    Write-Host '  7) Esegue _MAINCertManager.ps1 direttamente'
    Write-Host '  8) Verifica che BC e IIS passino al thumbprint del 2027CERT'
    Write-Host '  9) Ripristina BC, IIS e config allo stato live iniziale - pulisce il drop folder'
    Write-Host '  10) Stampa PASS o FAIL'
    Write-Host ''
    Write-Host 'Parametri:'
    Write-Host '  -Action       RunFull (default) | Status | Restore | Help'
    Write-Host '  -InstallRoot  Cartella CERTAMENT (default: C:\CERTAMENT)'
    Write-Host '  -SecretFilePath   File plain-text con la password PFX (opzionale)'
    Write-Host '  -BaselinePfxPath  PFX baseline E2E (default: C:\_install\e2e2_bak\2026CERT.pfx)'
    Write-Host '  -UpdatePfxPath    PFX target E2E (default: C:\_install\e2e2_bak\2027CERT.pfx)'
    Write-Host ''
}

# =============================================================
# Dispatch
# =============================================================
switch ($Action) {
    'RunFull' { Invoke-RunFull }
    'Status'  { Invoke-Status }
    'Restore' { Invoke-Restore }
    'Help'    { Show-Help }
}
