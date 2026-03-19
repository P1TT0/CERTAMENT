param(
    [string]$OriginalThumbprint = 'A5891105744CD279BAB93194C2A5032CD59AEB62',
    [string]$TestThumbprint = '',
    [string[]]$BCInstances = @('PROD_NUP', 'PROD_NUP2'),
    [string]$BCModulePath = 'C:\Program Files\Microsoft Dynamics 365 Business Central\260\Service\Microsoft.Dynamics.Nav.Management.psm1',
    [string]$IISSiteName = 'Microsoft Dynamics 365 Business Central Web Client',
    [string]$ConfigPath = 'C:\CERTAMENT\config.json',
    [int]$ExpectedNotifyBeforeDays = 30,
    [string]$PfxDropPath = 'C:\_install',
    [string[]]$ExpectedPfxNames = @('2027CERT.pfx', '2026CERT.pfx'),
    [string]$TestPfxPattern = 'E2E_TEST*',
    [string]$TempScriptPattern = '_e2e_*.ps1'
)

$originalThumbNormalized = ($OriginalThumbprint -replace '\s', '').ToUpper()
$testThumbNormalized = ($TestThumbprint -replace '\s', '').ToUpper()
$pass = 0
$fail = 0

Write-Host '========== FINAL PRODUCTION VERIFICATION =========='

if (-not [string]::IsNullOrWhiteSpace($testThumbNormalized)) {
    $testCertificate = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
        ($_.Thumbprint -replace '\s', '').ToUpper() -eq $testThumbNormalized
    }
    if (-not $testCertificate) {
        Write-Host 'PASS: Test cert removed from store'; $pass++
    }
    else {
        Write-Host 'FAIL: Test cert still in store'; $fail++
    }
}

$originalCertificate = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    ($_.Thumbprint -replace '\s', '').ToUpper() -eq $originalThumbNormalized
}
if ($originalCertificate) {
    Write-Host ('PASS: Original cert in store - ' + $originalCertificate.Subject); $pass++
}
else {
    Write-Host 'FAIL: Original cert NOT in store'; $fail++
}

Import-Module $BCModulePath -WarningAction SilentlyContinue -ErrorAction Stop
foreach ($instanceName in $BCInstances) {
    $instanceThumb = Get-NAVServerConfiguration -ServerInstance $instanceName -KeyName 'ServicesCertificateThumbprint' -ErrorAction SilentlyContinue
    $instanceState = (Get-NAVServerInstance -ServerInstance $instanceName).State
    $instanceThumbNormalized = ($instanceThumb -replace '\s', '').ToUpper()

    if ($instanceThumbNormalized -eq $originalThumbNormalized -and $instanceState -eq 'Running') {
        Write-Host ('PASS: ' + $instanceName + ' = original thumb, Running'); $pass++
    }
    else {
        Write-Host ('FAIL: ' + $instanceName + ' | Thumb=' + $instanceThumb + ' | State=' + $instanceState); $fail++
    }
}

Import-Module WebAdministration -ErrorAction SilentlyContinue
$httpsBindings = @(Get-WebBinding -Name $IISSiteName -Protocol https -ErrorAction SilentlyContinue)
if ($httpsBindings.Count -eq 0) {
    Write-Host 'FAIL: Nessun binding HTTPS trovato'; $fail++
}
else {
    $allBindingsMatch = $true
    foreach ($binding in $httpsBindings) {
        $bindingThumbNormalized = ($binding.certificateHash -replace '\s', '').ToUpper()
        if ($bindingThumbNormalized -ne $originalThumbNormalized) {
            $allBindingsMatch = $false
            Write-Host ('FAIL: IIS binding ' + $binding.bindingInformation + ' = ' + $binding.certificateHash)
            $fail++
        }
    }

    if ($allBindingsMatch) {
        Write-Host 'PASS: IIS binding(s) = original cert'; $pass++
    }
}

if (Test-Path $ConfigPath) {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if ($config.Notifications.CertificateExpiry.NotifyBeforeDays -eq $ExpectedNotifyBeforeDays) {
        Write-Host ('PASS: Config NotifyBeforeDays = ' + $ExpectedNotifyBeforeDays + ' (restored)'); $pass++
    }
    else {
        Write-Host ('FAIL: Config NotifyBeforeDays = ' + $config.Notifications.CertificateExpiry.NotifyBeforeDays); $fail++
    }
}
else {
    Write-Host ('FAIL: Config not found - ' + $ConfigPath); $fail++
}

$pfxFiles = @(Get-ChildItem $PfxDropPath -Filter '*.pfx' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
$missingPfxFiles = @($ExpectedPfxNames | Where-Object { $_ -notin $pfxFiles })
if ($missingPfxFiles.Count -eq 0) {
    Write-Host 'PASS: Required PFX files restored'; $pass++
}
else {
    Write-Host ('FAIL: Missing PFX files: ' + ($missingPfxFiles -join ', ')); $fail++
}

$testPfxFiles = @(Get-ChildItem $PfxDropPath -Filter $TestPfxPattern -File -ErrorAction SilentlyContinue)
if ($testPfxFiles.Count -eq 0) {
    Write-Host 'PASS: Test PFX cleaned up'; $pass++
}
else {
    Write-Host ('FAIL: Test PFX still present: ' + ($testPfxFiles.Name -join ', ')); $fail++
}

$currentScriptName = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { '' }
$tempScripts = @(Get-ChildItem $PfxDropPath -Filter $TempScriptPattern -File -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -ne $currentScriptName
})
if ($tempScripts.Count -eq 0) {
    Write-Host 'PASS: Temp files cleaned'; $pass++
}
else {
    Write-Host ('FAIL: Temp files: ' + ($tempScripts.Name -join ', ')); $fail++
}

Write-Host "`n========================================="
Write-Host ('RESULT: PASS=' + $pass + ', FAIL=' + $fail)
if ($fail -eq 0) {
    Write-Host 'PRODUCTION FULLY RESTORED - ALL CLEAR'
}
else {
    Write-Host 'WARNING: SOME CHECKS FAILED'
}
Write-Host '========================================='
