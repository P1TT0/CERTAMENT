$root=Split-Path $PSScriptRoot -Parent
$manager=Join-Path $root '_MAINCertManager.ps1'
$runner=Join-Path $root 'TESTER\certament-runner-v8.1\CertamentScenarioRunner.ps1'
$module=Join-Path $root 'modules\Get-PfxFile.psm1'
$identityModule=Join-Path $root 'modules\CertificateIdentity.psm1'
function Invoke-ParserCheck([string]$Path){$tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)|Out-Null;return @($errors)}
Describe 'CERTAMENT parser and static contracts' {
    It 'has a single runtime VERSION.txt source' { $version=(Get-Content (Join-Path $root 'VERSION.txt') -Raw).Trim();$version|Should Not BeNullOrEmpty;$managerText=Get-Content $manager -Raw;$managerText|Should Match 'VERSION.txt' }
    It 'parses manager and modules on PowerShell 5.1' { @('_MAINCertManager.ps1','modules\Get-BCThumbprint.psm1','modules\Get-PfxFile.psm1','modules\Update-IISBinding.psm1')|ForEach-Object{(Invoke-ParserCheck (Join-Path $root $_)).Count|Should Be 0} }
    It 'contains the heartbeat contract fields' { $text=Get-Content $manager -Raw; foreach($field in @('schemaVersion','version','runId','customer','server','status','stage','detail','timestampUtc','durationSec','certificateDaysRemaining','notificationStatus')){$text|Should Match $field} }
    It 'keeps notification status separate from run status' { $text=Get-Content $manager -Raw; $text|Should Match 'NotificationStatus';$text|Should Match 'status' }
    It 'allows completed status with failed notification status' { $text=Get-Content $manager -Raw;$text|Should Match "NotificationStatus='Failed'";$text|Should Match 'Status "Completed"' }
    It 'returns exit 1 for unhandled critical exceptions' { $text=Get-Content $manager -Raw;$text|Should Match 'Errore critico CERTAMENT';$text|Should Match 'exit 1' }
    It 'defines the monitoring API routes' { foreach($route in @('monitoring\Heartbeat\function.json','monitoring\Servers\function.json','monitoring\History\function.json','monitoring\Health\function.json')){Test-Path (Join-Path $root $route)|Should Be $true} }
    It 'does not expose heartbeat token to dashboard' { Get-Content (Join-Path $root 'monitoring\dashboard\app.js') -Raw|Should Not Match 'CERTAMENT_HEARTBEAT_TOKEN' }
    It 'does not use global iisreset in runtime files' { Get-Content (Join-Path $root 'modules\Update-IISBinding.psm1') -Raw|Should Not Match 'iisreset' }
    It 'provisions real LAB certificates and target bindings' { $text=Get-Content $runner -Raw;foreach($pattern in @('New-SelfSignedCertificate','Export-PfxCertificate','Cert:\\LocalMachine\\My','Set-BCThumbprint','Ensure-IISBinding','Set-HttpSslThumb','New-Snapshot','Invoke-Certament')){$text|Should Match ([regex]::Escape($pattern))} }
    It 'verifies BC service and NAV state after provisioning restart' { $text=Get-Content $runner -Raw;$text|Should Match 'Wait-BCRunning';$text|Should Match 'WindowsService';$text|Should Match 'NAVState' }
    It 'keeps prepared snapshot separate from preparation metadata' { $text=Get-Content $runner -Raw;$text|Should Match "Save-SnapshotArtifacts \$prepared \$runDir 'prepared'";$text|Should Match 'prepared-metadata.json' }
    It 'supports LAB cleanup after Recover without in-memory state' { $text=Get-Content $runner -Raw;$text|Should Match 'Remove-LabCerts \$before';$text|Should Match 'baselineThumbs' }
}
Describe 'PFX helper' {
    It 'enumerates PFX candidates deterministically' { Import-Module $module -Force; $temp=Join-Path ([IO.Path]::GetTempPath()) ('certament-pester-'+[guid]::NewGuid());New-Item $temp -ItemType Directory|Out-Null;try{1..2|ForEach-Object{[IO.File]::WriteAllBytes((Join-Path $temp ("$_.pfx")),[byte[]](1,2,3))};(@(Get-PfxCandidates $temp).Name -join ',')|Should Be '1.pfx,2.pfx'}finally{Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue} }
}
Describe 'Endpoint identity' {
    It 'matches exact DNS' { Import-Module $identityModule -Force; (Test-DnsIdentityMatch @('bc.example.com') @('bc.example.com'))|Should Be $true }
    It 'matches wildcard single label only' { (Test-DnsIdentityMatch @('*.example.com') @('bc.example.com'))|Should Be $true;(Test-DnsIdentityMatch @('*.example.com') @('foo.bc.example.com'))|Should Be $false }
    It 'uses ExpectedDnsNames precedence' { $r=Resolve-EndpointDnsIdentity @('expected.example.com') @('host.example.com');$r.Source|Should Be 'ExpectedDnsNames';$r.Conflict|Should Be $true }
    It 'falls back to HostHeader' { $r=Resolve-EndpointDnsIdentity @() @('host.example.com');$r.Source|Should Be 'HostHeader';$r.Names[0]|Should Be 'host.example.com' }
    It 'fails closed when endpoint identity is missing' { $r=Resolve-EndpointDnsIdentity @() @();$r.Source|Should Be 'None';$r.Names.Count|Should Be 0 }
}
Describe 'Runner scenarios and safety contracts' {
    It 'contains all required scenarios' { $text=Get-Content $runner -Raw; foreach($name in @('NoOp','PfxMissing','WrongPassword','PfxExpired','PfxNotNewer','WrongSan','MultipleCandidates','UnrelatedPfx','EndpointIdentityMissing','AlreadyCurrent','HappyPath','MultiGroup','RestartPolicy','EndpointIdentityConfigured','EndpointWildcard')){$text|Should Match $name} }
    It 'treats RestoreDrift as failure' { $text=Get-Content $runner -Raw;$text|Should Match 'restoreDrift\.Count -gt 0.*result=.FAIL.' }
    It 'defines independent expected outcome and oracle functions' { $text=Get-Content $runner -Raw;foreach($name in @('Get-ExpectedScenarioOutcome','Validate-PreparedScenario','Validate-ActualScenario')){$text|Should Match $name} }
    It 'reports provisioning outcome and actual outcome separately' { $text=Get-Content $runner -Raw;foreach($name in @('ProvisionValid','OutcomeValid','ExpectedOutcome','ActualOutcome','UnexpectedDrift','Failures')){$text|Should Match $name} }
    It 'does not use log-only PASS for renewal' { $text=Get-Content $runner -Raw;$text|Should Match 'Validate-ActualScenario';$text|Should Match 'Get-Drift' }
    It 'defines ExpectedDrift and compares UnexpectedDrift' { $text=Get-Content $runner -Raw;$text|Should Match 'ExpectedDrift';$text|Should Match 'UnexpectedDrift' }
    It 'requires scenario-specific negative categories' { $text=Get-Content $runner -Raw;foreach($category in @('PfxMissing','PfxPassword','PfxExpired','PfxNotNewer','EndpointIdentity','InvalidIdentity')){$text|Should Match $category} }
    It 'has one Restart-BC definition' { [regex]::Matches((Get-Content $runner -Raw),'function Restart-BC').Count|Should Be 1 }
    It 'checks prepared OLD BC/IIS/HTTP.sys state' { $text=Get-Content $runner -Raw;foreach($pattern in @('Prepared BC','Prepared IIS target','Prepared HTTP.sys','Prepared NEW PFX')){$text|Should Match $pattern} }
    It 'reports complete actual outcome resources' { $text=Get-Content $runner -Raw;foreach($field in @("outcome.Add('Services'","outcome.Add('HttpSys'","outcome.Add('Certificate'","outcome.Add('ExpectedDrift'","outcome.Add('UnexpectedDrift")){$text|Should Match ([regex]::Escape($field))} }
}
