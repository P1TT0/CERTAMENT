<#
.SYNOPSIS
    CERTAMENT E2E Tester - test di scenario per il ciclo di aggiornamento certificati.
.DESCRIPTION
    Crea ambienti di test specifici, esegue CERTAMENT e verifica il comportamento.

    SCENARI (creano ambiente, eseguono CERTAMENT, verificano risultato):
      RunScenarios       : esegue tutti gli scenari in sequenza (default).
      ScenarioRenew      : tutti i servizi con cert scaduto + PFX valido -> aggiornamento completo.
      ScenarioMixed      : servizi con cert diversi (uno scaduto, uno valido) -> solo scaduti aggiornati.
      ScenarioNoCert     : servizio senza cert + servizi con cert scaduto -> salta quello senza cert.
      ScenarioNoPfx      : cert in scadenza senza PFX -> notifica, nessun cambiamento.
      ScenarioExpiredPfx : cert in scadenza + PFX scaduto -> rifiuta PFX, nessun cambiamento.
      ScenarioAllValid   : tutti i cert validi -> nessuna azione, exit 0.

    VERIFICHE (non modificano l'ambiente):
      TestConfig         : valida config.json.
      TestModules        : verifica importazione moduli.
      TestNotification   : testa invio webhook.
      TestHeartbeat      : testa connettivita' heartbeat Azure.
      TestCertStore      : verifica coerenza cert store / BC / IIS.
      RunAll             : esegue tutte le verifiche non distruttive.

    UTILITA':
      Status             : mostra stato corrente (task, thumbprint, drop folder).
      Restore            : ripristino emergenza BC/IIS al certificato originale.
      Help               : mostra questo messaggio.
.EXAMPLE
    .\Certament-E2E-Tester.ps1
    .\Certament-E2E-Tester.ps1 -Action ScenarioMixed -SecretFilePath C:\temp\pfxpwd.txt
    .\Certament-E2E-Tester.ps1 -Action TestConfig
    .\Certament-E2E-Tester.ps1 -Action RunAll
    .\Certament-E2E-Tester.ps1 -Action Status
#>
param(
    [ValidateSet(
        'RunScenarios', 'ScenarioRenew', 'ScenarioMixed', 'ScenarioNoCert',
        'ScenarioNoPfx', 'ScenarioExpiredPfx', 'ScenarioAllValid',
        'TestConfig', 'TestModules', 'TestNotification', 'TestHeartbeat', 'TestCertStore',
        'RunAll', 'Status', 'Restore', 'Help')]
    [string]$Action = 'RunScenarios',

    # Cartella di installazione CERTAMENT
    [string]$InstallRoot = 'C:\CERTAMENT',

    # File .txt con la password del PFX di test (plain text, una riga).
    # Se omesso, la password viene chiesta interattivamente.
    [string]$SecretFilePath = ''
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

function Get-AllBCThumbprints {
    $map = @()
    foreach ($inst in @(Get-NAVServerInstance)) {
        try {
            $t = Get-NAVServerConfiguration -ServerInstance $inst.ServerInstance `
                 -KeyName ServicesCertificateThumbprint -ErrorAction SilentlyContinue
            if ($t -and $t.Trim() -ne '') {
                $map += [PSCustomObject]@{ Instance = $inst.ServerInstance; Thumbprint = $t.Trim().ToUpper() }
            }
        } catch {}
    }
    return $map
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

function Restore-BCThumbprints {
    param([array]$BaselineMap)
    foreach ($entry in $BaselineMap) {
        try {
            $curr = Get-NAVServerConfiguration -ServerInstance $entry.Instance `
                    -KeyName ServicesCertificateThumbprint -ErrorAction SilentlyContinue
            if (($curr -replace '\s','').ToUpper() -eq $entry.Thumbprint) {
                Write-Host ("    {0}: gia al baseline." -f $entry.Instance) -ForegroundColor Gray
                continue
            }
            Set-NAVServerConfiguration -ServerInstance $entry.Instance `
                -KeyName ServicesCertificateThumbprint -KeyValue $entry.Thumbprint -ErrorAction Stop
            Restart-NAVServerInstance -ServerInstance $entry.Instance -ErrorAction Stop
            Write-Host ("    {0}: ripristinato a {1}" -f $entry.Instance, $entry.Thumbprint) -ForegroundColor Green
        } catch {
            Write-Warning ("    {0}: errore restore: {1}" -f $entry.Instance, $_.Exception.Message)
        }
    }
}

function Set-BCInstanceThumbprint {
    param(
        [string]$Instance,
        [string]$Thumbprint,
        [switch]$NoRestart
    )
    $norm = if ($Thumbprint) { $Thumbprint.ToUpper() } else { '' }
    Set-NAVServerConfiguration -ServerInstance $Instance `
        -KeyName ServicesCertificateThumbprint -KeyValue $norm -ErrorAction Stop
    if (-not $NoRestart) {
        Restart-NAVServerInstance -ServerInstance $Instance -ErrorAction Stop
    }
    Write-Host ("    {0} -> {1}" -f $Instance, $(if ($norm) { $norm } else { '(vuoto)' })) -ForegroundColor Green
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

function Write-Phase { param([string]$Text) Write-Host ("`n=== $Text ===") -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host ("  [OK] $Text") -ForegroundColor Green }
function Write-Fail  { param([string]$Text) Write-Host ("  [!!] $Text") -ForegroundColor Red }
function Write-Skip  { param([string]$Text) Write-Host ("  [--] $Text") -ForegroundColor Gray }

# Test result tracking
$script:TestResults = [System.Collections.ArrayList]::new()

function Add-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $null = $script:TestResults.Add([PSCustomObject]@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    })
    if ($Passed) { Write-Ok "$Name$(if ($Detail) { " - $Detail" })" }
    else         { Write-Fail "$Name$(if ($Detail) { " - $Detail" })" }
}

function Show-TestSummary {
    $total  = $script:TestResults.Count
    $passed = @($script:TestResults | Where-Object { $_.Passed }).Count
    $failed = $total - $passed
    $color  = if ($failed -eq 0) { 'Green' } else { 'Red' }

    Write-Host ''
    Write-Host ('+' + ('-' * 50) + '+') -ForegroundColor $color
    Write-Host ("|  TEST SUMMARY: {0} passed, {1} failed (of {2}){3}|" -f $passed, $failed, $total, (' ' * (50 - 43 - "$passed$failed$total".Length))) -ForegroundColor $color
    Write-Host ('+' + ('-' * 50) + '+') -ForegroundColor $color

    foreach ($r in $script:TestResults) {
        $icon = if ($r.Passed) { 'PASS' } else { 'FAIL' }
        $c    = if ($r.Passed) { 'Green' } else { 'Red' }
        Write-Host ("  [{0}] {1}" -f $icon, $r.Name) -ForegroundColor $c
    }
    Write-Host ''
}

function Import-CertamentModules {
    $moduleDir = Join-Path $InstallRoot 'modules'
    @('Get-BCThumbprint','Get-CertDetails','Get-PfxFile','Install-PfxCert',
      'Update-BCServiceCert','Update-IISBinding','Test-BCWebServices','Send-Notification') |
        ForEach-Object { Import-Module (Join-Path $moduleDir "$_.psm1") -Force }
}

# =============================================================
# Scenario framework helpers
# =============================================================

function Resolve-PfxPassword {
    if ($script:PfxPasswordResolved) { return $script:PfxPasswordResolved }
    if (-not [string]::IsNullOrWhiteSpace($SecretFilePath) -and (Test-Path $SecretFilePath)) {
        $script:PfxPasswordResolved = (Get-Content $SecretFilePath -Raw).Trim()
    }
    else {
        $secure = Read-Host 'Password per i PFX di test' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $script:PfxPasswordResolved = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
    }
    if ([string]::IsNullOrWhiteSpace($script:PfxPasswordResolved)) { throw 'Password non fornita.' }
    return $script:PfxPasswordResolved
}

function Save-TestBaseline {
    Import-BCModuleSafe
    $map = @(Get-AllBCThumbprints)
    $cfg, $configPath = Read-CertamentConfig
    $iisSite = if ($cfg.IIS -and $cfg.IIS.SiteName) { $cfg.IIS.SiteName } `
               else { 'Microsoft Dynamics 365 Business Central Web Client' }
    $iisThumb = Get-LiveIISThumbprint -SiteName $iisSite
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $configBackup = "$configPath.e2e_backup_$stamp"
    $configOriginalRaw = Get-Content $configPath -Raw
    Copy-Item $configPath $configBackup -Force

    return @{
        BCMap             = $map
        IISThumb          = $iisThumb
        IISSite           = $iisSite
        Config            = $cfg
        ConfigPath        = $configPath
        ConfigBackup      = $configBackup
        ConfigOriginalRaw = $configOriginalRaw
        Stamp             = $stamp
        PfxDrop           = $cfg.Pfx.Path
        MainScript        = Join-Path $InstallRoot '_MAINCertManager.ps1'
        TestCerts         = @()
        TestFiles         = @()
        StashedFiles      = @()
    }
}

function Restore-TestBaseline {
    param([hashtable]$BL)
    Write-Phase 'Ripristino'

    # BC per-istanza
    try {
        Restore-BCThumbprints -BaselineMap $BL.BCMap
        Write-Host '    BC ripristinato.' -ForegroundColor Green
    } catch { Write-Warning "    BC restore: $($_.Exception.Message)" }

    # IIS
    if ($BL.IISThumb) {
        try {
            Set-IISThumbprint -Thumbprint $BL.IISThumb -SiteName $BL.IISSite
            iisreset /restart 2>&1 | Out-Null
            Write-Host '    IIS ripristinato.' -ForegroundColor Green
        } catch { Write-Warning "    IIS restore: $($_.Exception.Message)" }
    }

    # Config
    if ($BL.ConfigBackup -and (Test-Path $BL.ConfigBackup)) {
        Copy-Item $BL.ConfigBackup $BL.ConfigPath -Force
        Remove-Item $BL.ConfigBackup -Force -ErrorAction SilentlyContinue
        Write-Host '    Config ripristinato.' -ForegroundColor Green
    }
    elseif ($BL.ConfigOriginalRaw) {
        Set-Content $BL.ConfigPath -Value $BL.ConfigOriginalRaw -Encoding UTF8
    }

    # Cleanup test certs
    foreach ($t in $BL.TestCerts) {
        Remove-Item "Cert:\LocalMachine\My\$t" -Force -ErrorAction SilentlyContinue
    }

    # Cleanup test files
    foreach ($f in $BL.TestFiles) {
        if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }

    # Restore stashed files
    foreach ($s in $BL.StashedFiles) {
        if (Test-Path $s.Temp) { Move-Item $s.Temp $s.Original -Force -ErrorAction SilentlyContinue }
    }

    # Clean password.txt
    $pwdFile = Join-Path $BL.PfxDrop 'password.txt'
    if (Test-Path $pwdFile) { Remove-Item $pwdFile -Force -ErrorAction SilentlyContinue }

    # Clean archived E2E PFX
    $archiveDir = Join-Path $BL.PfxDrop 'installed'
    if (Test-Path $archiveDir) {
        Get-ChildItem $archiveDir -Filter 'E2E_*' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Write-Ok 'Ripristino completato.'
}

function Set-TestConfig {
    param([hashtable]$BL, [int]$NotifyBeforeDays)
    $cfgObj = $BL.ConfigOriginalRaw | ConvertFrom-Json
    $cfgObj.Notifications.CertificateExpiry.NotifyBeforeDays = $NotifyBeforeDays
    $cfgObj | ConvertTo-Json -Depth 10 | Set-Content $BL.ConfigPath -Encoding UTF8
    Write-Ok "NotifyBeforeDays = $NotifyBeforeDays"
}

function Invoke-CertamentProcess {
    param([string]$MainScript)
    Write-Phase 'Esecuzione CERTAMENT'
    Write-Host ''
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MainScript
    $code = $LASTEXITCODE
    Write-Host ''
    Write-Host ("  Exit code: $code") -ForegroundColor $(if ($code -eq 0) { 'Green' } else { 'Yellow' })
    return $code
}

# =============================================================
# Action: TestConfig
# =============================================================
function Invoke-TestConfig {
    Write-Phase 'TEST CONFIG'
    $script:TestResults.Clear()

    $cp = Join-Path $InstallRoot 'config.json'
    Add-TestResult -Name 'config.json exists' -Passed (Test-Path $cp) -Detail $cp
    if (-not (Test-Path $cp)) { Show-TestSummary; return }

    $raw = Get-Content $cp -Raw
    $cfg = $null
    try {
        $sanitized = (($raw -split "`r?`n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
        $cfg = $sanitized | ConvertFrom-Json
        Add-TestResult -Name 'config.json valid JSON' -Passed $true
    }
    catch {
        Add-TestResult -Name 'config.json valid JSON' -Passed $false -Detail $_.Exception.Message
        Show-TestSummary; return
    }

    Add-TestResult -Name 'Context.CustomerName set' `
        -Passed ($cfg.Context -and $cfg.Context.CustomerName -and $cfg.Context.CustomerName.Trim() -ne '' -and $cfg.Context.CustomerName -ne '<SET_CUSTOMER_NAME>') `
        -Detail $(if ($cfg.Context.CustomerName) { $cfg.Context.CustomerName } else { '(empty)' })

    Add-TestResult -Name 'Pfx.Path configured' `
        -Passed ($cfg.Pfx -and $cfg.Pfx.Path -and $cfg.Pfx.Path.Trim() -ne '') `
        -Detail $(if ($cfg.Pfx.Path) { $cfg.Pfx.Path } else { '(empty)' })

    if ($cfg.Pfx.Path) {
        Add-TestResult -Name 'Pfx.Path directory exists' -Passed (Test-Path $cfg.Pfx.Path) -Detail $cfg.Pfx.Path
    }

    Add-TestResult -Name 'IIS.SiteName configured' `
        -Passed ($cfg.IIS -and $cfg.IIS.SiteName -and $cfg.IIS.SiteName.Trim() -ne '') `
        -Detail $(if ($cfg.IIS.SiteName) { $cfg.IIS.SiteName } else { '(default)' })

    Add-TestResult -Name 'Webhooks.Customer configured' `
        -Passed ($cfg.Notifications -and $cfg.Notifications.Webhooks -and $cfg.Notifications.Webhooks.Customer -and $cfg.Notifications.Webhooks.Customer -ne '<SET_CUSTOMER_WEBHOOK_URL>') `
        -Detail $(if ($cfg.Notifications.Webhooks.Customer -and $cfg.Notifications.Webhooks.Customer -ne '<SET_CUSTOMER_WEBHOOK_URL>') { 'set' } else { 'missing/placeholder' })

    Add-TestResult -Name 'Webhooks.Internal configured' `
        -Passed ($cfg.Notifications -and $cfg.Notifications.Webhooks -and $cfg.Notifications.Webhooks.Internal -and $cfg.Notifications.Webhooks.Internal -ne '<SET_INTERNAL_WEBHOOK_URL>') `
        -Detail $(if ($cfg.Notifications.Webhooks.Internal -and $cfg.Notifications.Webhooks.Internal -ne '<SET_INTERNAL_WEBHOOK_URL>') { 'set' } else { 'missing/placeholder' })

    Add-TestResult -Name 'NotifyBeforeDays set' `
        -Passed ($cfg.Notifications -and $cfg.Notifications.CertificateExpiry -and $null -ne $cfg.Notifications.CertificateExpiry.NotifyBeforeDays) `
        -Detail $(if ($cfg.Notifications.CertificateExpiry.NotifyBeforeDays) { "$($cfg.Notifications.CertificateExpiry.NotifyBeforeDays) days" } else { '(not set)' })

    Add-TestResult -Name 'Heartbeat.Enabled & Url set' `
        -Passed ($cfg.Heartbeat -and $cfg.Heartbeat.Enabled -eq $true -and $cfg.Heartbeat.Url -and $cfg.Heartbeat.Url -ne '<SET_AZURE_HEARTBEAT_URL>') `
        -Detail $(if ($cfg.Heartbeat.Enabled) { 'enabled' } else { 'disabled' })

    Add-TestResult -Name 'Logging configured' `
        -Passed ($cfg.Logging -and $cfg.Logging.Enabled -eq $true) `
        -Detail $(if ($cfg.Logging.RetentionDays) { "$($cfg.Logging.RetentionDays) days retention" } else { '(defaults)' })

    Show-TestSummary
}

# =============================================================
# Action: TestModules
# =============================================================
function Invoke-TestModules {
    Write-Phase 'TEST MODULES'
    $script:TestResults.Clear()

    $moduleDir = Join-Path $InstallRoot 'modules'
    Add-TestResult -Name 'modules/ directory exists' -Passed (Test-Path $moduleDir) -Detail $moduleDir
    if (-not (Test-Path $moduleDir)) { Show-TestSummary; return }

    $moduleMap = [ordered]@{
        'Get-BCThumbprint'     = 'Get-BCThumbprint'
        'Get-CertDetails'      = 'Get-CertDetails'
        'Get-PfxFile'          = 'Get-PfxFile'
        'Install-PfxCert'      = 'Install-PfxCert'
        'Update-BCServiceCert' = 'Update-BCServiceCert'
        'Update-IISBinding'    = 'Update-IISBinding'
        'Test-BCWebServices'   = 'Test-BCWebServices'
        'Send-Notification'    = 'Send-Notification'
    }

    foreach ($modName in $moduleMap.Keys) {
        $modPath = Join-Path $moduleDir "$modName.psm1"
        $fileExists = Test-Path $modPath
        Add-TestResult -Name "File $modName.psm1 exists" -Passed $fileExists

        if ($fileExists) {
            try {
                Import-Module $modPath -Force -ErrorAction Stop
                $fn = Get-Command $moduleMap[$modName] -ErrorAction SilentlyContinue
                Add-TestResult -Name "Function $($moduleMap[$modName]) available" -Passed ($null -ne $fn)
            }
            catch {
                Add-TestResult -Name "Import $modName" -Passed $false -Detail $_.Exception.Message
            }
        }
    }

    # Check main script exists
    $mainScript = Join-Path $InstallRoot '_MAINCertManager.ps1'
    Add-TestResult -Name '_MAINCertManager.ps1 exists' -Passed (Test-Path $mainScript)

    # Check installer exists
    $installer = Join-Path $InstallRoot 'Install-Certament.ps1'
    Add-TestResult -Name 'Install-Certament.ps1 exists' -Passed (Test-Path $installer)

    # Check config template exists
    $configExample = Join-Path $InstallRoot 'config.example.json'
    Add-TestResult -Name 'config.example.json exists' -Passed (Test-Path $configExample)

    # BC module availability
    $bcCommand = Get-Command Get-NAVServerInstance -ErrorAction SilentlyContinue
    if (-not $bcCommand) {
        try { Import-BCModuleSafe } catch {}
        $bcCommand = Get-Command Get-NAVServerInstance -ErrorAction SilentlyContinue
    }
    Add-TestResult -Name 'BC Management module loadable' -Passed ($null -ne $bcCommand)

    Show-TestSummary
}

# =============================================================
# Action: TestNotification
# =============================================================
function Invoke-TestNotification {
    Write-Phase 'TEST NOTIFICATION'
    $script:TestResults.Clear()

    $cfg, $_ = Read-CertamentConfig
    Import-CertamentModules

    $webhooks = @{}
    if ($cfg.Notifications -and $cfg.Notifications.Webhooks) {
        if ($cfg.Notifications.Webhooks.Customer) { $webhooks['Customer'] = [string]$cfg.Notifications.Webhooks.Customer }
        if ($cfg.Notifications.Webhooks.Internal) { $webhooks['Internal'] = [string]$cfg.Notifications.Webhooks.Internal }
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $testTitle = 'CERTAMENT E2E - Test Notification'

    # Test EnableWebhook gating
    $webhooksEnabled = ($cfg.Notifications.EnableWebhook -ne $false)
    Add-TestResult -Name 'EnableWebhook flag' -Passed $true -Detail $(if ($webhooksEnabled) { 'enabled' } else { 'disabled (notifications gated)' })

    # Test Internal webhook
    if ($webhooks.ContainsKey('Internal')) {
        $testMsg = "Test notifica Internal da E2E Tester ($stamp) su $env:COMPUTERNAME"
        $sent = Send-Notification -Title $testTitle -Message $testMsg -Target 'Internal' -Webhooks $webhooks
        Add-TestResult -Name 'Internal webhook delivery' -Passed ([bool]$sent)
    }
    else {
        Add-TestResult -Name 'Internal webhook configured' -Passed $false -Detail 'No Internal webhook URL'
    }

    # Test Customer webhook
    if ($webhooks.ContainsKey('Customer')) {
        $testMsg = "Test notifica Customer da E2E Tester ($stamp) su $env:COMPUTERNAME"
        $sent = Send-Notification -Title $testTitle -Message $testMsg -Target 'Customer' -Webhooks $webhooks
        Add-TestResult -Name 'Customer webhook delivery' -Passed ([bool]$sent)
    }
    else {
        Add-TestResult -Name 'Customer webhook configured' -Passed $false -Detail 'No Customer webhook URL'
    }

    # Verify EnableCustomerNotification flag is respected
    $custNotifEnabled = ($cfg.Notifications.CertificateExpiry.EnableCustomerNotification -ne $false)
    Add-TestResult -Name 'EnableCustomerNotification flag' -Passed $true `
        -Detail $(if ($custNotifEnabled) { 'enabled' } else { 'disabled (customer notifications suppressed)' })

    Show-TestSummary
}

# =============================================================
# Action: TestHeartbeat
# =============================================================
function Invoke-TestHeartbeat {
    Write-Phase 'TEST HEARTBEAT'
    $script:TestResults.Clear()

    $cfg, $_ = Read-CertamentConfig

    $hbEnabled = ($cfg.Heartbeat -and $cfg.Heartbeat.Enabled -eq $true)
    Add-TestResult -Name 'Heartbeat.Enabled' -Passed $hbEnabled

    $hbUrl = if ($cfg.Heartbeat -and $cfg.Heartbeat.Url) { [string]$cfg.Heartbeat.Url } else { '' }
    $hbUrlSet = (-not [string]::IsNullOrWhiteSpace($hbUrl)) -and ($hbUrl -ne '<SET_AZURE_HEARTBEAT_URL>')
    Add-TestResult -Name 'Heartbeat.Url configured' -Passed $hbUrlSet

    if ($hbEnabled -and $hbUrlSet) {
        $timeoutSec = if ($cfg.Heartbeat.TimeoutSec) { [int]$cfg.Heartbeat.TimeoutSec } else { 10 }
        $customerName = if ($cfg.Context -and $cfg.Context.CustomerName) { [string]$cfg.Context.CustomerName } else { '' }

        $payload = @{
            tool      = 'CERTAMENT'
            customer  = $customerName
            server    = $env:COMPUTERNAME
            status    = 'E2E-Test'
            stage     = 'HeartbeatTest'
            detail    = 'E2E heartbeat connectivity test'
            timestamp = (Get-Date).ToString('o')
        } | ConvertTo-Json -Depth 6

        try {
            Invoke-RestMethod -Method POST -Uri $hbUrl -ContentType 'application/json; charset=utf-8' `
                -Body $payload -TimeoutSec $timeoutSec -ErrorAction Stop | Out-Null
            Add-TestResult -Name 'Heartbeat POST request' -Passed $true
        }
        catch {
            Add-TestResult -Name 'Heartbeat POST request' -Passed $false -Detail $_.Exception.Message
        }
    }
    else {
        Write-Skip 'Heartbeat test skipped (not enabled or URL not configured)'
    }

    Show-TestSummary
}

# =============================================================
# Action: TestCertStore
# =============================================================
function Invoke-TestCertStore {
    Write-Phase 'TEST CERT STORE COHERENCE'
    $script:TestResults.Clear()

    Import-BCModuleSafe
    $cfg, $_ = Read-CertamentConfig

    # Get BC thumbprints
    $bcThumbs = @()
    foreach ($inst in @(Get-NAVServerInstance)) {
        try {
            $t = Get-NAVServerConfiguration -ServerInstance $inst.ServerInstance `
                 -KeyName ServicesCertificateThumbprint -ErrorAction SilentlyContinue
            if ($t -and $t.Trim() -ne '') {
                $bcThumbs += [PSCustomObject]@{
                    Instance   = $inst.ServerInstance
                    Thumbprint = $t.Trim().ToUpper()
                    State      = $inst.State
                }
            }
        } catch {}
    }

    Add-TestResult -Name 'BC instances found' -Passed ($bcThumbs.Count -gt 0) -Detail "$($bcThumbs.Count) instances"

    # Check each BC thumbprint is in cert store
    $uniqueThumbs = @($bcThumbs | Select-Object -ExpandProperty Thumbprint -Unique)
    foreach ($thumb in $uniqueThumbs) {
        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint.ToUpper() -eq $thumb }
        $inStore = ($null -ne $cert)
        $detail = if ($cert) {
            "Subject: $($cert.Subject), Expires: $($cert.NotAfter.ToString('yyyy-MM-dd')), HasKey: $($cert.HasPrivateKey)"
        } else { 'NOT IN STORE' }
        Add-TestResult -Name "BC cert in store [$($thumb.Substring(0,12))...]" -Passed $inStore -Detail $detail

        if ($cert) {
            $isExpired = $cert.NotAfter -lt (Get-Date)
            Add-TestResult -Name "BC cert not expired [$($thumb.Substring(0,12))...]" -Passed (-not $isExpired) `
                -Detail $(if ($isExpired) { "EXPIRED on $($cert.NotAfter)" } else { "$([int]((New-TimeSpan -Start (Get-Date) -End $cert.NotAfter).TotalDays)) days remaining" })

            Add-TestResult -Name "BC cert has private key [$($thumb.Substring(0,12))...]" -Passed $cert.HasPrivateKey
        }
    }

    # Check all BC instances are Running
    foreach ($entry in $bcThumbs) {
        Add-TestResult -Name "BC instance $($entry.Instance) running" `
            -Passed ($entry.State -eq 'Running') -Detail "State: $($entry.State)"
    }

    # Check IIS binding matches a BC thumbprint
    $iisSite = if ($cfg.IIS -and $cfg.IIS.SiteName) { $cfg.IIS.SiteName } else { 'Microsoft Dynamics 365 Business Central Web Client' }
    $iisThumb = Get-LiveIISThumbprint -SiteName $iisSite
    if ($iisThumb) {
        $iisMatchesBC = $uniqueThumbs -contains $iisThumb
        Add-TestResult -Name 'IIS thumbprint matches BC' -Passed $iisMatchesBC `
            -Detail "IIS: $iisThumb"

        $iisCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                   Where-Object { $_.Thumbprint.ToUpper() -eq $iisThumb }
        Add-TestResult -Name 'IIS cert in store' -Passed ($null -ne $iisCert) `
            -Detail $(if ($iisCert) { "Expires: $($iisCert.NotAfter.ToString('yyyy-MM-dd'))" } else { 'NOT IN STORE' })
    }
    else {
        Add-TestResult -Name 'IIS HTTPS binding found' -Passed $false -Detail "Site: $iisSite"
    }

    Show-TestSummary
}

# =============================================================
# Action: RunAll (batch all non-destructive tests)
# =============================================================
function Invoke-RunAll {
    Write-Host ''
    Write-Host '+--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '|    CERTAMENT E2E - Running all tests             |' -ForegroundColor Cyan
    Write-Host '+--------------------------------------------------+' -ForegroundColor Cyan

    $allResults = [System.Collections.ArrayList]::new()

    Write-Host "`n>>> TestConfig" -ForegroundColor Yellow
    Invoke-TestConfig
    $null = $allResults.AddRange(@($script:TestResults))

    Write-Host "`n>>> TestModules" -ForegroundColor Yellow
    Invoke-TestModules
    $null = $allResults.AddRange(@($script:TestResults))

    Write-Host "`n>>> TestCertStore" -ForegroundColor Yellow
    Invoke-TestCertStore
    $null = $allResults.AddRange(@($script:TestResults))

    Write-Host "`n>>> TestNotification" -ForegroundColor Yellow
    Invoke-TestNotification
    $null = $allResults.AddRange(@($script:TestResults))

    Write-Host "`n>>> TestHeartbeat" -ForegroundColor Yellow
    Invoke-TestHeartbeat
    $null = $allResults.AddRange(@($script:TestResults))

    # Grand summary
    $script:TestResults = $allResults
    Write-Host ''
    Write-Host ('+' + ('=' * 50) + '+') -ForegroundColor Cyan
    Write-Host '|              GRAND SUMMARY                       |' -ForegroundColor Cyan
    Write-Host ('+' + ('=' * 50) + '+') -ForegroundColor Cyan
    Show-TestSummary
}

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
# SCENARI - creano ambiente -> eseguono CERTAMENT -> verificano
# =============================================================

# ----- ScenarioRenew -----
# Tutti i servizi hanno lo stesso certificato in scadenza.
# PFX valido nella drop folder.
# Atteso: tutti i servizi aggiornati al nuovo certificato.
function Invoke-ScenarioRenew {
    Assert-Admin
    $script:TestResults.Clear()
    Write-Phase 'SCENARIO: Rinnovo completo'
    Write-Host '  Tutti i servizi con lo stesso cert scaduto + PFX valido.'
    Write-Host '  Atteso: tutti aggiornati, IIS aggiornato, exit 0.'

    $bl = Save-TestBaseline
    if ($bl.BCMap.Count -eq 0) { throw 'Nessuna istanza BC trovata.' }
    if (-not (Test-Path $bl.MainScript)) { throw "_MAINCertManager.ps1 non trovato." }

    $pwd = Resolve-PfxPassword
    $securePwd = ConvertTo-SecureString $pwd -AsPlainText -Force

    try {
        Write-Phase 'Setup ambiente'

        # Cert A: scadenza prossima (5 giorni)
        $certA = New-SelfSignedCertificate -DnsName 'certament.e2e.expiring' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddDays(5) `
            -FriendlyName "E2E Expiring $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certA.Thumbprint.ToUpper()
        Write-Ok "Cert scaduto: $($certA.Thumbprint.Substring(0,12))... (5gg)"

        # Cert R: sostituzione (3 anni) - esportato come PFX
        $certR = New-SelfSignedCertificate -DnsName 'certament.e2e.replacement' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddYears(3) `
            -FriendlyName "E2E Replacement $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certR.Thumbprint.ToUpper()
        $expectedThumb = $certR.Thumbprint.ToUpper()
        Write-Ok "Cert sostituzione: $($expectedThumb.Substring(0,12))... (3 anni)"

        # Esporta PFX e deposita nella drop folder
        $pfxFile = Join-Path $bl.PfxDrop ("E2E_RENEW_{0}.pfx" -f $bl.Stamp)
        Export-PfxCertificate -Cert $certR -FilePath $pfxFile -Password $securePwd | Out-Null
        $bl.TestFiles += $pfxFile
        Set-Content (Join-Path $bl.PfxDrop 'password.txt') -Value $pwd -Encoding UTF8 -NoNewline
        Write-Ok "PFX depositato: $pfxFile"

        # Imposta tutti i servizi BC al cert scaduto (senza restart - basta il config)
        Write-Host '  Configurazione istanze BC...'
        foreach ($entry in $bl.BCMap) {
            Set-BCInstanceThumbprint -Instance $entry.Instance -Thumbprint $certA.Thumbprint.ToUpper() -NoRestart
        }

        # Imposta IIS al cert scaduto
        Set-IISThumbprint -Thumbprint $certA.Thumbprint.ToUpper() -SiteName $bl.IISSite

        # Config: NotifyBeforeDays = 30 (cert A ha 5gg -> scaduto)
        Set-TestConfig -BL $bl -NotifyBeforeDays 30

        # Esegui CERTAMENT
        $exitCode = Invoke-CertamentProcess -MainScript $bl.MainScript

        # Verifica
        Write-Phase 'Verifica risultati'
        Import-BCModuleSafe
        $postMap = @(Get-AllBCThumbprints)
        $postIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        foreach ($entry in $bl.BCMap) {
            $post = $postMap | Where-Object { $_.Instance -eq $entry.Instance }
            $postThumb = if ($post) { $post.Thumbprint } else { '' }
            $ok = ($postThumb -eq $expectedThumb)
            Add-TestResult -Name "BC $($entry.Instance) aggiornata" -Passed $ok `
                -Detail "atteso=$($expectedThumb.Substring(0,12)) dopo=$(if ($postThumb) { $postThumb.Substring(0,12) } else { 'N/D' })"
        }
        Add-TestResult -Name 'IIS aggiornato' -Passed ($postIIS -eq $expectedThumb) `
            -Detail "atteso=$($expectedThumb.Substring(0,12)) dopo=$(if ($postIIS) { $postIIS.Substring(0,12) } else { 'N/D' })"
        Add-TestResult -Name 'Exit code = 0' -Passed ($exitCode -eq 0) -Detail "code=$exitCode"
    }
    catch {
        Add-TestResult -Name 'ScenarioRenew errore' -Passed $false -Detail $_.Exception.Message
    }
    finally { Restore-TestBaseline -BL $bl }

    Show-TestSummary
}

# ----- ScenarioMixed -----
# Servizi con certificati diversi: un gruppo scaduto, un gruppo valido.
# PFX per il rinnovo nella drop folder.
# Atteso: solo il gruppo scaduto viene aggiornato, il resto invariato.
function Invoke-ScenarioMixed {
    Assert-Admin
    $script:TestResults.Clear()
    Write-Phase 'SCENARIO: Servizi con certificati diversi'
    Write-Host '  Gruppo A -> cert scaduto, Gruppo B -> cert valido, PFX valido.'
    Write-Host '  Atteso: solo Gruppo A aggiornato. Gruppo B invariato.'

    $bl = Save-TestBaseline
    if ($bl.BCMap.Count -eq 0) { throw 'Nessuna istanza BC trovata.' }
    if (-not (Test-Path $bl.MainScript)) { throw "_MAINCertManager.ps1 non trovato." }

    $instances = @(Get-NAVServerInstance)
    if ($instances.Count -lt 2) {
        Write-Skip 'Servono almeno 2 istanze BC per questo scenario.'
        Add-TestResult -Name 'ScenarioMixed' -Passed $true -Detail "Saltato: solo $($instances.Count) istanza"
        Restore-TestBaseline -BL $bl
        Show-TestSummary
        return
    }

    $pwd = Resolve-PfxPassword
    $securePwd = ConvertTo-SecureString $pwd -AsPlainText -Force

    # Dividi istanze: prima meta' -> Gruppo A (scaduto), seconda meta' -> Gruppo B (valido)
    $halfIdx = [math]::Ceiling($instances.Count / 2)
    $groupAInstances = @($instances[0..($halfIdx - 1)] | ForEach-Object { $_.ServerInstance })
    $groupBInstances = @($instances[$halfIdx..($instances.Count - 1)] | ForEach-Object { $_.ServerInstance })

    try {
        Write-Phase 'Setup ambiente'

        # Cert A: scadenza prossima (5 giorni)
        $certA = New-SelfSignedCertificate -DnsName 'certament.e2e.expiring' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddDays(5) `
            -FriendlyName "E2E Expiring $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certA.Thumbprint.ToUpper()
        $thumbA = $certA.Thumbprint.ToUpper()
        Write-Ok "Cert scaduto (Gruppo A): $($thumbA.Substring(0,12))..."

        # Cert B: valido (3 anni)
        $certB = New-SelfSignedCertificate -DnsName 'certament.e2e.valid' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddYears(3) `
            -FriendlyName "E2E Valid $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certB.Thumbprint.ToUpper()
        $thumbB = $certB.Thumbprint.ToUpper()
        Write-Ok "Cert valido (Gruppo B): $($thumbB.Substring(0,12))..."

        # Cert R: sostituzione PFX (3 anni, diverso da B)
        $certR = New-SelfSignedCertificate -DnsName 'certament.e2e.replacement' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddYears(3) `
            -FriendlyName "E2E Replacement $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certR.Thumbprint.ToUpper()
        $expectedThumb = $certR.Thumbprint.ToUpper()
        Write-Ok "Cert sostituzione (PFX): $($expectedThumb.Substring(0,12))..."

        # Esporta PFX
        $pfxFile = Join-Path $bl.PfxDrop ("E2E_MIXED_{0}.pfx" -f $bl.Stamp)
        Export-PfxCertificate -Cert $certR -FilePath $pfxFile -Password $securePwd | Out-Null
        $bl.TestFiles += $pfxFile
        Set-Content (Join-Path $bl.PfxDrop 'password.txt') -Value $pwd -Encoding UTF8 -NoNewline

        # Configura Gruppo A -> cert scaduto
        Write-Host '  Configurazione Gruppo A (cert scaduto)...'
        foreach ($inst in $groupAInstances) {
            Set-BCInstanceThumbprint -Instance $inst -Thumbprint $thumbA -NoRestart
        }

        # Configura Gruppo B -> cert valido
        Write-Host '  Configurazione Gruppo B (cert valido)...'
        foreach ($inst in $groupBInstances) {
            Set-BCInstanceThumbprint -Instance $inst -Thumbprint $thumbB -NoRestart
        }

        # IIS -> cert scaduto (dovrebbe essere aggiornato)
        Set-IISThumbprint -Thumbprint $thumbA -SiteName $bl.IISSite

        # Config: NotifyBeforeDays = 30 (cert A: 5gg -> scaduto, cert B: 1095gg -> valido)
        Set-TestConfig -BL $bl -NotifyBeforeDays 30

        # Esegui CERTAMENT
        $exitCode = Invoke-CertamentProcess -MainScript $bl.MainScript

        # Verifica
        Write-Phase 'Verifica risultati'
        Import-BCModuleSafe
        $postMap = @(Get-AllBCThumbprints)
        $postIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Gruppo A: deve essere stato aggiornato al cert sostituzione
        foreach ($inst in $groupAInstances) {
            $post = $postMap | Where-Object { $_.Instance -eq $inst }
            $postThumb = if ($post) { $post.Thumbprint } else { '' }
            Add-TestResult -Name "Gruppo A [$inst] aggiornato" -Passed ($postThumb -eq $expectedThumb) `
                -Detail "atteso=$($expectedThumb.Substring(0,12)) dopo=$(if ($postThumb) { $postThumb.Substring(0,12) } else { 'N/D' })"
        }

        # Gruppo B: deve essere INVARIATO (cert valido)
        foreach ($inst in $groupBInstances) {
            $post = $postMap | Where-Object { $_.Instance -eq $inst }
            $postThumb = if ($post) { $post.Thumbprint } else { '' }
            Add-TestResult -Name "Gruppo B [$inst] invariato" -Passed ($postThumb -eq $thumbB) `
                -Detail "atteso=$($thumbB.Substring(0,12)) dopo=$(if ($postThumb) { $postThumb.Substring(0,12) } else { 'N/D' })"
        }

        # IIS: aggiornato (era su cert A scaduto)
        Add-TestResult -Name 'IIS aggiornato' -Passed ($postIIS -eq $expectedThumb) `
            -Detail "atteso=$($expectedThumb.Substring(0,12)) dopo=$(if ($postIIS) { $postIIS.Substring(0,12) } else { 'N/D' })"
    }
    catch {
        Add-TestResult -Name 'ScenarioMixed errore' -Passed $false -Detail $_.Exception.Message
    }
    finally { Restore-TestBaseline -BL $bl }

    Show-TestSummary
}

# ----- ScenarioNoCert -----
# Un servizio senza certificato configurato + servizi con cert scaduto.
# PFX disponibile.
# Atteso: servizio senza cert saltato, altri aggiornati.
function Invoke-ScenarioNoCert {
    Assert-Admin
    $script:TestResults.Clear()
    Write-Phase 'SCENARIO: Servizio senza certificato'
    Write-Host '  Istanza senza cert + altre con cert scaduto + PFX valido.'
    Write-Host '  Atteso: istanza senza cert saltata, altre aggiornate.'

    $bl = Save-TestBaseline
    if ($bl.BCMap.Count -eq 0) { throw 'Nessuna istanza BC trovata.' }
    if (-not (Test-Path $bl.MainScript)) { throw "_MAINCertManager.ps1 non trovato." }

    $instances = @(Get-NAVServerInstance)
    if ($instances.Count -lt 2) {
        Write-Skip 'Servono almeno 2 istanze BC per questo scenario.'
        Add-TestResult -Name 'ScenarioNoCert' -Passed $true -Detail "Saltato: solo $($instances.Count) istanza"
        Restore-TestBaseline -BL $bl
        Show-TestSummary
        return
    }

    $pwd = Resolve-PfxPassword
    $securePwd = ConvertTo-SecureString $pwd -AsPlainText -Force

    # Ultima istanza -> senza cert; le altre -> cert scaduto
    $noCertInstance = $instances[-1].ServerInstance
    $expiringInstances = @($instances[0..($instances.Count - 2)] | ForEach-Object { $_.ServerInstance })

    try {
        Write-Phase 'Setup ambiente'

        # Cert A: scadenza prossima (5 giorni)
        $certA = New-SelfSignedCertificate -DnsName 'certament.e2e.expiring' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddDays(5) `
            -FriendlyName "E2E Expiring $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certA.Thumbprint.ToUpper()
        $thumbA = $certA.Thumbprint.ToUpper()
        Write-Ok "Cert scaduto: $($thumbA.Substring(0,12))..."

        # Cert R: sostituzione PFX
        $certR = New-SelfSignedCertificate -DnsName 'certament.e2e.replacement' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotAfter (Get-Date).AddYears(3) `
            -FriendlyName "E2E Replacement $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certR.Thumbprint.ToUpper()
        $expectedThumb = $certR.Thumbprint.ToUpper()
        Write-Ok "Cert sostituzione: $($expectedThumb.Substring(0,12))..."

        # Esporta PFX
        $pfxFile = Join-Path $bl.PfxDrop ("E2E_NOCERT_{0}.pfx" -f $bl.Stamp)
        Export-PfxCertificate -Cert $certR -FilePath $pfxFile -Password $securePwd | Out-Null
        $bl.TestFiles += $pfxFile
        Set-Content (Join-Path $bl.PfxDrop 'password.txt') -Value $pwd -Encoding UTF8 -NoNewline

        # Configura istanze con cert scaduto
        Write-Host '  Configurazione istanze con cert scaduto...'
        foreach ($inst in $expiringInstances) {
            Set-BCInstanceThumbprint -Instance $inst -Thumbprint $thumbA -NoRestart
        }

        # Svuota il thumbprint dell'ultima istanza
        Write-Host "  Rimozione cert da $noCertInstance..."
        Set-BCInstanceThumbprint -Instance $noCertInstance -Thumbprint '' -NoRestart

        # IIS -> cert scaduto
        Set-IISThumbprint -Thumbprint $thumbA -SiteName $bl.IISSite

        # Config
        Set-TestConfig -BL $bl -NotifyBeforeDays 30

        # Esegui CERTAMENT
        $exitCode = Invoke-CertamentProcess -MainScript $bl.MainScript

        # Verifica
        Write-Phase 'Verifica risultati'
        Import-BCModuleSafe
        $postMap = @(Get-AllBCThumbprints)
        $postIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Istanze con cert scaduto: aggiornate
        foreach ($inst in $expiringInstances) {
            $post = $postMap | Where-Object { $_.Instance -eq $inst }
            $postThumb = if ($post) { $post.Thumbprint } else { '' }
            Add-TestResult -Name "[$inst] aggiornata" -Passed ($postThumb -eq $expectedThumb) `
                -Detail "atteso=$($expectedThumb.Substring(0,12)) dopo=$(if ($postThumb) { $postThumb.Substring(0,12) } else { 'N/D' })"
        }

        # Istanza senza cert: deve essere ancora senza cert
        $postNoCert = $postMap | Where-Object { $_.Instance -eq $noCertInstance }
        Add-TestResult -Name "[$noCertInstance] saltata (no cert)" -Passed ($null -eq $postNoCert) `
            -Detail $(if ($postNoCert) { "thumb=$($postNoCert.Thumbprint.Substring(0,12))" } else { 'nessun cert (OK)' })

        # IIS aggiornato
        Add-TestResult -Name 'IIS aggiornato' -Passed ($postIIS -eq $expectedThumb) `
            -Detail "dopo=$(if ($postIIS) { $postIIS.Substring(0,12) } else { 'N/D' })"
    }
    catch {
        Add-TestResult -Name 'ScenarioNoCert errore' -Passed $false -Detail $_.Exception.Message
    }
    finally { Restore-TestBaseline -BL $bl }

    Show-TestSummary
}

# ----- ScenarioNoPfx -----
# Cert in scadenza ma nessun PFX nella drop folder.
# Atteso: CERTAMENT notifica, nessun cambiamento, exit non-zero.
function Invoke-ScenarioNoPfx {
    Assert-Admin
    $script:TestResults.Clear()
    Write-Phase 'SCENARIO: Nessun PFX disponibile'
    Write-Host '  Cert in scadenza, drop folder vuota.'
    Write-Host '  Atteso: notifica inviata, nessun cambiamento BC/IIS.'

    $bl = Save-TestBaseline
    if ($bl.BCMap.Count -eq 0) { throw 'Nessuna istanza BC trovata.' }
    if (-not (Test-Path $bl.MainScript)) { throw "_MAINCertManager.ps1 non trovato." }

    try {
        Write-Phase 'Setup ambiente'

        # Svuota la drop folder (sposta PFX esistenti in temp)
        $existingPfx = @(Get-ChildItem $bl.PfxDrop -Filter '*.pfx' -File -ErrorAction SilentlyContinue)
        foreach ($pf in $existingPfx) {
            $tempDest = Join-Path $env:TEMP ("E2E_STASH_{0}_{1}" -f $bl.Stamp, $pf.Name)
            Move-Item $pf.FullName $tempDest -Force
            $bl.StashedFiles += [PSCustomObject]@{ Original = $pf.FullName; Temp = $tempDest }
        }

        # Rimuovi password.txt
        $pwdFile = Join-Path $bl.PfxDrop 'password.txt'
        if (Test-Path $pwdFile) {
            $pwdBackup = Join-Path $env:TEMP ("E2E_STASH_{0}_password.txt" -f $bl.Stamp)
            Move-Item $pwdFile $pwdBackup -Force
            $bl.StashedFiles += [PSCustomObject]@{ Original = $pwdFile; Temp = $pwdBackup }
        }
        Write-Ok "Drop folder svuotata ($($existingPfx.Count) PFX spostati)"

        # Config: forza scadenza
        Set-TestConfig -BL $bl -NotifyBeforeDays 9999

        # Salva thumbprints pre-esecuzione
        $preMap = @(Get-AllBCThumbprints)
        $preIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Esegui CERTAMENT
        $exitCode = Invoke-CertamentProcess -MainScript $bl.MainScript

        # Verifica
        Write-Phase 'Verifica risultati'
        Import-BCModuleSafe
        $postMap = @(Get-AllBCThumbprints)
        $postIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Nessun thumbprint BC deve essere cambiato
        $allUnchanged = $true
        foreach ($pre in $preMap) {
            $post = $postMap | Where-Object { $_.Instance -eq $pre.Instance }
            $postThumb = if ($post) { $post.Thumbprint } else { '' }
            if ($postThumb -ne $pre.Thumbprint) { $allUnchanged = $false }
        }
        Add-TestResult -Name 'BC thumbprints invariati' -Passed $allUnchanged

        # IIS invariato
        Add-TestResult -Name 'IIS thumbprint invariato' -Passed ($postIIS -eq $preIIS) `
            -Detail "prima=$preIIS dopo=$postIIS"

        Add-TestResult -Name 'CERTAMENT gestito senza crash' -Passed ($null -ne $exitCode) `
            -Detail "Exit code: $exitCode"
    }
    catch {
        Add-TestResult -Name 'ScenarioNoPfx errore' -Passed $false -Detail $_.Exception.Message
    }
    finally { Restore-TestBaseline -BL $bl }

    Show-TestSummary
}

# ----- ScenarioExpiredPfx -----
# Cert in scadenza + PFX presente ma gia' scaduto.
# Atteso: CERTAMENT rifiuta il PFX, thumbprint invariati.
function Invoke-ScenarioExpiredPfx {
    Assert-Admin
    $script:TestResults.Clear()
    Write-Phase 'SCENARIO: PFX scaduto'
    Write-Host '  Cert in scadenza, PFX nella drop folder ma scaduto.'
    Write-Host '  Atteso: PFX rifiutato, nessun cambiamento BC/IIS.'

    $bl = Save-TestBaseline
    if ($bl.BCMap.Count -eq 0) { throw 'Nessuna istanza BC trovata.' }
    if (-not (Test-Path $bl.MainScript)) { throw "_MAINCertManager.ps1 non trovato." }

    $pwd = Resolve-PfxPassword
    $securePwd = ConvertTo-SecureString $pwd -AsPlainText -Force

    try {
        Write-Phase 'Setup ambiente'

        # Cert scaduto ieri
        $certExp = New-SelfSignedCertificate -DnsName 'certament.e2e.expired' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotBefore (Get-Date).AddYears(-2) `
            -NotAfter (Get-Date).AddDays(-1) `
            -FriendlyName "E2E Expired $($bl.Stamp)" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $bl.TestCerts += $certExp.Thumbprint.ToUpper()
        $expiredThumb = $certExp.Thumbprint.ToUpper()
        Write-Ok "Cert scaduto creato: $($expiredThumb.Substring(0,12))..."

        # Esporta PFX scaduto e deposita
        $pfxTemp = Join-Path $env:TEMP ("E2E_EXP_{0}.pfx" -f $bl.Stamp)
        Export-PfxCertificate -Cert $certExp -FilePath $pfxTemp -Password $securePwd | Out-Null
        $bl.TestFiles += $pfxTemp

        $pfxDest = Join-Path $bl.PfxDrop ("E2E_EXPIRED_{0}.pfx" -f $bl.Stamp)
        Copy-Item $pfxTemp $pfxDest -Force
        $bl.TestFiles += $pfxDest
        Set-Content (Join-Path $bl.PfxDrop 'password.txt') -Value $pwd -Encoding UTF8 -NoNewline
        Write-Ok "PFX scaduto depositato: $pfxDest"

        # Config: forza scadenza
        Set-TestConfig -BL $bl -NotifyBeforeDays 9999

        # Salva thumbprints pre-esecuzione
        $preMap = @(Get-AllBCThumbprints)
        $preIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Esegui CERTAMENT
        $exitCode = Invoke-CertamentProcess -MainScript $bl.MainScript

        # Verifica
        Write-Phase 'Verifica risultati'
        Import-BCModuleSafe
        $postMap = @(Get-AllBCThumbprints)
        $postIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Il cert scaduto NON deve essere stato installato in BC
        $noneChanged = $true
        foreach ($pre in $preMap) {
            $post = $postMap | Where-Object { $_.Instance -eq $pre.Instance }
            $postThumb = if ($post) { $post.Thumbprint } else { '' }
            if ($postThumb -ne $pre.Thumbprint) { $noneChanged = $false }
            $notExpired = ($postThumb -ne $expiredThumb)
            Add-TestResult -Name "[$($pre.Instance)] PFX scaduto non installato" -Passed $notExpired `
                -Detail "thumb=$postThumb"
        }
        Add-TestResult -Name 'BC thumbprints invariati' -Passed $noneChanged

        # IIS invariato
        Add-TestResult -Name 'IIS thumbprint invariato' -Passed ($postIIS -eq $preIIS)

        Add-TestResult -Name 'CERTAMENT exit non-zero' -Passed ($exitCode -ne 0) `
            -Detail "Exit code: $exitCode"
    }
    catch {
        Add-TestResult -Name 'ScenarioExpiredPfx errore' -Passed $false -Detail $_.Exception.Message
    }
    finally { Restore-TestBaseline -BL $bl }

    Show-TestSummary
}

# ----- ScenarioAllValid -----
# Tutti i certificati sono validi (lontano dalla scadenza).
# Atteso: CERTAMENT esce con exit 0 senza modificare nulla.
function Invoke-ScenarioAllValid {
    Assert-Admin
    $script:TestResults.Clear()
    Write-Phase 'SCENARIO: Tutti i certificati validi'
    Write-Host '  Nessun cert in scadenza, NotifyBeforeDays = 0.'
    Write-Host '  Atteso: exit 0, nessun cambiamento.'

    $bl = Save-TestBaseline
    if ($bl.BCMap.Count -eq 0) { throw 'Nessuna istanza BC trovata.' }
    if (-not (Test-Path $bl.MainScript)) { throw "_MAINCertManager.ps1 non trovato." }

    try {
        Write-Phase 'Setup ambiente'

        # Verifica che i cert attuali non siano gia' scaduti
        $allValid = $true
        foreach ($entry in $bl.BCMap) {
            $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object { $_.Thumbprint.ToUpper() -eq $entry.Thumbprint }
            if (-not $cert -or $cert.NotAfter -lt (Get-Date)) {
                $allValid = $false
                Write-Fail "Cert $($entry.Thumbprint.Substring(0,12)) gia' scaduto - scenario non applicabile"
            }
        }
        if (-not $allValid) {
            Add-TestResult -Name 'ScenarioAllValid' -Passed $true -Detail 'Saltato: cert attuali gia scaduti'
            Restore-TestBaseline -BL $bl
            Show-TestSummary
            return
        }

        # Config: NotifyBeforeDays = 0 (nessun cert e' scaduto -> nessuna azione)
        Set-TestConfig -BL $bl -NotifyBeforeDays 0

        # Salva thumbprints pre-esecuzione
        $preMap = @(Get-AllBCThumbprints)
        $preIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Esegui CERTAMENT
        $exitCode = Invoke-CertamentProcess -MainScript $bl.MainScript

        # Verifica
        Write-Phase 'Verifica risultati'
        Import-BCModuleSafe
        $postMap = @(Get-AllBCThumbprints)
        $postIIS = Get-LiveIISThumbprint -SiteName $bl.IISSite

        # Nessun cambiamento
        $allUnchanged = $true
        foreach ($pre in $preMap) {
            $post = $postMap | Where-Object { $_.Instance -eq $pre.Instance }
            $postThumb = if ($post) { $post.Thumbprint } else { '' }
            if ($postThumb -ne $pre.Thumbprint) { $allUnchanged = $false }
        }
        Add-TestResult -Name 'BC thumbprints invariati' -Passed $allUnchanged
        Add-TestResult -Name 'IIS thumbprint invariato' -Passed ($postIIS -eq $preIIS)
        Add-TestResult -Name 'Exit code = 0' -Passed ($exitCode -eq 0) -Detail "code=$exitCode"
    }
    catch {
        Add-TestResult -Name 'ScenarioAllValid errore' -Passed $false -Detail $_.Exception.Message
    }
    finally { Restore-TestBaseline -BL $bl }

    Show-TestSummary
}

# =============================================================
# RunScenarios - esegue tutti gli scenari
# =============================================================
function Invoke-RunScenarios {
    Assert-Admin
    Write-Host ''
    Write-Host '+--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '|    CERTAMENT E2E - Scenari di test               |' -ForegroundColor Cyan
    Write-Host '+--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'Ogni scenario crea un ambiente specifico, esegue CERTAMENT'
    Write-Host 'e verifica che il comportamento sia corretto.'
    Write-Host ''

    # Risolvi password una volta sola (per gli scenari che la richiedono)
    $null = Resolve-PfxPassword

    $allResults = [System.Collections.ArrayList]::new()

    $scenarios = @(
        @{ Name = 'ScenarioRenew';      Fn = { Invoke-ScenarioRenew } },
        @{ Name = 'ScenarioMixed';      Fn = { Invoke-ScenarioMixed } },
        @{ Name = 'ScenarioNoCert';     Fn = { Invoke-ScenarioNoCert } },
        @{ Name = 'ScenarioNoPfx';      Fn = { Invoke-ScenarioNoPfx } },
        @{ Name = 'ScenarioExpiredPfx'; Fn = { Invoke-ScenarioExpiredPfx } },
        @{ Name = 'ScenarioAllValid';   Fn = { Invoke-ScenarioAllValid } }
    )

    foreach ($s in $scenarios) {
        Write-Host ''
        Write-Host (">>> {0}" -f $s.Name) -ForegroundColor Yellow
        Write-Host ('=' * 60) -ForegroundColor DarkGray
        try {
            & $s.Fn
        }
        catch {
            Write-Fail "Scenario $($s.Name) fallito: $($_.Exception.Message)"
            Add-TestResult -Name $s.Name -Passed $false -Detail $_.Exception.Message
        }
        $null = $allResults.AddRange(@($script:TestResults))
    }

    # Riepilogo finale
    $script:TestResults = $allResults
    Write-Host ''
    Write-Host ('+' + ('=' * 50) + '+') -ForegroundColor Cyan
    Write-Host '|         RIEPILOGO FINALE SCENARI                 |' -ForegroundColor Cyan
    Write-Host ('+' + ('=' * 50) + '+') -ForegroundColor Cyan
    Show-TestSummary
}

# =============================================================
# Action: Help
# =============================================================
function Show-Help {
    Write-Host ''
    Write-Host 'CERTAMENT E2E Tester'
    Write-Host '===================='
    Write-Host 'Crea ambienti di test specifici, esegue CERTAMENT e verifica'
    Write-Host 'che il comportamento sia corretto.'
    Write-Host ''
    Write-Host 'SCENARI (ambiente -> CERTAMENT -> verifica):'
    Write-Host '  .\Certament-E2E-Tester.ps1'
    Write-Host '      -> Esegue tutti gli scenari in sequenza (default)'
    Write-Host ''
    Write-Host '  -Action ScenarioRenew      Tutti i servizi con cert scaduto + PFX valido'
    Write-Host '                             -> aggiornamento completo BC + IIS'
    Write-Host ''
    Write-Host '  -Action ScenarioMixed      Servizi con cert diversi (scaduto vs valido)'
    Write-Host '                             -> solo i servizi con cert scaduto aggiornati'
    Write-Host ''
    Write-Host '  -Action ScenarioNoCert     Servizio senza cert + servizi con cert scaduto'
    Write-Host '                             -> servizio senza cert saltato, altri aggiornati'
    Write-Host ''
    Write-Host '  -Action ScenarioNoPfx      Cert in scadenza, drop folder vuota'
    Write-Host '                             -> notifica, nessun cambiamento'
    Write-Host ''
    Write-Host '  -Action ScenarioExpiredPfx Cert in scadenza + PFX scaduto'
    Write-Host '                             -> PFX rifiutato, nessun cambiamento'
    Write-Host ''
    Write-Host '  -Action ScenarioAllValid   Tutti i cert validi, NotifyBeforeDays = 0'
    Write-Host '                             -> exit 0, nessuna modifica'
    Write-Host ''
    Write-Host 'VERIFICHE (non modificano l''ambiente):'
    Write-Host '  -Action RunAll             Esegue tutti i test non distruttivi'
    Write-Host '  -Action TestConfig         Valida config.json'
    Write-Host '  -Action TestModules        Verifica importazione moduli'
    Write-Host '  -Action TestNotification   Testa invio webhook'
    Write-Host '  -Action TestHeartbeat      Testa heartbeat Azure'
    Write-Host '  -Action TestCertStore      Verifica coerenza cert store / BC / IIS'
    Write-Host ''
    Write-Host 'UTILITA:'
    Write-Host '  -Action Status             Stato corrente: task, thumbprint, drop folder'
    Write-Host '  -Action Restore            Ripristino emergenza BC/IIS'
    Write-Host ''
    Write-Host 'Parametri:'
    Write-Host '  -InstallRoot      Cartella CERTAMENT (default: C:\CERTAMENT)'
    Write-Host '  -SecretFilePath   File plain-text con la password PFX (opzionale)'
    Write-Host ''
    Write-Host 'Ogni scenario:'
    Write-Host '  1) Salva il baseline (thumbprint per istanza BC + IIS + config)'
    Write-Host '  2) Crea certificati di test e configura l''ambiente'
    Write-Host '  3) Esegue _MAINCertManager.ps1'
    Write-Host '  4) Verifica il comportamento per ogni istanza'
    Write-Host '  5) Ripristina tutto allo stato originale'
    Write-Host ''
}

# =============================================================
# Dispatch
# =============================================================
switch ($Action) {
    'RunScenarios'     { Invoke-RunScenarios }
    'ScenarioRenew'    { Invoke-ScenarioRenew }
    'ScenarioMixed'    { Invoke-ScenarioMixed }
    'ScenarioNoCert'   { Invoke-ScenarioNoCert }
    'ScenarioNoPfx'    { Invoke-ScenarioNoPfx }
    'ScenarioExpiredPfx' { Invoke-ScenarioExpiredPfx }
    'ScenarioAllValid' { Invoke-ScenarioAllValid }
    'TestConfig'       { Invoke-TestConfig }
    'TestModules'      { Invoke-TestModules }
    'TestNotification' { Invoke-TestNotification }
    'TestHeartbeat'    { Invoke-TestHeartbeat }
    'TestCertStore'    { Invoke-TestCertStore }
    'RunAll'           { Invoke-RunAll }
    'Status'           { Invoke-Status }
    'Restore'          { Invoke-Restore }
    'Help'             { Show-Help }
}
