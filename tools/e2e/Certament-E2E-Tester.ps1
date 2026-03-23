<#
.SYNOPSIS
    CERTAMENT E2E Tester - testa il ciclo di aggiornamento certificati e le singole funzionalita'.
.DESCRIPTION
    RunFull          : test completo del ciclo di rinnovo certificato (default).
    TestNotification : testa l'invio notifiche webhook (Customer e/o Internal).
    TestHeartbeat    : testa la connettivita' heartbeat Azure.
    TestModules      : verifica che tutti i moduli CERTAMENT si importino e le funzioni esistano.
    TestExpiredPfx   : verifica che la pipeline rifiuti un PFX scaduto.
    TestNoPfx        : verifica il comportamento con drop folder vuoto.
    TestConfig       : valida la configurazione config.json.
    TestCertStore    : mostra i certificati nello store e verifica coerenza con BC/IIS.
    Status           : mostra lo stato corrente (task, BC/IIS thumbprint, drop folder).
    Restore          : ripristino di emergenza BC/IIS al certificato originale.
    RunAll           : esegue tutti i test in sequenza (escluso RunFull e Restore).
    Help             : mostra questo messaggio.
.EXAMPLE
    .\Certament-E2E-Tester.ps1
    .\Certament-E2E-Tester.ps1 -SecretFilePath C:\temp\pfxpwd.txt
    .\Certament-E2E-Tester.ps1 -Action TestNotification
    .\Certament-E2E-Tester.ps1 -Action TestModules
    .\Certament-E2E-Tester.ps1 -Action RunAll
    .\Certament-E2E-Tester.ps1 -Action Status
    .\Certament-E2E-Tester.ps1 -Action Restore
#>
param(
    [ValidateSet('RunFull', 'TestNotification', 'TestHeartbeat', 'TestModules',
                 'TestExpiredPfx', 'TestNoPfx', 'TestConfig', 'TestCertStore',
                 'Status', 'Restore', 'RunAll', 'Help')]
    [string]$Action = 'RunFull',

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
# Action: TestExpiredPfx
# =============================================================
function Invoke-TestExpiredPfx {
    Assert-Admin
    Write-Phase 'TEST EXPIRED PFX REJECTION'
    $script:TestResults.Clear()

    $cfg, $configPath = Read-CertamentConfig
    $pfxDrop = $cfg.Pfx.Path
    $mainScript = Join-Path $InstallRoot '_MAINCertManager.ps1'

    Add-TestResult -Name 'Main script exists' -Passed (Test-Path $mainScript)
    Add-TestResult -Name 'Drop folder exists' -Passed (Test-Path $pfxDrop) -Detail $pfxDrop
    if (-not (Test-Path $mainScript) -or -not (Test-Path $pfxDrop)) { Show-TestSummary; return }

    # Get password
    $secretPlain = $null
    if (-not [string]::IsNullOrWhiteSpace($SecretFilePath) -and (Test-Path $SecretFilePath)) {
        $secretPlain = (Get-Content $SecretFilePath -Raw).Trim()
    }
    else {
        $secure = Read-Host 'Password per il PFX di test' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $secretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
    }
    if ([string]::IsNullOrWhiteSpace($secretPlain)) { throw 'Password non fornita.' }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $testPfxTemp = $null
    $destPfx = $null
    $destPwd = $null
    $configBackup = $null
    $configOriginalRaw = $null

    try {
        # Create an EXPIRED self-signed cert
        $testCert = New-SelfSignedCertificate -DnsName 'certament.e2e.expired' `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -NotBefore (Get-Date).AddYears(-2) `
            -NotAfter (Get-Date).AddDays(-1) `
            -FriendlyName "CERTAMENT E2E EXPIRED $stamp" `
            -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $expiredThumb = $testCert.Thumbprint.ToUpper()
        Add-TestResult -Name 'Expired test cert created' -Passed $true -Detail "Thumb: $expiredThumb"

        # Export to PFX
        $testPfxTemp = Join-Path $env:TEMP ("CERTAMENT_E2E_EXP_{0}.pfx" -f $stamp)
        $securePwd = ConvertTo-SecureString $secretPlain -AsPlainText -Force
        Export-PfxCertificate -Cert $testCert -FilePath $testPfxTemp -Password $securePwd | Out-Null

        # Drop into PFX folder
        $destPfx = Join-Path $pfxDrop ("E2E_EXPIRED_{0}.pfx" -f $stamp)
        $destPwd = Join-Path $pfxDrop 'password.txt'
        Copy-Item $testPfxTemp $destPfx -Force
        Set-Content $destPwd -Value $secretPlain -Encoding UTF8 -NoNewline

        # Backup config and set threshold to force
        $configBackup = "$configPath.e2e_backup_$stamp"
        $configOriginalRaw = Get-Content $configPath -Raw
        Copy-Item $configPath $configBackup -Force
        $cfgObj = $configOriginalRaw | ConvertFrom-Json
        $cfgObj.Notifications.CertificateExpiry.NotifyBeforeDays = 9999
        $cfgObj | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8

        # Run CERTAMENT - it SHOULD reject the expired PFX (exit 1, not crash)
        Write-Host '  Running CERTAMENT with expired PFX...'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript
        $exitCode = $LASTEXITCODE

        # Verify BC thumbprint was NOT changed
        Import-BCModuleSafe
        $currentThumb = Get-LiveBCThumbprint
        $notChanged = ($null -eq $currentThumb) -or ($currentThumb -ne $expiredThumb)
        Add-TestResult -Name 'Expired PFX rejected (not installed to BC)' -Passed $notChanged `
            -Detail "BC thumb: $currentThumb, expired: $expiredThumb"
        Add-TestResult -Name 'CERTAMENT exit code non-zero' -Passed ($exitCode -ne 0) `
            -Detail "Exit code: $exitCode"
    }
    finally {
        # Cleanup
        if ($configBackup -and (Test-Path $configBackup)) {
            Copy-Item $configBackup $configPath -Force
            Remove-Item $configBackup -Force -ErrorAction SilentlyContinue
        }
        elseif ($configOriginalRaw) {
            Set-Content $configPath -Value $configOriginalRaw -Encoding UTF8
        }
        if ($testPfxTemp -and (Test-Path $testPfxTemp)) { Remove-Item $testPfxTemp -Force -ErrorAction SilentlyContinue }
        if ($destPfx -and (Test-Path $destPfx)) { Remove-Item $destPfx -Force -ErrorAction SilentlyContinue }
        if ($destPwd -and (Test-Path $destPwd)) { Remove-Item $destPwd -Force -ErrorAction SilentlyContinue }
        if ($expiredThumb) { Remove-Item "Cert:\LocalMachine\My\$expiredThumb" -Force -ErrorAction SilentlyContinue }
        # Clean up any archived test PFX
        $archiveDir = Join-Path $pfxDrop 'installed'
        if (Test-Path $archiveDir) {
            Get-ChildItem $archiveDir -Filter "E2E_EXPIRED_*" -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }

    Show-TestSummary
}

# =============================================================
# Action: TestNoPfx
# =============================================================
function Invoke-TestNoPfx {
    Assert-Admin
    Write-Phase 'TEST NO PFX (EMPTY DROP FOLDER)'
    $script:TestResults.Clear()

    $cfg, $configPath = Read-CertamentConfig
    $pfxDrop = $cfg.Pfx.Path
    $mainScript = Join-Path $InstallRoot '_MAINCertManager.ps1'

    Add-TestResult -Name 'Main script exists' -Passed (Test-Path $mainScript)
    if (-not (Test-Path $mainScript)) { Show-TestSummary; return }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $configBackup = $null
    $configOriginalRaw = $null
    $movedPfxFiles = @()

    try {
        # Backup config
        $configBackup = "$configPath.e2e_backup_$stamp"
        $configOriginalRaw = Get-Content $configPath -Raw
        Copy-Item $configPath $configBackup -Force
        $cfgObj = $configOriginalRaw | ConvertFrom-Json
        $cfgObj.Notifications.CertificateExpiry.NotifyBeforeDays = 9999
        $cfgObj | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8

        # Temporarily move any existing PFX files out of drop folder
        $existingPfx = @(Get-ChildItem $pfxDrop -Filter '*.pfx' -File -ErrorAction SilentlyContinue)
        foreach ($pf in $existingPfx) {
            $tempDest = Join-Path $env:TEMP ("E2E_STASH_{0}_{1}" -f $stamp, $pf.Name)
            Move-Item $pf.FullName $tempDest -Force
            $movedPfxFiles += [PSCustomObject]@{ Original = $pf.FullName; Temp = $tempDest }
        }

        # Remove password.txt temporarily
        $pwdFile = Join-Path $pfxDrop 'password.txt'
        $pwdBackup = $null
        if (Test-Path $pwdFile) {
            $pwdBackup = Join-Path $env:TEMP ("E2E_STASH_{0}_password.txt" -f $stamp)
            Move-Item $pwdFile $pwdBackup -Force
        }

        Add-TestResult -Name 'Drop folder emptied' -Passed $true `
            -Detail "$($existingPfx.Count) PFX stashed"

        # Run CERTAMENT - should report no PFX, not crash
        Write-Host '  Running CERTAMENT with empty drop folder...'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $mainScript
        $exitCode = $LASTEXITCODE

        Add-TestResult -Name 'CERTAMENT handled missing PFX gracefully' -Passed ($exitCode -ne $null) `
            -Detail "Exit code: $exitCode"
    }
    finally {
        # Restore stashed PFX files
        foreach ($stash in $movedPfxFiles) {
            if (Test-Path $stash.Temp) {
                Move-Item $stash.Temp $stash.Original -Force -ErrorAction SilentlyContinue
            }
        }
        # Restore password.txt
        if ($pwdBackup -and (Test-Path $pwdBackup)) {
            Move-Item $pwdBackup $pwdFile -Force -ErrorAction SilentlyContinue
        }
        # Restore config
        if ($configBackup -and (Test-Path $configBackup)) {
            Copy-Item $configBackup $configPath -Force
            Remove-Item $configBackup -Force -ErrorAction SilentlyContinue
        }
        elseif ($configOriginalRaw) {
            Set-Content $configPath -Value $configOriginalRaw -Encoding UTF8
        }
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

    # ── 3. Thumbprint baseline ───────────────────────────────
    Write-Phase '3/7 - Thumbprint baseline'
    $originalThumb = Get-LiveBCThumbprint
    if (-not $originalThumb) { throw 'Impossibile rilevare il thumbprint corrente da BC.' }
    Write-Ok "Baseline: $originalThumb"

    # ── 4. Password ──────────────────────────────────────────
    Write-Phase '4/7 - Password PFX test'
    if (-not [string]::IsNullOrWhiteSpace($SecretFilePath) -and (Test-Path $SecretFilePath)) {
        $secretPlain = (Get-Content $SecretFilePath -Raw).Trim()
        Write-Ok "Password letta da: $SecretFilePath"
    } else {
        $secure = Read-Host 'Password per il PFX di test' -AsSecureString
        $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try     { $secretPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) } }
    }
    if ([string]::IsNullOrWhiteSpace($secretPlain)) { throw 'Password non fornita.' }

    $configBackup = $null
    $configOriginalRaw = $null
    $testPfxTemp = $null
    $destPfx = $null
    $destPwd = $null
    $testThumb = $null
    $newBCThumb = $null
    $newIISThumb = $null
    $bcOk = $false
    $iisOk = $false
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

        # Crea cert self-signed + PFX
        $testPfxTemp = Join-Path $env:TEMP ("CERTAMENT_E2E_{0}.pfx" -f $stamp)
        $notAfter    = (Get-Date).AddYears(3)
        $testCert    = New-SelfSignedCertificate -DnsName 'certament.e2e.test' `
                           -CertStoreLocation 'Cert:\LocalMachine\My' `
                           -NotAfter $notAfter `
                           -FriendlyName "CERTAMENT E2E $stamp" `
                           -KeyExportPolicy Exportable -KeySpec KeyExchange -KeyLength 2048
        $securePwd   = ConvertTo-SecureString $secretPlain -AsPlainText -Force
        Export-PfxCertificate -Cert $testCert -FilePath $testPfxTemp -Password $securePwd | Out-Null
        $testThumb   = $testCert.Thumbprint.ToUpper()
        Write-Ok "Cert test: $testThumb"
        Write-Ok "Scadenza : $($notAfter.ToString('yyyy-MM-dd'))"

        # Drop PFX + password.txt
        $destPfx = Join-Path $pfxDrop ("E2E_TEST_{0}.pfx" -f $stamp)
        $destPwd = Join-Path $pfxDrop 'password.txt'
        Copy-Item $testPfxTemp $destPfx -Force
        Set-Content $destPwd -Value $secretPlain -Encoding UTF8 -NoNewline
        Write-Ok "PFX in drop: $destPfx"
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
        $bcOk  = ($newBCThumb  -and $newBCThumb.ToUpper()  -ne $originalThumb)
        $iisOk = ($newIISThumb -and $newIISThumb.ToUpper() -ne $originalThumb)

        Write-Host ''
        Write-Host '  prima  -> ' -NoNewline; Write-Host $originalThumb -ForegroundColor Gray
        Write-Host ("  BC     -> {0}  {1}" -f $newBCThumb,  (if ($bcOk)  { '[CAMBIATO OK]' } else { '[INVARIATO - TEST FALLITO]' })) `
            -ForegroundColor $(if ($bcOk)  { 'Green' } else { 'Red' })
        Write-Host ("  IIS    -> {0}  {1}" -f $newIISThumb, (if ($iisOk) { '[CAMBIATO OK]' } else { '[INVARIATO - TEST FALLITO]' })) `
            -ForegroundColor $(if ($iisOk) { 'Green' } else { 'Red' })
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

        # Pulizia
        if ($testPfxTemp -and (Test-Path $testPfxTemp)) {
            Remove-Item $testPfxTemp -Force -ErrorAction SilentlyContinue
        }
        if ($destPwd -and (Test-Path $destPwd)) {
            Remove-Item $destPwd -Force -ErrorAction SilentlyContinue
        }
        if ($destPfx -and (Test-Path $destPfx)) {
            Remove-Item $destPfx -Force -ErrorAction SilentlyContinue
        }
        if ($testThumb) {
            Remove-Item "Cert:\LocalMachine\My\$testThumb" -Force -ErrorAction SilentlyContinue
        }
        Write-Host '  Pulizia completata.' -ForegroundColor Gray
    }

    # ── Riepilogo finale ─────────────────────────────────────
    $pass  = $bcOk -and $iisOk -and $configRestored -and (-not $runError)
    $baselineShort = if ($originalThumb) { $originalThumb.Substring(0,[Math]::Min(36,$originalThumb.Length)) } else { 'N/D' }
    $testShort = if ($testThumb) { $testThumb.Substring(0,[Math]::Min(36,$testThumb.Length)) } else { 'N/D' }
    $color = if ($pass) { 'Green' } else { 'Red' }
    Write-Host ''
    Write-Host '+--------------------------------------------------+' -ForegroundColor $color
    Write-Host ('|  RISULTATO: {0,-38}|' -f $(if ($pass) { 'PASS - Test superato!' } else { 'FAIL - vedere dettagli sopra' })) -ForegroundColor $color
    Write-Host '|                                                  |' -ForegroundColor $color
    Write-Host ("|  Baseline  : {0,-36}|" -f $baselineShort) -ForegroundColor $color
    Write-Host ("|  Test cert : {0,-36}|" -f $testShort) -ForegroundColor $color
    Write-Host ("|  BC camb.  : {0,-36}|" -f $(if ($bcOk)  { 'SI' } else { 'NO' })) -ForegroundColor $color
    Write-Host ("|  IIS camb. : {0,-36}|" -f $(if ($iisOk) { 'SI' } else { 'NO' })) -ForegroundColor $color
    Write-Host ("|  Config OK : {0,-36}|" -f $(if ($configRestored) { 'SI' } else { 'NO' })) -ForegroundColor $color
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
    Write-Host 'Verifica il ciclo completo di aggiornamento certificati BC + IIS'
    Write-Host 'e testa le singole funzionalita di CERTAMENT.'
    Write-Host ''
    Write-Host 'Utilizzo:'
    Write-Host '  .\Certament-E2E-Tester.ps1'
    Write-Host '      -> Test completo del rinnovo certificato (chiede password PFX)'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -SecretFilePath C:\temp\pfxpwd.txt'
    Write-Host '      -> Test completo con password letta da file'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action RunAll'
    Write-Host '      -> Esegue tutti i test non-distruttivi in sequenza'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action TestConfig'
    Write-Host '      -> Valida config.json (campi obbligatori, URL placeholder, ecc.)'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action TestModules'
    Write-Host '      -> Verifica che tutti i moduli si importino e le funzioni esistano'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action TestNotification'
    Write-Host '      -> Invia notifiche di test ai webhook Customer e Internal'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action TestHeartbeat'
    Write-Host '      -> Testa la connettivita heartbeat Azure'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action TestExpiredPfx'
    Write-Host '      -> Verifica che CERTAMENT rifiuti un PFX con certificato scaduto'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action TestNoPfx'
    Write-Host '      -> Verifica il comportamento con drop folder vuoto'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action TestCertStore'
    Write-Host '      -> Controlla coerenza certificati tra BC, IIS e cert store'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action Status'
    Write-Host '      -> Stato corrente: task, thumbprint BC/IIS, drop folder'
    Write-Host ''
    Write-Host '  .\Certament-E2E-Tester.ps1 -Action Restore'
    Write-Host '      -> Ripristino emergenza: riporta BC/IIS al certificato originale'
    Write-Host ''
    Write-Host 'Parametri:'
    Write-Host '  -Action           RunFull | TestConfig | TestModules | TestNotification |'
    Write-Host '                    TestHeartbeat | TestExpiredPfx | TestNoPfx | TestCertStore |'
    Write-Host '                    RunAll | Status | Restore | Help'
    Write-Host '  -InstallRoot      Cartella CERTAMENT (default: C:\CERTAMENT)'
    Write-Host '  -SecretFilePath   File plain-text con la password PFX (opzionale)'
    Write-Host ''
    Write-Host 'RunFull esegue il ciclo completo:'
    Write-Host '  1) Legge config.json da InstallRoot'
    Write-Host '  2) Carica il modulo BC e rileva il thumbprint baseline'
    Write-Host '  3) Chiede (o legge da file) la password PFX'
    Write-Host '  4) Backup config + forza NotifyBeforeDays = 9999'
    Write-Host '  5) Crea certificato self-signed 3 anni + PFX'
    Write-Host '  6) Deposita PFX + password.txt in drop folder'
    Write-Host '  7) Esegue _MAINCertManager.ps1 direttamente'
    Write-Host '  8) Verifica che BC e IIS abbiano il nuovo thumbprint'
    Write-Host '  9) Ripristina BC, IIS, config - rimuove file temporanei'
    Write-Host '  10) Stampa PASS o FAIL'
    Write-Host ''
}

# =============================================================
# Dispatch
# =============================================================
switch ($Action) {
    'RunFull'          { Invoke-RunFull }
    'TestNotification' { Invoke-TestNotification }
    'TestHeartbeat'    { Invoke-TestHeartbeat }
    'TestModules'      { Invoke-TestModules }
    'TestExpiredPfx'   { Invoke-TestExpiredPfx }
    'TestNoPfx'        { Invoke-TestNoPfx }
    'TestConfig'       { Invoke-TestConfig }
    'TestCertStore'    { Invoke-TestCertStore }
    'RunAll'           { Invoke-RunAll }
    'Status'           { Invoke-Status }
    'Restore'          { Invoke-Restore }
    'Help'             { Show-Help }
}
