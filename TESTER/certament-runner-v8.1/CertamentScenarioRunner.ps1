[CmdletBinding()]
param(
    [ValidateSet('Doctor','Preflight','SelfTest','FastTest','List','Baseline','Provision','Recover','Run','RunSuite')]
    [string]$Action = 'List',
    [string]$Scenario,
    [string]$RunPath,
    [string]$TargetInstance = 'MicrosoftDynamicsNavServer$PROD_NUP2',
    [string]$TargetBinding = '*:443:',
    [string]$IISSiteName,
    [ValidateSet('Core','Renewal','All')]
    [string]$Suite = 'Core',
    [int]$TimeoutSeconds = 900,
    [ValidateRange(0,1)]
    [double]$SleepScale = 1.0,
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CertamentRoot = 'C:\CERTAMENT'
$ConfigPath    = Join-Path $CertamentRoot 'config.json'
$StateRoot     = 'C:\ProgramData\EOS\Certament\ScenarioRunnerV8'
$RunRoot       = Join-Path $StateRoot 'runs'
$script:BCReady = $false
$script:NavTool = $null

$ScenarioCatalog = [ordered]@{
    NoOp               = 'Esegue CERTAMENT nello stato reale; atteso: nessuna modifica.'
    PfxMissing         = 'Certificato BC in scadenza, PFX assente; atteso: nessuna modifica.'
    WrongPassword      = 'PFX valido ma password errata; atteso: nessuna modifica.'
    PfxExpired         = 'PFX contiene certificato gia scaduto; atteso: nessuna modifica.'
    PfxNotNewer        = 'PFX contiene certificato non piu nuovo del certificato corrente; atteso: nessuna modifica.'
    WrongSan           = 'PFX valido ma SAN non pertinente; GAP atteso sulla release corrente se viene accettato.'
    MultipleCandidates = 'Due PFX pertinenti: uno migliore ma meno recente come file; testa la selezione del candidato.'
    UnrelatedPfx       = 'PFX piu recente ma SAN non pertinente; GAP atteso sulla release corrente se viene accettato.'
    AlreadyCurrent     = 'BC e IIS gia sul certificato LAB nuovo; atteso: no-op.'
    HappyPath          = 'Rinnovo coerente di PROD_NUP2: BC, IIS e HTTP.sys puntano al vecchio LAB prima del run.'
    MultiGroup         = 'Un solo certificato vecchio LAB condiviso da PROD_NUP + PROD_NUP2; atteso: entrambi aggiornati.'
    RestartPolicy      = 'HappyPath con IIS.RestartAfterUpdate=false; atteso: aggiornamento senza iisreset.'
}
$SuiteCatalog = @{
    Core    = @('NoOp','PfxMissing','WrongPassword','PfxExpired','PfxNotNewer','WrongSan','MultipleCandidates','UnrelatedPfx','AlreadyCurrent')
    Renewal = @('HappyPath','MultiGroup','RestartPolicy')
    All     = @('NoOp','PfxMissing','WrongPassword','PfxExpired','PfxNotNewer','WrongSan','MultipleCandidates','UnrelatedPfx','AlreadyCurrent','HappyPath','MultiGroup','RestartPolicy')
}

function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail([string]$m){ Write-Host "[FAIL] $m" -ForegroundColor Red }
function Require-Admin {
    $id=[Security.Principal.WindowsIdentity]::GetCurrent()
    $p=New-Object Security.Principal.WindowsPrincipal($id)
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){ throw 'Eseguire Windows PowerShell 5.1 come amministratore.' }
}
function Require-PS51 {
    if($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){ throw "Richiesto Windows PowerShell 5.1. Trovato $($PSVersionTable.PSVersion)." }
}
function Ensure-Dirs {
    foreach($d in @($StateRoot,$RunRoot)){
        if(-not(Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}
function Save-Json($obj,[string]$path){ $obj | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $path -Encoding UTF8 }
function Load-Json([string]$path){ Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
function Hash-File([string]$path){ (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Normalize-Thumb([object]$value){
    if($null -eq $value){return ''}
    if($value -is [byte[]]){return (([BitConverter]::ToString([byte[]]$value)) -replace '-','').ToUpperInvariant()}
    return (([string]$value) -replace '\s','').Trim().ToUpperInvariant()
}
function Canonical($obj){ $obj | ConvertTo-Json -Compress -Depth 80 }
function Assert-True([bool]$condition,[string]$message){ if(-not $condition){throw $message} }

function Initialize-Platform {
    Require-PS51
    Require-Admin
    Assert-True (Test-Path -LiteralPath $CertamentRoot) "CERTAMENT non trovato: $CertamentRoot"
    Assert-True (Test-Path -LiteralPath $ConfigPath) "config.json non trovato: $ConfigPath"
    if(-not (Get-Command Get-NAVServerInstance -ErrorAction SilentlyContinue)){
        $candidates=@(Get-ChildItem -Path 'C:\Program Files\Microsoft Dynamics 365 Business Central\*\Service\NavAdminTool.ps1' -File -ErrorAction SilentlyContinue)
        Assert-True ($candidates.Count -gt 0) 'NavAdminTool.ps1 non trovato.'
        $script:NavTool=$candidates | Sort-Object FullName -Descending | Select-Object -First 1
        Import-Module $script:NavTool.FullName -Force -ErrorAction Stop | Out-Null
    }
    $script:BCReady=$true
    Import-Module WebAdministration -ErrorAction Stop | Out-Null
}
function Get-ConfigObject { Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
function Set-ConfigObject($cfg){ $cfg | ConvertTo-Json -Depth 80 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }
function Get-ConfiguredIISSite {
    if(-not [string]::IsNullOrWhiteSpace($IISSiteName)){return $IISSiteName}
    $cfg=Get-ConfigObject
    if($cfg.IIS -and -not [string]::IsNullOrWhiteSpace([string]$cfg.IIS.SiteName)){return [string]$cfg.IIS.SiteName}
    return 'Microsoft Dynamics 365 Business Central Web Client'
}
function Set-PfxPath([string]$path){$cfg=Get-ConfigObject;$cfg.Pfx.Path=$path;Set-ConfigObject $cfg}
function Set-TestRenewalSettings([int]$notifyDays,[bool]$restartAfterUpdate){
    $cfg=Get-ConfigObject
    if($null -eq $cfg.Notifications){$cfg | Add-Member NoteProperty Notifications ([pscustomobject]@{}) -Force}
    if($null -eq $cfg.Notifications.CertificateExpiry){$cfg.Notifications | Add-Member NoteProperty CertificateExpiry ([pscustomobject]@{}) -Force}
    $cfg.Notifications.CertificateExpiry.NotifyBeforeDays=$notifyDays
    if($null -eq $cfg.IIS){$cfg | Add-Member NoteProperty IIS ([pscustomobject]@{}) -Force}
    $cfg.IIS.RestartAfterUpdate=$restartAfterUpdate
    Set-ConfigObject $cfg
}

function Get-BCThumbprintValue([string]$instance){
    $thumb=''
    try{
        $raw=@(Get-NAVServerConfiguration -ServerInstance $instance -KeyName 'ServicesCertificateThumbprint' -ErrorAction Stop)
        if($raw.Count -gt 0){
            $first=$raw | Select-Object -First 1
            if($first.PSObject.Properties.Name -contains 'Value'){$thumb=[string]$first.Value}else{$thumb=[string]$first}
        }
    }catch{}
    return (Normalize-Thumb $thumb)
}
function Get-BCState {
    if(-not $script:BCReady){Initialize-Platform}
    $rows=@()
    foreach($inst in @(Get-NAVServerInstance)){
        $name=[string]$inst.ServerInstance
        $svc=Get-Service -Name $name -ErrorAction SilentlyContinue
        $serviceStatus='';$startType=''
        if($null -ne $svc){$serviceStatus=[string]$svc.Status;$startType=[string]$svc.StartType}
        $rows += [pscustomobject]@{
            Instance=$name;State=[string]$inst.State;Version=[string]$inst.Version
            ServiceStatus=$serviceStatus;StartType=$startType;Thumbprint=(Get-BCThumbprintValue $name)
        }
    }
    return @($rows)
}
function Find-BCRow($snap,[string]$instance){@($snap.BC)|Where-Object Instance -eq $instance|Select-Object -First 1}
function Set-BCThumbprint([string]$instance,[string]$thumbprint){Set-NAVServerConfiguration -ServerInstance $instance -KeyName 'ServicesCertificateThumbprint' -KeyValue $thumbprint -ErrorAction Stop|Out-Null}
function Wait-ServiceState([string]$name,[string]$desired,[int]$timeout=120){
    $deadline=(Get-Date).AddSeconds($timeout)
    do{$s=Get-Service -Name $name -ErrorAction Stop;if([string]$s.Status -eq $desired){return $true};Start-Sleep -Seconds 2}while((Get-Date)-lt $deadline)
    throw "Servizio $name non ha raggiunto lo stato $desired entro ${timeout}s. Stato attuale: $($s.Status)"
}
function Restart-BC([string]$instance){Restart-NAVServerInstance -ServerInstance $instance -ErrorAction Stop|Out-Null;Wait-ServiceState $instance 'Running' 120}
function Set-BCServiceBaseline($row){
    $svc=Get-Service -Name $row.Instance -ErrorAction Stop
    $currentThumb=Get-BCThumbprintValue $row.Instance
    $baselineThumb=[string]$row.Thumbprint
    if([string]$row.ServiceStatus -eq 'Running'){
        if($currentThumb -ne $baselineThumb){Set-BCThumbprint $row.Instance $baselineThumb;Restart-BC $row.Instance}
        elseif([string]$svc.Status -ne 'Running'){Start-Service $row.Instance;Wait-ServiceState $row.Instance 'Running' 120}
    }elseif([string]$row.ServiceStatus -eq 'Stopped'){
        if([string]$svc.Status -ne 'Stopped'){Stop-Service $row.Instance -Force -ErrorAction Stop;Wait-ServiceState $row.Instance 'Stopped' 120}
        if($currentThumb -ne $baselineThumb){Set-BCThumbprint $row.Instance $baselineThumb}
    }else{
        throw "Stato servizio baseline non supportato per $($row.Instance): $($row.ServiceStatus)"
    }
}

function Get-IISState {
    $sites=@()
    foreach($site in @(Get-Website)){
        $bindings=@()
        foreach($b in @(Get-WebBinding -Name ([string]$site.Name) -ErrorAction Stop)){
            $storeName='';$sslFlags=0
            if($b.PSObject.Properties.Name -contains 'CertificateStoreName'){$storeName=[string]$b.CertificateStoreName}
            if($b.PSObject.Properties.Name -contains 'SslFlags'){$sslFlags=[int]$b.SslFlags}
            $bindings += [pscustomobject]@{
                Protocol=[string]$b.Protocol;BindingInformation=[string]$b.BindingInformation
                CertificateHash=(Normalize-Thumb $b.CertificateHash)
                CertificateStoreName=$storeName;SslFlags=$sslFlags
            }
        }
        $sites += [pscustomobject]@{Name=[string]$site.Name;State=[string]$site.State;Bindings=@($bindings)}
    }
    return @($sites)
}
function Find-IISBinding($snap,[string]$site,[string]$binding){foreach($s in @($snap.IIS)){if([string]$s.Name -eq $site){foreach($b in @($s.Bindings)){if([string]$b.Protocol -eq 'https' -and [string]$b.BindingInformation -eq $binding){return $b}}}}return $null}
function Ensure-IISBinding([string]$site,[string]$bindingInformation,[string]$thumbprint,[string]$store='My'){
    $b=Get-WebBinding -Name $site -Protocol 'https' -ErrorAction SilentlyContinue|Where-Object{[string]$_.BindingInformation -eq $bindingInformation}|Select-Object -First 1
    Assert-True ($null -ne $b) "Binding HTTPS non trovato: $site / $bindingInformation"
        $b.AddSslCertificate((Normalize-Thumb $thumbprint),$store)|Out-Null
}
function Restart-BC([string]$instance){Restart-NAVServerInstance -ServerInstance $instance -ErrorAction Stop|Out-Null;Wait-ServiceState $instance 'Running' 120|Out-Null}

function Get-HttpSslState {
    $raw=(& netsh http show sslcert 2>&1|Out-String);$rows=@();$cur=$null
    foreach($line in ($raw -split "`r?`n")){
        if($line -match '^\s*(IP:port|Hostname:port)\s*:\s*(.+?)\s*$'){
            if($null -ne $cur){$rows += [pscustomobject]$cur}
            $cur=@{Kind=$Matches[1];Endpoint=$Matches[2].Trim();CertHash='';AppId='';StoreName=''};continue
        }
        if($null -eq $cur){continue}
        if($line -match '^\s*Certificate Hash\s*:\s*(.+?)\s*$'){$cur.CertHash=Normalize-Thumb $Matches[1];continue}
        if($line -match '^\s*Application ID\s*:\s*(\{[^}]+\})\s*$'){$cur.AppId=$Matches[1].Trim();continue}
        if($line -match '^\s*Certificate Store Name\s*:\s*(.+?)\s*$'){$cur.StoreName=$Matches[1].Trim();continue}
    }
    if($null -ne $cur){$rows += [pscustomobject]$cur}
    return @($rows)
}
function Find-HttpSsl($snap,[string]$kind,[string]$endpoint){@($snap.HttpSSL)|Where-Object{[string]$_.Kind -eq $kind -and [string]$_.Endpoint -eq $endpoint}|Select-Object -First 1}
function Invoke-NetshHttp([string[]]$netshArgs,[string]$logPath){
    Assert-True ($null -ne $netshArgs -and $netshArgs.Count -gt 0) 'netsh richiamato senza argomenti.'
    $argumentLine=($netshArgs -join ' ');$out=(& netsh @netshArgs 2>&1|Out-String).Trim()
    if($logPath){Add-Content -LiteralPath $logPath -Value ($argumentLine + "`r`n" + $out)}
    if($LASTEXITCODE -ne 0 -and $out -notmatch 'successfully (added|updated|deleted)') {throw "netsh fallito: $argumentLine`n$out"}
    return $out
}
function Set-HttpSslThumb($row,[string]$thumbprint,[string]$logPath){
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$row.AppId)) "HTTP.sys binding senza AppId: $($row.Endpoint)"
    $args=@('http','update','sslcert');if([string]$row.Kind -eq 'IP:port'){$args+=('ipport='+$row.Endpoint)}else{$args+=('hostnameport='+$row.Endpoint)};$args+=('certhash='+$(Normalize-Thumb $thumbprint));$args+=('appid='+$row.AppId)
    $httpStore='MY';if(-not [string]::IsNullOrWhiteSpace([string]$row.StoreName) -and $row.StoreName -ne '(null)'){$httpStore=[string]$row.StoreName};$args+=('certstorename='+$httpStore)
    try{Invoke-NetshHttp $args $logPath|Out-Null}catch{
        $current=@(Get-HttpSslState|Where-Object{[string]$_.Kind -eq [string]$row.Kind -and [string]$_.Endpoint -eq [string]$row.Endpoint})
        if($current.Count -eq 0){if($logPath){Add-Content -LiteralPath $logPath -Value ("skip absent endpoint " + [string]$row.Endpoint)};return}
        $delete=@('http','delete','sslcert');if([string]$row.Kind -eq 'IP:port'){$delete+=('ipport='+$row.Endpoint)}else{$delete+=('hostnameport='+$row.Endpoint)};Invoke-NetshHttp $delete $logPath|Out-Null
        $add=@('http','add','sslcert');if([string]$row.Kind -eq 'IP:port'){$add+=('ipport='+$row.Endpoint)}else{$add+=('hostnameport='+$row.Endpoint)};$add+=('certhash='+$(Normalize-Thumb $thumbprint));$add+=('appid='+$row.AppId);if(-not [string]::IsNullOrWhiteSpace([string]$row.StoreName) -and $row.StoreName -ne '(null)'){$add+=('certstorename='+$row.StoreName)};Invoke-NetshHttp $add $logPath|Out-Null
    }
}

function Get-UrlAclRaw {(& netsh http show urlacl 2>&1|Out-String).Trim()}
function Get-UrlAclState {
    $raw=Get-UrlAclRaw;$rows=@();$curUrl=$null;$curSddl=''
    foreach($line in ($raw -split "`r?`n")){
        if($line -match '^\s*Reserved URL\s*:\s*(.+?)\s*$'){
            if($null -ne $curUrl){$rows += [pscustomobject]@{Url=$curUrl;SDDL=$curSddl}}
            $curUrl=$Matches[1].Trim();$curSddl='';continue
        }
        if($null -ne $curUrl -and $line -match '^\s*SDDL\s*:\s*(.+?)\s*$'){$curSddl=$Matches[1].Trim()}
    }
    if($null -ne $curUrl){$rows += [pscustomobject]@{Url=$curUrl;SDDL=$curSddl}}
    $ded=@{};foreach($r in $rows){$ded[$r.Url]=$r};return @($ded.Values|Sort-Object Url)
}
function Reconcile-UrlAcl($before,[string]$logPath){
    $cur=@(Get-UrlAclState);$old=@($before.UrlAcl);$oldMap=@{};foreach($r in $old){$oldMap[$r.Url]=$r};$curMap=@{};foreach($r in $cur){$curMap[$r.Url]=$r}
    foreach($r in $cur){if(-not $oldMap.ContainsKey($r.Url)){Invoke-NetshHttp @('http','delete','urlacl',('url='+$r.Url)) $logPath|Out-Null}}
    foreach($r in $old){
        if($curMap.ContainsKey($r.Url) -and [string]$curMap[$r.Url].SDDL -eq [string]$r.SDDL){continue}
        if($curMap.ContainsKey($r.Url)){Invoke-NetshHttp @('http','delete','urlacl',('url='+$r.Url)) $logPath|Out-Null}
        if(-not [string]::IsNullOrWhiteSpace([string]$r.SDDL)){Invoke-NetshHttp @('http','add','urlacl',('url='+$r.Url),('sddl='+$r.SDDL)) $logPath|Out-Null}
    }
}

function Get-CertState {return @(Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction Stop|ForEach-Object{[pscustomobject]@{Thumbprint=Normalize-Thumb $_.Thumbprint;Subject=[string]$_.Subject;FriendlyName=[string]$_.FriendlyName;HasPrivateKey=[bool]$_.HasPrivateKey;NotAfter=$_.NotAfter.ToString('o')}})}
function Get-PfxState([string]$path=$null){if([string]::IsNullOrWhiteSpace($path)){$cfg=Get-ConfigObject;$path=[string]$cfg.Pfx.Path};if(-not(Test-Path -LiteralPath $path -PathType Container)){return @()};return @(Get-ChildItem -LiteralPath $path -Filter '*.pfx' -File -ErrorAction SilentlyContinue|ForEach-Object{[pscustomobject]@{Name=$_.Name;Length=[int64]$_.Length;SHA256=(Hash-File $_.FullName);LastWriteTime=$_.LastWriteTime.ToString('o')}})}
function Get-TaskState {$t=Get-ScheduledTask -TaskName 'CERTAMENT' -ErrorAction SilentlyContinue;if($null -eq $t){return $null};return [pscustomobject]@{Name=[string]$t.TaskName;State=[string]$t.State;Enabled=[bool]$t.Settings.Enabled}}
function Get-IISProcessEvidence {$rows=@();foreach($p in @(Get-Process w3wp -ErrorAction SilentlyContinue)){$st=$null;try{$st=$p.StartTime.ToString('o')}catch{};$rows+=[pscustomobject]@{Id=[int]$p.Id;StartTime=$st}};return @($rows|Sort-Object Id)}
function New-Snapshot {$obj=[pscustomobject]@{CapturedAt=(Get-Date).ToUniversalTime().ToString('o');ConfigHash=(Hash-File $ConfigPath);BC=@(Get-BCState);IIS=@(Get-IISState);HttpSSL=@(Get-HttpSslState);UrlAcl=@(Get-UrlAclState);Certificates=@(Get-CertState);Pfx=@(Get-PfxState);Task=Get-TaskState;IISProcesses=@(Get-IISProcessEvidence)};return $obj}
function Get-Drift($a,$b){$d=@();if($a.ConfigHash -ne $b.ConfigHash){$d+='Config'};if((Canonical $a.BC) -ne (Canonical $b.BC)){$d+='BC'};if((Canonical $a.IIS) -ne (Canonical $b.IIS)){$d+='IIS'};if((Canonical $a.HttpSSL) -ne (Canonical $b.HttpSSL)){$d+='HTTP.sys'};if((Canonical $a.UrlAcl) -ne (Canonical $b.UrlAcl)){$d+='URLACL'};if((Canonical $a.Pfx) -ne (Canonical $b.Pfx)){$d+='PFX'};if((Canonical $a.Certificates) -ne (Canonical $b.Certificates)){$d+='Certificates'};if((Canonical $a.Task) -ne (Canonical $b.Task)){$d+='ScheduledTask'};return @($d)}
function Protect-FileBytes([string]$sourcePath,[string]$backupPath){
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $bytes=[IO.File]::ReadAllBytes($sourcePath)
    $protected=[System.Security.Cryptography.ProtectedData]::Protect($bytes,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Convert]::ToBase64String($protected)|Set-Content -LiteralPath $backupPath -Encoding ASCII
}
function Restore-FileBytes([string]$backupPath,[string]$destinationPath){
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $protected=[Convert]::FromBase64String((Get-Content -LiteralPath $backupPath -Raw))
    $bytes=[System.Security.Cryptography.ProtectedData]::Unprotect($protected,$null,[System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($destinationPath,$bytes)
}
function Save-SnapshotArtifacts($snap,[string]$runDir,[string]$label,[bool]$protectConfig=$false){Save-Json $snap (Join-Path $runDir ($label+'.json'));if($protectConfig){Protect-FileBytes $ConfigPath (Join-Path $runDir 'config.backup.dpapi')}}

function New-LabPassword(){return 'CERTAMENT-LAB-5A!2026#Pfx'}
function Write-LabPassword([string]$dir,[string]$password){Set-Content -LiteralPath (Join-Path $dir 'password.txt') -Value $password -Encoding UTF8}
function New-LabCert([string]$name,[string[]]$dns,[double]$validDays,[securestring]$password,[string]$pfxDir){
    $now=Get-Date
    if($validDays -lt 0){$notBefore=$now.AddDays(-2);$notAfter=$now.AddDays(-1)}else{$notBefore=$now.AddMinutes(-10);$notAfter=$now.AddDays($validDays)}
    $cert=New-SelfSignedCertificate -Type SSLServerAuthentication -Subject ('CN='+$dns[0]) -DnsName $dns -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName $name -NotBefore $notBefore -NotAfter $notAfter -KeyExportPolicy Exportable -ErrorAction Stop
    $pfx=Join-Path $pfxDir ($name+'.pfx');Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $password -Force -ErrorAction Stop|Out-Null
    return [pscustomobject]@{Thumbprint=(Normalize-Thumb $cert.Thumbprint);PfxPath=$pfx;FriendlyName=$name;NotBefore=$cert.NotBefore;NotAfter=$cert.NotAfter;Subject=$cert.Subject;DnsNames=@($dns)}
}
function Remove-LabCerts {
    $labs=@(Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction Stop|Where-Object{([string]$_.FriendlyName)-like 'CERTAMENT-LAB-*'})
    foreach($cert in $labs){Remove-Item ('Cert:\LocalMachine\My\'+$cert.Thumbprint) -Force -ErrorAction Stop}
    $remaining=@(Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction Stop|Where-Object{([string]$_.FriendlyName)-like 'CERTAMENT-LAB-*'})
    Assert-True ($remaining.Count -eq 0) 'Certificati CERTAMENT-LAB-* residui dopo cleanup.'
}
function Set-FileAge([string]$path,[datetime]$when){(Get-Item -LiteralPath $path).LastWriteTime=$when}
function Prepare-Common([string]$runDir,$before,[bool]$restartAfterUpdate=$true){
    $site=Get-ConfiguredIISSite;$b=Find-IISBinding $before $site $TargetBinding;Assert-True ($null -ne $b) "Binding HTTPS non trovato: $site / $TargetBinding"
    $oldIisThumb=Normalize-Thumb $b.CertificateHash;$oldTarget=Find-BCRow $before $TargetInstance;Assert-True ($null -ne $oldTarget) "Istanza BC non trovata: $TargetInstance";Assert-True (-not [string]::IsNullOrWhiteSpace([string]$oldTarget.Thumbprint)) "Target BC senza ServicesCertificateThumbprint: $TargetInstance";Assert-True ($oldIisThumb -eq (Normalize-Thumb $oldTarget.Thumbprint)) "Stato sandbox incoerente: IIS 443 e BC target non usano lo stesso certificato."
    $labDir=Join-Path $runDir 'pfx';New-Item -ItemType Directory -Path $labDir -Force|Out-Null;$pw=New-LabPassword;$sec=ConvertTo-SecureString $pw -AsPlainText -Force;Write-LabPassword $labDir $pw
    Set-TestRenewalSettings 400 $restartAfterUpdate;Set-PfxPath $labDir
    return [pscustomobject]@{Site=$site;OldIisThumb=$oldIisThumb;OldTargetThumb=(Normalize-Thumb $oldTarget.Thumbprint);LabPfxDir=$labDir;LabPassword=$pw;SecurePassword=$sec;ModifiedHttp=@()}
}
function Prepare-Scenario([string]$name,[string]$runDir,$before){
    Remove-LabCerts
    $prep=Prepare-Common $runDir $before $true
    $target=$TargetInstance
    $oldRef=$null;$newRef=$null;$badRef=$null
    switch($name){
        'PfxMissing' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            Remove-Item -LiteralPath $oldRef.PfxPath -Force
        }
        'WrongPassword' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $newRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-NEW" @('bc.cert.pitto',$env:COMPUTERNAME) 3650 $prep.SecurePassword $prep.LabPfxDir
            Write-LabPassword $prep.LabPfxDir 'CERTAMENT-LAB-WRONG-PASSWORD'
            Set-FileAge $newRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        'PfxExpired' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $badRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-EXPIRED" @('bc.cert.pitto',$env:COMPUTERNAME) -0.1 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $badRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        'PfxNotNewer' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $badRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLDER" @('bc.cert.pitto',$env:COMPUTERNAME) 10 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $badRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        'WrongSan' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $badRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-BADSAN" @('not-the-target.invalid') 3650 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $badRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        'MultipleCandidates' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $newRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-GOOD" @('bc.cert.pitto',$env:COMPUTERNAME) 3650 $prep.SecurePassword $prep.LabPfxDir
            $badRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-SHORT" @('bc.cert.pitto',$env:COMPUTERNAME) 100 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $badRef.PfxPath (Get-Date);Set-FileAge $newRef.PfxPath (Get-Date).AddMinutes(-2);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-4)
        }
        'UnrelatedPfx' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $badRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-UNRELATED" @('not-the-target.invalid') 3650 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $badRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        'NoOp' {
            $newRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-CURRENT" @('bc.cert.pitto',$env:COMPUTERNAME) 3650 $prep.SecurePassword $prep.LabPfxDir
        }
        'AlreadyCurrent' {
            $newRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-CURRENT" @('bc.cert.pitto',$env:COMPUTERNAME) 3650 $prep.SecurePassword $prep.LabPfxDir
        }
        'HappyPath' {
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-OLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $newRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-NEW" @('bc.cert.pitto',$env:COMPUTERNAME) 3650 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $newRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        'MultiGroup' {
            Set-TestRenewalSettings 400 $true
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-MGOLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $newRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-MGNEW" @('bc.cert.pitto',$env:COMPUTERNAME) 3650 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $newRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        'RestartPolicy' {
            $prep=Prepare-Common $runDir $before $false
            $oldRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-RPOOLD" @('bc.cert.pitto',$env:COMPUTERNAME) 20 $prep.SecurePassword $prep.LabPfxDir
            $newRef=New-LabCert "CERTAMENT-LAB-$((Split-Path $runDir -Leaf))-RPNEW" @('bc.cert.pitto',$env:COMPUTERNAME) 3650 $prep.SecurePassword $prep.LabPfxDir
            Set-FileAge $newRef.PfxPath (Get-Date);Set-FileAge $oldRef.PfxPath (Get-Date).AddMinutes(-2)
        }
        default { throw "Scenario non supportato: $name" }
    }
    if($name -in @('NoOp','AlreadyCurrent')){
        Set-BCThumbprint $target $newRef.Thumbprint;Restart-BC $target;Ensure-IISBinding $prep.Site $TargetBinding $newRef.Thumbprint 'My'
        foreach($h in @($before.HttpSSL|Where-Object{(Normalize-Thumb $_.CertHash) -eq $prep.OldIisThumb})){
            Set-HttpSslThumb $h $newRef.Thumbprint (Join-Path $runDir 'http-prepare.log')
        }
        return [pscustomobject]@{Site=$prep.Site;Target=$target;Old=$null;New=$newRef;Bad=$null;ModifiedHttp=@();LabPfxDir=$prep.LabPfxDir;OldIisThumb=$prep.OldIisThumb;OldTargetThumb=$prep.OldTargetThumb}
    }
    if($null -eq $oldRef){throw "Scenario $name non ha generato un certificato OLD."}
    $oldThumbs=@($prep.OldTargetThumb)
    if($name -eq 'MultiGroup'){
        $mg=Find-BCRow $before 'MicrosoftDynamicsNavServer$PROD_NUP';Assert-True ($null -ne $mg) 'PROD_NUP non trovato per MultiGroup';$oldThumbs+=Normalize-Thumb $mg.Thumbprint
        Set-BCThumbprint 'MicrosoftDynamicsNavServer$PROD_NUP' $oldRef.Thumbprint
        Restart-BC 'MicrosoftDynamicsNavServer$PROD_NUP'
    }
    Set-BCThumbprint $target $oldRef.Thumbprint;Restart-BC $target;Ensure-IISBinding $prep.Site $TargetBinding $oldRef.Thumbprint 'My'
    $httpChanged=@()
    foreach($h in @($before.HttpSSL|Where-Object{$oldThumbs -contains (Normalize-Thumb $_.CertHash)})){
        Set-HttpSslThumb $h $oldRef.Thumbprint (Join-Path $runDir 'http-prepare.log');$httpChanged += [string]$h.Endpoint
    }
    return [pscustomobject]@{Site=$prep.Site;Target=$target;Old=$oldRef;New=$newRef;Bad=$badRef;ModifiedHttp=@($httpChanged);LabPfxDir=$prep.LabPfxDir;OldIisThumb=$prep.OldIisThumb;OldTargetThumb=$prep.OldTargetThumb}
}

function Get-PublicPreparation($prep,[string]$runDir){
    $oldThumb='';$newThumb='';$badThumb=''
    if($null -ne $prep.Old){$oldThumb=Normalize-Thumb $prep.Old.Thumbprint}
    if($null -ne $prep.New){$newThumb=Normalize-Thumb $prep.New.Thumbprint}
    if($null -ne $prep.Bad){$badThumb=Normalize-Thumb $prep.Bad.Thumbprint}
    return [pscustomobject]@{
        RunDir=$runDir;Site=[string]$prep.Site;Target=[string]$prep.Target;LabPfxDir=[string]$prep.LabPfxDir
        OldIisThumb=(Normalize-Thumb $prep.OldIisThumb);OldTargetThumb=(Normalize-Thumb $prep.OldTargetThumb)
        OldThumbprint=$oldThumb;NewThumbprint=$newThumb;BadThumbprint=$badThumb;ModifiedHttp=@($prep.ModifiedHttp)
    }
}
function Invoke-Certament([string]$runDir){
    $script=Join-Path $CertamentRoot '_MAINCertManager.ps1';Assert-True (Test-Path -LiteralPath $script) "CERTAMENT non trovato: $script"
    $out=Join-Path $runDir 'certament.stdout.log';$err=Join-Path $runDir 'certament.stderr.log';$sw=[Diagnostics.Stopwatch]::StartNew()
    $previousScale=$env:CERTAMENT_TEST_SLEEP_SCALE;$env:CERTAMENT_TEST_SLEEP_SCALE=$SleepScale.ToString([Globalization.CultureInfo]::InvariantCulture)
    try{
        $p=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script) -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden
        $finished=$p.WaitForExit($TimeoutSeconds*1000)
        if(-not $finished){try{$p.Kill()}catch{};$sw.Stop();return [pscustomobject]@{ExitCode=-9;TimedOut=$true;Duration=[math]::Round($sw.Elapsed.TotalSeconds,1);Stdout=$out;Stderr=$err}}
        $p.Refresh();$exitCode=[int]$p.ExitCode;$sw.Stop();return [pscustomobject]@{ExitCode=$exitCode;TimedOut=$false;Duration=[math]::Round($sw.Elapsed.TotalSeconds,1);Stdout=$out;Stderr=$err}
    }finally{
        if($null -eq $previousScale){Remove-Item Env:CERTAMENT_TEST_SLEEP_SCALE -ErrorAction SilentlyContinue}else{$env:CERTAMENT_TEST_SLEEP_SCALE=$previousScale}
    }
}
function Restore-HttpSsl($before,[string]$runDir){
    $log=Join-Path $runDir 'http-restore.log';$current=@(Get-HttpSslState);$cur=@{};foreach($r in $current){$cur[([string]$r.Kind)+'|'+([string]$r.Endpoint)]=$r};$old=@{};foreach($r in @($before.HttpSSL)){$old[([string]$r.Kind)+'|'+([string]$r.Endpoint)]=$r}
    foreach($r in $current){$k=([string]$r.Kind)+'|'+([string]$r.Endpoint);if(-not $old.ContainsKey($k)){$a=@('http','delete','sslcert');if($r.Kind -eq 'IP:port'){$a+=('ipport='+$r.Endpoint)}else{$a+=('hostnameport='+$r.Endpoint)};Invoke-NetshHttp $a $log|Out-Null}}
    foreach($r in @($before.HttpSSL)){
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r.AppId)) "HTTP.sys binding senza AppId durante restore: $($r.Endpoint)";$k=([string]$r.Kind)+'|'+([string]$r.Endpoint);$verb='add';if($cur.ContainsKey($k)){$verb='update'};$args=@('http',$verb,'sslcert');if($r.Kind -eq 'IP:port'){$args+=('ipport='+$r.Endpoint)}else{$args+=('hostnameport='+$r.Endpoint)};$args+=('certhash='+$r.CertHash);$args+=('appid='+$r.AppId);if(-not [string]::IsNullOrWhiteSpace([string]$r.StoreName) -and $r.StoreName -ne '(null)'){$args+=('certstorename='+$r.StoreName)};Invoke-NetshHttp $args $log|Out-Null
    }
}
function Restore-IISSiteState($before){
    foreach($site in @($before.IIS)){
        $current=Get-Website -Name ([string]$site.Name) -ErrorAction Stop
        if([string]$site.State -eq 'Started' -and [string]$current.State -ne 'Started'){Start-Website -Name ([string]$site.Name)}
        elseif([string]$site.State -eq 'Stopped' -and [string]$current.State -ne 'Stopped'){Stop-Website -Name ([string]$site.Name)}
    }
}
function Restore-State($before,[string]$runDir){
    $cfgBackup=Join-Path $runDir 'config.backup.dpapi';Assert-True (Test-Path -LiteralPath $cfgBackup) 'Backup config DPAPI non trovato.'
    Info 'Restore: config'
    Restore-FileBytes $cfgBackup $ConfigPath
    Info 'Restore: BC'
    foreach($b in @($before.BC)){
        $svc=Get-Service -Name $b.Instance -ErrorAction SilentlyContinue;Assert-True ($null -ne $svc) "Istanza BC mancante durante restore: $($b.Instance)"
        $curThumb=Get-BCThumbprintValue $b.Instance
        if($curThumb -ne [string]$b.Thumbprint){Set-BCThumbprint $b.Instance $b.Thumbprint}
        Set-BCServiceBaseline $b
    }
    Info 'Restore: HTTP.sys'
    Restore-HttpSsl $before $runDir
    Info 'Restore: IIS'
    foreach($site in @($before.IIS)){
        foreach($b in @($site.Bindings|Where-Object Protocol -eq 'https')){if($b.CertificateHash){$store='My';if(-not [string]::IsNullOrWhiteSpace([string]$b.CertificateStoreName)){$store=[string]$b.CertificateStoreName};Ensure-IISBinding $site.Name $b.BindingInformation $b.CertificateHash $store}}
    }
    Restore-IISSiteState $before
    Info 'Restore: URLACL e certificati LAB'
    Reconcile-UrlAcl $before (Join-Path $runDir 'urlacl-restore.log')
    Remove-LabCerts
}
function Evaluate-Negative($name,$exec,$prepared,$after,$before){
    $runtimeDrift=@(Get-Drift $prepared $after)
    $stdoutText='';$stderrText='';if(Test-Path -LiteralPath ([string]$exec.Stdout)){$stdoutText=Get-Content -LiteralPath ([string]$exec.Stdout) -Raw};if(Test-Path -LiteralPath ([string]$exec.Stderr)){$stderrText=Get-Content -LiteralPath ([string]$exec.Stderr) -Raw};$evidence=($stdoutText+"`n"+$stderrText)
    $handled=($evidence -match 'Nessun file PFX|PFX non leggibile|password PFX|PFX.*scaduto|PFX.*non.*nuovo|non piu recente|non pertinente')
    $safeExit=(($exec.ExitCode -ne 0 -or $handled) -and -not $exec.TimedOut)
    $safeState=@($runtimeDrift|Where-Object{$_ -in @('Config','BC','IIS','HTTP.sys','Certificates','URLACL','ScheduledTask')}).Count -eq 0
    if($name -in @('WrongSan','UnrelatedPfx')){
        if($safeExit -and $safeState){return 'PASS'}
        return 'EXPECTED-GAP'
    }
    if($safeExit -and $safeState){return 'PASS'}
    return 'FAIL'
}
function Evaluate-Scenario($name,$exec,$before,$preparedState,$after,$prep){
    if($name -in @('NoOp','AlreadyCurrent')){
        if($exec.ExitCode -eq 0 -and @(Get-Drift $preparedState $after).Count -eq 0){return 'PASS'};return 'FAIL'
    }
    if($name -in @('PfxMissing','WrongPassword','PfxExpired','PfxNotNewer','WrongSan','UnrelatedPfx','MultipleCandidates')){return Evaluate-Negative $name $exec $preparedState $after $before}
    if($name -in @('HappyPath','RestartPolicy','MultiGroup')){
        if($exec.ExitCode -ne 0 -or $exec.TimedOut){return 'FAIL'}
        $target=Find-BCRow $after $TargetInstance;$newThumb=Normalize-Thumb $prep.New.Thumbprint;$site=$prep.Site;$iis=Find-IISBinding $after $site $TargetBinding
        Assert-True ($null -ne $target) "Target BC assente dopo $name";Assert-True ($target.Thumbprint -eq $newThumb) "BC target non aggiornato: trovato $($target.Thumbprint), atteso $newThumb";Assert-True ($target.ServiceStatus -eq 'Running') "BC target non Running dopo $name";Assert-True ($null -ne $iis -and (Normalize-Thumb $iis.CertificateHash) -eq $newThumb) "IIS 443 non aggiornato a $newThumb"
        if($name -eq 'MultiGroup'){
            $mgAfter=Find-BCRow $after 'MicrosoftDynamicsNavServer$PROD_NUP';Assert-True ($null -ne $mgAfter) 'PROD_NUP assente dopo MultiGroup';Assert-True ((Normalize-Thumb $mgAfter.Thumbprint) -eq $newThumb) 'PROD_NUP non aggiornato al nuovo certificato';Assert-True ([string]$mgAfter.ServiceStatus -eq 'Running') 'PROD_NUP non Running dopo MultiGroup'
        }
        $required=@()
        if($name -eq 'MultiGroup'){
            $mgBefore=Find-BCRow $before 'MicrosoftDynamicsNavServer$PROD_NUP';Assert-True ($null -ne $mgBefore) 'PROD_NUP non trovato nella baseline.'
            $groupThumbs=@((Normalize-Thumb $prep.Old.Thumbprint),(Normalize-Thumb $mgBefore.Thumbprint))
            $required=@($before.HttpSSL|Where-Object{(Normalize-Thumb $_.CertHash) -in $groupThumbs})
        }else{
            $required=@($before.HttpSSL|Where-Object{(Normalize-Thumb $_.CertHash) -eq (Normalize-Thumb $prep.Old.Thumbprint)})
        }
        foreach($h in $required){$x=Find-HttpSsl $after $h.Kind $h.Endpoint;Assert-True ($null -ne $x -and (Normalize-Thumb $x.CertHash) -eq $newThumb) "HTTP.sys $($h.Endpoint) non aggiornato"}
        $c=@($after.Certificates|Where-Object{(Normalize-Thumb $_.Thumbprint) -eq $newThumb})|Select-Object -First 1;Assert-True ($null -ne $c -and [bool]$c.HasPrivateKey) 'Nuovo certificato non presente con private key'
        if($name -eq 'RestartPolicy'){
            $text='';$outPath=Join-Path $prep.RunDir 'certament.stdout.log';if(Test-Path $outPath){$text=Get-Content $outPath -Raw};Assert-True ($text -notmatch 'Riavvio IIS') 'CERTAMENT ha tentato il riavvio IIS nonostante RestartAfterUpdate=false.'
        }
        return 'PASS'
    }
    return 'FAIL'
}
function Run-One([string]$name){
    Ensure-Dirs;Initialize-Platform;Assert-True ($ScenarioCatalog.Contains($name)) "Scenario non supportato: $name"
    $runDir=Join-Path $RunRoot ((Get-Date -Format 'yyyyMMdd_HHmmssfff')+'_'+$name);New-Item -ItemType Directory -Path $runDir -Force|Out-Null;Info "Scenario $name -> $runDir"
    $before=$null;$prepared=$null;$after=$null;$final=$null;$prepInfo=$null;$exec=[pscustomobject]@{ExitCode=0;TimedOut=$false;Duration=0};$result='FAIL';$err='';$runtimeDrift=@();$restoreDrift=@()
    try{
        Assert-True (@(Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction Stop|Where-Object{([string]$_.FriendlyName)-like 'CERTAMENT-LAB-*'}).Count -eq 0) 'Esistono gia certificati CERTAMENT-LAB-*; eseguire Recover/cleanup prima.'
        $before=New-Snapshot;Save-SnapshotArtifacts $before $runDir 'baseline' $true
        if($name -eq 'NoOp'){
            $prepInfo=[pscustomobject]@{RunDir=$runDir;Site=(Get-ConfiguredIISSite);Target=$TargetInstance;LabPfxDir='';OldIisThumb='';OldTargetThumb='';Old=$null;New=$null;Bad=$null;ModifiedHttp=@()}
            $prepared=$before
            Save-Json (Get-PublicPreparation $prepInfo $runDir) (Join-Path $runDir 'prepared.json')
        }else{
            $prepInfo=Prepare-Scenario $name $runDir $before;$prepared=New-Snapshot;Save-SnapshotArtifacts $prepared $runDir 'prepared'
            Save-Json (Get-PublicPreparation $prepInfo $runDir) (Join-Path $runDir 'prepared.json')
        }
        $exec=Invoke-Certament $runDir
        $after=New-Snapshot;Save-SnapshotArtifacts $after $runDir 'post-run';$runtimeDrift=@(Get-Drift $prepared $after);Save-Json $runtimeDrift (Join-Path $runDir 'runtime-drift.json')
        $result=Evaluate-Scenario $name $exec $before $prepared $after $prepInfo
    }catch{$err=$_.Exception.ToString();Set-Content -LiteralPath (Join-Path $runDir 'runner-error.txt') -Value $err -Encoding UTF8;$result='FAIL'}
    finally{
        if($null -ne $before){
            try{Restore-State $before $runDir}catch{$err += "`nRESTORE: $($_.Exception.ToString())";$restoreDrift=@('RestoreError')}
            try{$final=New-Snapshot;Save-SnapshotArtifacts $final $runDir 'post-restore';$restoreDrift=@(Get-Drift $before $final);Save-Json $restoreDrift (Join-Path $runDir 'restore-drift.json')}catch{$err += "`nPOST-RESTORE: $($_.Exception.ToString())";$restoreDrift=@('VerificationError')}
        }
    }
    if($restoreDrift.Count -gt 0){$result='FAIL'}
    if($err){Set-Content -LiteralPath (Join-Path $runDir 'runner-error.txt') -Value $err -Encoding UTF8}
    $r=[pscustomobject]@{Scenario=$name;Result=$result;ExitCode=$exec.ExitCode;TimedOut=$exec.TimedOut;DurationSeconds=$exec.Duration;RuntimeDrift=@($runtimeDrift);BaselineRestored=($restoreDrift.Count -eq 0);RestoreDrift=@($restoreDrift);RunDirectory=$runDir}
    Save-Json $r (Join-Path $runDir 'result.json');if($result -eq 'PASS'){Ok "$name PASS"}elseif($result -eq 'EXPECTED-GAP'){Warn "$name EXPECTED-GAP"}else{Fail "$name FAIL"};return $r
}
function Provision-One([string]$name){
    Ensure-Dirs;Initialize-Platform;Assert-True ($ScenarioCatalog.Contains($name)) "Scenario non supportato: $name"
    $runDir=Join-Path $RunRoot ((Get-Date -Format 'yyyyMMdd_HHmmssfff')+'_PROVISION_'+$name);New-Item -ItemType Directory -Path $runDir -Force|Out-Null;Info "Provision $name -> $runDir"
    $before=$null;$prepared=$null;$prepInfo=$null;$err='';$restoreDrift=@();$result='FAIL'
    try{
        Assert-True (@(Get-ChildItem 'Cert:\LocalMachine\My' -ErrorAction Stop|Where-Object{([string]$_.FriendlyName)-like 'CERTAMENT-LAB-*'}).Count -eq 0) 'Esistono gia certificati CERTAMENT-LAB-*; eseguire Recover/cleanup prima.'
        $before=New-Snapshot;Save-SnapshotArtifacts $before $runDir 'baseline' $true
        if($name -eq 'NoOp'){$prepInfo=[pscustomobject]@{RunDir=$runDir;Site=(Get-ConfiguredIISSite);Target=$TargetInstance;LabPfxDir='';OldIisThumb='';OldTargetThumb='';Old=$null;New=$null;Bad=$null;ModifiedHttp=@()};$prepared=$before}else{$prepInfo=Prepare-Scenario $name $runDir $before;$prepared=New-Snapshot;Save-SnapshotArtifacts $prepared $runDir 'prepared'}
        Save-Json (Get-PublicPreparation $prepInfo $runDir) (Join-Path $runDir 'prepared.json')
        $result='PASS'
    }catch{$err=$_.Exception.ToString();$result='FAIL'}finally{
        if($null -ne $before){try{Restore-State $before $runDir}catch{$err += "`nRESTORE: $($_.Exception.ToString())";$restoreDrift=@('RestoreError')};try{$final=New-Snapshot;Save-SnapshotArtifacts $final $runDir 'post-restore';$restoreDrift=@(Get-Drift $before $final);Save-Json $restoreDrift (Join-Path $runDir 'restore-drift.json')}catch{$restoreDrift=@('VerificationError')}}
    }
    if($restoreDrift.Count -gt 0){$result='FAIL'};if($err){Set-Content -LiteralPath (Join-Path $runDir 'runner-error.txt') -Value $err -Encoding UTF8}
    $r=[pscustomobject]@{Scenario=$name;Result=$result;Provisioned=($null -ne $prepared);BaselineRestored=($restoreDrift.Count -eq 0);RestoreDrift=@($restoreDrift);RunDirectory=$runDir};Save-Json $r (Join-Path $runDir 'provision-result.json');if($result -eq 'PASS'){Ok "$name PROVISION PASS"}else{Fail "$name PROVISION FAIL"};return $r
}
function Run-Suite([string]$name){
    Ensure-Dirs;Initialize-Platform;$rows=@()
    foreach($s in @($SuiteCatalog[$name])){Write-Host "`n===== $s =====" -ForegroundColor Magenta;$r=Run-One $s;$rows+=$r;if(-not $r.BaselineRestored){Fail 'Baseline non ripristinato: suite interrotta.';break}}
    $suitePath=Join-Path $StateRoot ((Get-Date -Format 'yyyyMMdd_HHmmss')+"_$name.json");Save-Json $rows $suitePath;$rows|Format-Table Scenario,Result,ExitCode,BaselineRestored -AutoSize
    return [pscustomobject]@{Suite=$name;Total=$rows.Count;Pass=@($rows|Where-Object Result -eq 'PASS').Count;ExpectedGap=@($rows|Where-Object Result -eq 'EXPECTED-GAP').Count;Fail=@($rows|Where-Object Result -eq 'FAIL').Count;Report=$suitePath}
}
function Doctor{
    Require-PS51;Require-Admin
    $nav=@(Get-ChildItem -Path 'C:\Program Files\Microsoft Dynamics 365 Business Central\*\Service\NavAdminTool.ps1' -File -ErrorAction SilentlyContinue)
    $w3=Get-Service W3SVC -ErrorAction SilentlyContinue
    $wa=$false;try{Import-Module WebAdministration -ErrorAction Stop;$wa=$true}catch{}
    $iisStatus='';if($null -ne $w3){$iisStatus=[string]$w3.Status}
    $navPath='';if($nav.Count -gt 0){$navPath=[string]$nav[0].FullName}
    return [pscustomobject]@{PowerShell=$PSVersionTable.PSVersion.ToString();Administrator=$true;CertamentRoot=(Test-Path $CertamentRoot);Config=(Test-Path $ConfigPath);NavAdminTool=$navPath;WebAdministration=$wa;IIS=$iisStatus}
}

function Preflight{
    Initialize-Platform;Ensure-Dirs;$snap=New-Snapshot;$site=Get-ConfiguredIISSite;$target=Find-BCRow $snap $TargetInstance;$iis=Find-IISBinding $snap $site $TargetBinding;$issues=@()
    if($null -eq $target){$issues+='Target BC instance missing'}elseif([string]::IsNullOrWhiteSpace($target.Thumbprint)){$issues+='Target BC has no certificate'}
    if($null -eq $iis){$issues+="IIS HTTPS binding missing: $site/$TargetBinding"}
    if($null -ne $target -and $null -ne $iis -and (Normalize-Thumb $target.Thumbprint) -ne (Normalize-Thumb $iis.CertificateHash)){$issues+='Target BC certificate and IIS 443 certificate differ'}
    $targetHttp=@($snap.HttpSSL|Where-Object{(Normalize-Thumb $_.CertHash) -eq (Normalize-Thumb $target.Thumbprint)})
    if($null -ne $target -and $targetHttp.Count -eq 0){$issues+='No HTTP.sys SSL binding uses the target BC certificate'}
    if(@($snap.HttpSSL|Where-Object{[string]::IsNullOrWhiteSpace([string]$_.AppId)}).Count -gt 0){$issues+='HTTP.sys SSL binding without AppId cannot be restored safely'}
    $labs=@(Get-CertState|Where-Object{[string]$_.FriendlyName -like 'CERTAMENT-LAB-*'});if($labs.Count -gt 0){$issues+='CERTAMENT-LAB-* certificates already installed'}
    if(@(Get-PfxState).Count -gt 0){Info "PFX real path: $(@(Get-PfxState).Count) file(s); only PFX are hashed."}
    $rows=@([pscustomobject]@{Check='PS5.1';Passed=($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)},[pscustomobject]@{Check='Admin';Passed=$true},[pscustomobject]@{Check='BC discovered';Passed=(@($snap.BC).Count -gt 0)},[pscustomobject]@{Check='Target';Passed=($null -ne $target)},[pscustomobject]@{Check='IIS target binding';Passed=($null -ne $iis)},[pscustomobject]@{Check='BC/IIS thumb aligned';Passed=($null -ne $target -and $null -ne $iis -and (Normalize-Thumb $target.Thumbprint) -eq (Normalize-Thumb $iis.CertificateHash))},[pscustomobject]@{Check='No stale LAB certs';Passed=($labs.Count -eq 0)},[pscustomobject]@{Check='Scenario catalog';Passed=($ScenarioCatalog.Count -eq 12)})
    $rows|Format-Table -AutoSize;if($issues.Count -gt 0){throw ('PREFLIGHT FAIL: '+($issues -join '; '))};Ok 'Preflight PASS'
}
function SelfTest{Initialize-Platform;Ensure-Dirs;$snap=New-Snapshot;Assert-True ($ScenarioCatalog.Count -eq 12) 'Catalogo scenari incompleto.';Assert-True (@($snap.BC).Count -gt 0) 'BC non rilevato.';Assert-True (@($snap.IIS).Count -gt 0) 'IIS non rilevato.';Assert-True ($null -ne $snap.HttpSSL) 'HTTP.sys probe fallita.';Assert-True ($null -ne $snap.UrlAcl) 'URLACL probe fallita.';Assert-True ($null -ne $snap.Certificates) 'Certificate store probe fallita.';Ok "SelfTest PASS - BC=$(@($snap.BC).Count), IIS=$(@($snap.IIS).Count), SSL bindings=$(@($snap.HttpSSL).Count), URLACL=$(@($snap.UrlAcl).Count)"}
function FastTest {
    $modulePath=Join-Path $PSScriptRoot '..\..\modules\Get-PfxFile.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
    Assert-True ((Normalize-Thumb " aa bb `r`ncc ") -eq 'AABBCC') 'Normalize-Thumb fallita.'
    Assert-True ($ScenarioCatalog.Count -eq 12) 'Catalogo scenari incompleto.'
    foreach($suiteName in @('Core','Renewal','All')){
        Assert-True ($SuiteCatalog.ContainsKey($suiteName)) "Suite mancante: $suiteName"
        foreach($scenarioName in @($SuiteCatalog[$suiteName])){Assert-True ($ScenarioCatalog.Contains($scenarioName)) "Scenario mancante: $scenarioName"}
    }
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('CERTAMENT-FastTest-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp -Force|Out-Null
    try{
        $older=Join-Path $temp 'older.pfx';$newer=Join-Path $temp 'newer.pfx'
        [IO.File]::WriteAllBytes($older,[byte[]](1,2,3));[IO.File]::WriteAllBytes($newer,[byte[]](4,5,6))
        (Get-Item $older).LastWriteTime=(Get-Date).AddMinutes(-2);(Get-Item $newer).LastWriteTime=(Get-Date)
        Assert-True ((Get-PfxFile -Path $temp) -eq $newer) 'Selezione PFX piu recente fallita.'
    }finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
    Ok 'FastTest PASS - helper, catalogo, suite e selezione PFX'
}
function Baseline{$null=Initialize-Platform;Ensure-Dirs;$snap=New-Snapshot;$dir=Join-Path $StateRoot 'manual-baseline';New-Item -ItemType Directory -Path $dir -Force|Out-Null;Save-SnapshotArtifacts $snap $dir 'baseline' $true;Ok "Baseline salvato in $dir"}
function Recover{
    Assert-True (-not [string]::IsNullOrWhiteSpace($RunPath)) 'Specificare -RunPath per Recover.';Assert-True (Test-Path -LiteralPath (Join-Path $RunPath 'baseline.json')) 'baseline.json non trovato.';Initialize-Platform
    $before=Load-Json (Join-Path $RunPath 'baseline.json');$cfgFile=Join-Path $RunPath 'config.backup.dpapi';Assert-True (Test-Path $cfgFile) 'Backup config DPAPI non trovato.';Restore-State $before $RunPath;$post=New-Snapshot;$drift=@(Get-Drift $before $post);Save-Json $post (Join-Path $RunPath 'recover-post.json');Save-Json $drift (Join-Path $RunPath 'recover-drift.json');if($drift.Count -gt 0){throw ('RECOVER FAIL: '+($drift -join ', '))};Ok 'RECOVER PASS'
}

switch($Action){
 'Doctor'{Doctor}
 'Preflight'{Preflight}
 'SelfTest'{SelfTest}
 'FastTest'{FastTest}
 'List'{$ScenarioCatalog.GetEnumerator()|ForEach-Object{[pscustomobject]@{Scenario=$_.Key;Description=$_.Value}}|Format-Table -AutoSize}
 'Baseline'{Baseline}
 'Provision'{Assert-True (-not [string]::IsNullOrWhiteSpace($Scenario)) 'Specificare -Scenario.';Provision-One $Scenario|Format-List}
 'Recover'{Recover}
 'Run'{Assert-True (-not [string]::IsNullOrWhiteSpace($Scenario)) 'Specificare -Scenario.';Run-One $Scenario|Format-List}
 'RunSuite'{Run-Suite $Suite|Format-List}
}
