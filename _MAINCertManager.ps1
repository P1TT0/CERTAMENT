<#
.SYNOPSIS
    CERTAMENT - Automated certificate lifecycle manager for Business Central.

.DESCRIPTION
    Detects expiring certificates, installs newer PFX replacements, updates
    Business Central service instances, IIS bindings, and sends notifications.

    Designed to run unattended via Scheduled Task on client servers.

.NOTES
    Requires: Administrator privileges, IIS, Business Central Management module.
    Configure via config.json (see config.example.json for template).
#>

# --- Require Administrator ---
function Get-TestSleepSeconds {
    param([int]$Seconds)
    $scale = 1.0
    if (-not [string]::IsNullOrWhiteSpace($env:CERTAMENT_TEST_SLEEP_SCALE)) {
        $parsed = 0.0
        if ([double]::TryParse($env:CERTAMENT_TEST_SLEEP_SCALE, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            $scale = [math]::Max(0.0, [math]::Min(1.0, $parsed))
        }
    }
    return [int][math]::Ceiling($Seconds * $scale)
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "CERTAMENT richiede privilegi di Amministratore. Rilancio..."
    Start-Process powershell "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# ============================================================
# Single-instance guard (named mutex)
# ============================================================
$mutexName = 'Global\CERTAMENT_SingleInstance'
$script:mutex = $null
try {
    $script:mutex = [System.Threading.Mutex]::new($false, $mutexName)
}
catch {
    Write-Error "Impossibile creare mutex: $($_.Exception.Message)"
    exit 1
}

if (-not $script:mutex.WaitOne(0)) {
    Write-Warning "Un'altra istanza di CERTAMENT e' gia' in esecuzione. Uscita."
    $script:mutex.Dispose()
    exit 0
}

# Release mutex on exit (normal, error, or Ctrl+C)
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    if ($script:mutex) { try { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() } catch { } }
} | Out-Null

# ============================================================
# Configuration
# ============================================================
$configPath = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $configPath)) {
    Write-Error "Config non trovato: $configPath (copiare config.example.json e personalizzare)"
    exit 1
}

$configRaw = Get-Content -Raw -Path $configPath
# Rimuovi righe con commenti // (stile JSON non standard) prima del parse
$configRaw = ($configRaw -split "\r?\n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
$config = $configRaw | ConvertFrom-Json

# ============================================================
# Logging
# ============================================================
$loggingEnabled = -not ($config.Logging -and $config.Logging.PSObject.Properties['Enabled'] -and $config.Logging.Enabled -eq $false)

$logPath = if ($config.Logging -and -not [string]::IsNullOrWhiteSpace([string]$config.Logging.Path)) {
    [string]$config.Logging.Path
}
else {
    "logs"
}

$logDir = Join-Path $PSScriptRoot $logPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

if ($loggingEnabled) {
    $logFile = Join-Path $logDir ("certament_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    Start-Transcript -Path $logFile -Append | Out-Null
}

# Clean old logs
if ($config.Logging.RetentionDays) {
    $cutoff = (Get-Date).AddDays(-[int]$config.Logging.RetentionDays)
    Get-ChildItem -Path $logDir -Filter "certament_*.log" |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Clean old snapshots (30 days retention)
$snapshotCleanDir = Join-Path $logDir 'snapshots'
if (Test-Path $snapshotCleanDir) {
    $snapCutoff = (Get-Date).AddDays(-30)
    Get-ChildItem -Path $snapshotCleanDir -Filter "snapshot_*.json" |
        Where-Object { $_.LastWriteTime -lt $snapCutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Import BC Management Module
# ============================================================
if ($config.BusinessCentral.UseLatestModule -eq $true) {
    $bcCommand = Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue
    if ($bcCommand) {
        Write-Host "Modulo BC gia disponibile in sessione."
    }
    else {
        $bcModulePaths = Get-ChildItem -Path "C:\Program Files\Microsoft Dynamics 365 Business Central" `
            -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" `
            -ErrorAction SilentlyContinue

        if (-not $bcModulePaths) {
            Write-Error "Nessun modulo Business Central trovato."
            Stop-Transcript | Out-Null
            exit 1
        }

        $orderedCandidates = $bcModulePaths | Sort-Object `
            @{ Expression = { if ($_.FullName -match '\\Admin\\') { 1 } else { 0 } } }, `
            @{ Expression = 'LastWriteTime'; Descending = $true }

        $importedPath = $null
        $importErrors = @()

        foreach ($candidate in $orderedCandidates) {
            try {
                Remove-Module -Name Microsoft.Dynamics.Nav.Management -ErrorAction SilentlyContinue
                Import-Module $candidate.FullName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

                $bcCommand = Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue
                if ($bcCommand) {
                    $importedPath = $candidate.FullName
                    break
                }

                $importErrors += ("{0} -> cmdlet Get-NAVServerInstance non disponibile" -f $candidate.FullName)
            }
            catch {
                $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
                $importErrors += ("{0} -> {1}" -f $candidate.FullName, $errMsg)
            }
        }

        if (-not $importedPath) {
            $firstErrors = ($importErrors | Select-Object -First 5) -join "`n"
            Write-Error "Nessun modulo BC importabile in questa sessione. Errori principali:`n$firstErrors"
            Stop-Transcript | Out-Null
            exit 1
        }

        Write-Host "Modulo BC importato da: $importedPath"
    }
}

# ============================================================
# Import CERTAMENT Modules
# ============================================================
$moduleDir = Join-Path $PSScriptRoot "modules"
@(
    'Get-BCThumbprint',
    'Get-CertDetails',
    'Get-PfxFile',
    'Install-PfxCert',
    'Update-BCServiceCert',
    'Update-IISBinding',
    'Test-BCWebServices',
    'Send-Notification'
) | ForEach-Object {
    Import-Module (Join-Path $moduleDir "$_.psm1") -Force
}

$script:HeartbeatFailureNotified = $false

# ============================================================
# Snapshot persistence directory
# ============================================================
$script:SnapshotDir = Join-Path $PSScriptRoot (Join-Path $logPath 'snapshots')
if (-not (Test-Path $script:SnapshotDir)) { New-Item -ItemType Directory -Path $script:SnapshotDir -Force | Out-Null }

# ============================================================
# Helper: save binding snapshots to JSON file
# ============================================================
function Save-BindingSnapshot {
    param(
        [string]$OldThumbprint,
        [string]$NewThumbprint,
        [array]$SslSnapshot   = @(),
        [array]$UrlAclSnapshot = @(),
        [array]$IISSnapshot   = @()
    )

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $fileName = "snapshot_{0}_{1}.json" -f $ts, ($OldThumbprint.Substring(0, [Math]::Min(8, $OldThumbprint.Length)))
    $filePath = Join-Path $script:SnapshotDir $fileName

    $data = [ordered]@{
        Timestamp     = (Get-Date).ToString('o')
        Server        = $env:COMPUTERNAME
        OldThumbprint = $OldThumbprint
        NewThumbprint = $NewThumbprint
        SslBindings   = @($SslSnapshot | ForEach-Object {
            [ordered]@{ Endpoint = $_.Endpoint; IsHostnamePort = $_.IsHostnamePort; CertHash = $_.CertHash; AppId = $_.AppId; StoreName = $_.StoreName }
        })
        UrlAcls       = @($UrlAclSnapshot | ForEach-Object {
            [ordered]@{ Url = $_.Url; SDDL = $_.SDDL }
        })
        IISBindings   = @($IISSnapshot | ForEach-Object {
            [ordered]@{ BindingInformation = $_.BindingInformation; CertificateStoreName = $_.CertificateStoreName; SslFlags = $_.SslFlags; Thumbprint = $_.Thumbprint }
        })
    }

    try {
        $data | ConvertTo-Json -Depth 6 | Set-Content -Path $filePath -Encoding UTF8 -Force
        Write-Host "  Snapshot salvato su disco: $filePath"
        return $filePath
    }
    catch {
        Write-Warning "Errore salvataggio snapshot: $($_.Exception.Message)"
        return $null
    }
}

# ============================================================
# Helper: load latest binding snapshot from disk
# ============================================================
function Get-LatestBindingSnapshot {
    param(
        [string]$Thumbprint = ""
    )

    if (-not (Test-Path $script:SnapshotDir)) { return $null }

    $pattern = if ($Thumbprint) {
        $prefix = $Thumbprint.Substring(0, [Math]::Min(8, $Thumbprint.Length))
        "snapshot_*_$prefix.json"
    }
    else {
        "snapshot_*.json"
    }

    $latest = Get-ChildItem -Path $script:SnapshotDir -Filter $pattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $latest) { return $null }

    try {
        $data = Get-Content -Raw -Path $latest.FullName -ErrorAction Stop | ConvertFrom-Json
        Write-Host "  Ultimo snapshot caricato da: $($latest.Name) ($($data.Timestamp))"
        return $data
    }
    catch {
        Write-Warning "Errore lettura snapshot $($latest.Name): $($_.Exception.Message)"
        return $null
    }
}

# ============================================================
# Helper: exit with transcript cleanup
# ============================================================
function Exit-WithCode {
    param([int]$Code)
    try { Stop-Transcript | Out-Null } catch {}
    exit $Code
}


function Get-CertificateDnsNames {
    param([object]$Certificate)
    if($null -ne $Certificate.DnsNameList){return @($Certificate.DnsNameList | ForEach-Object { [string]$_.Unicode } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })}
    if($null -ne $Certificate.DnsNames){return @(([string]$Certificate.DnsNames -split ',')|ForEach-Object{$_.Trim()}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)})}
    return @()
}

function Get-ConfiguredEndpointDnsNames {
    param([string]$SiteName,[string]$BindingInformation)
    $configured=@();$configuredExpected=@()
    if($config.IIS -and $config.IIS.PSObject.Properties['ExpectedDnsNames']){$configuredExpected+=@($config.IIS.ExpectedDnsNames);$configured+=@($configuredExpected)}
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $binding=Get-WebBinding -Name $SiteName -Protocol 'https' -ErrorAction Stop|Where-Object{[string]$_.BindingInformation -eq $BindingInformation}|Select-Object -First 1
        if($null -ne $binding -and -not [string]::IsNullOrWhiteSpace([string]$binding.HostHeader)){$configured+=[string]$binding.HostHeader}
    } catch { }
    $normalized=@()
    foreach($name in @($configured)){
        $value=([string]$name -replace '\s+','').Trim().ToLowerInvariant()
        if(-not [string]::IsNullOrWhiteSpace($value)){$normalized+=$value}
    }
    $expected=@($configuredExpected|ForEach-Object{([string]$_).Trim().ToLowerInvariant()}|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}|Sort-Object -Unique)
    $hostHeaders=@($normalized|Where-Object{$_ -notin $expected})
    $conflict=($expected.Count -gt 0 -and $hostHeaders.Count -gt 0 -and -not (Test-DnsIdentityMatch -ExpectedNames $expected -CandidateNames $hostHeaders))
    return [pscustomobject]@{ExpectedNames=$expected;HostHeaders=$hostHeaders;Names=@($expected);Conflict=$conflict}
}

function Test-DnsIdentityMatch {
    param([string[]]$ExpectedNames,[string[]]$CandidateNames)
    foreach($expected in @($ExpectedNames)){
        foreach($candidate in @($CandidateNames)){
            if($expected -eq $candidate){return $true}
            if($expected.StartsWith('*.') -and (Test-WildcardDnsMatch $expected $candidate)){return $true}
            if($candidate.StartsWith('*.') -and (Test-WildcardDnsMatch $candidate $expected)){return $true}
        }
    }
    return $false
}

function Test-WildcardDnsMatch {
    param([string]$Wildcard,[string]$Name)
    $suffix=$Wildcard.Substring(2)
    if([string]::IsNullOrWhiteSpace($suffix) -or $Name -notlike ('*.'+$suffix)){return $false}
    return (($Name.Length - $suffix.Length - 1) -gt 0 -and ([string]$Name.Substring(0,$Name.Length-$suffix.Length-1) -notmatch '\.'))
}

function Test-PfxCandidate {
    param(
        [object]$Certificate,
        [object]$CurrentCertificate,
        [string[]]$ExpectedDnsNames
    )

    $candidateNames=@(Get-CertificateDnsNames $Certificate | ForEach-Object { $_.Trim().ToLowerInvariant() })
    if(@($ExpectedDnsNames).Count -eq 0){return 'No configured IIS/BC endpoint DNS identity is available'}
    if(-not (Test-DnsIdentityMatch -ExpectedNames $ExpectedDnsNames -CandidateNames $candidateNames)){return 'SAN/DNS identity does not match configured endpoint'}
    $serverAuth=@($Certificate.EnhancedKeyUsageList|Where-Object{[string]$_.ObjectId.Value -eq '1.3.6.1.5.5.7.3.1' -or [string]$_.FriendlyName -eq 'Server Authentication'})
    if($serverAuth.Count -eq 0){return 'Server Authentication EKU missing'}
    if($Certificate.NotAfter -lt (Get-Date)){return 'PFX certificate is expired'}
    if($Certificate.NotAfter -le $CurrentCertificate.NotAfter){return 'PFX certificate is not newer than current certificate'}
    return $null
}

function Select-PfxCandidate {
    param(
        [object[]]$Candidates,
        [securestring]$Password,
        [object]$CurrentCertificate,
        [string[]]$ExpectedDnsNames
    )
    $valid=@();$rejected=@()
    foreach($file in @($Candidates)){
        try{
            $data=Get-PfxData -FilePath $file.FullName -Password $Password -ErrorAction Stop
            $certificate=$data.EndEntityCertificates|Select-Object -First 1
            $reason=Test-PfxCandidate $certificate $CurrentCertificate $ExpectedDnsNames
            if($null -eq $reason){$valid+=[pscustomobject]@{File=$file;Data=$data;Certificate=$certificate}}
            else{$rejected+=[pscustomobject]@{Name=$file.Name;Reason=$reason}}
        }catch{$rejected+=[pscustomobject]@{Name=$file.Name;Reason='PFX unreadable or password invalid'}}
    }
    foreach($item in @($rejected)){Write-Warning ("PFX scartato: {0} ({1})" -f $item.Name,$item.Reason)}
    $selected=$valid|Sort-Object @{Expression={$_.Certificate.NotAfter};Descending=$true},@{Expression={$_.Certificate.Thumbprint};Descending=$false},@{Expression={$_.File.Name};Descending=$false}|Select-Object -First 1
    return [pscustomobject]@{Selected=$selected;Valid=@($valid);Rejected=@($rejected)}
}
# ============================================================
# Helper: customer context
# ============================================================
function Get-CustomerName {
    if ($config.Context -and -not [string]::IsNullOrWhiteSpace([string]$config.Context.CustomerName)) {
        return [string]$config.Context.CustomerName.Trim()
    }
    return $null
}

$script:CustomerName = Get-CustomerName

function Get-CustomerLabel {
    if ([string]::IsNullOrWhiteSpace([string]$script:CustomerName)) {
        return "Cliente non specificato"
    }
    return [string]$script:CustomerName
}

function Get-CertamentTitle {
    param([string]$BaseTitle)

    if ([string]::IsNullOrWhiteSpace([string]$script:CustomerName)) {
        return $BaseTitle
    }
    return ("{0} [{1}]" -f $BaseTitle, $script:CustomerName)
}

# ============================================================
# Helper: build webhook hashtable from config
# ============================================================
function Get-WebhookTable {
    if ($config.Notifications -and $config.Notifications.EnableWebhook -eq $false) {
        Write-Host "[INFO] Webhook disabilitati (Notifications.EnableWebhook=false). Notifiche soppresse."
        return @{}
    }
    $wh = @{}
    if ($config.Notifications.Webhooks.Customer) { $wh['Customer'] = $config.Notifications.Webhooks.Customer }
    if ($config.Notifications.Webhooks.Internal) { $wh['Internal'] = $config.Notifications.Webhooks.Internal }
    return $wh
}

# ============================================================
# Helper: send internal notification
# ============================================================
function Send-InternalNotification {
    param(
        [string]$Title,
        [string]$Message
    )

    $webhooks = Get-WebhookTable
    if (-not $webhooks.ContainsKey('Internal')) {
        Write-Warning "Webhook Internal non configurato. Notifica interna non inviata."
        return $false
    }

    $fullTitle = Get-CertamentTitle -BaseTitle $Title
    return (Send-Notification -Title $fullTitle -Message $Message -Target "Internal" -Webhooks $webhooks)
}

# ============================================================
# Helper: send customer notification with fallback on failure
# ============================================================
function Send-CustomerNotification {
    param(
        [string]$Title,
        [string]$Message,
        [string]$ContextLabel = ""
    )

    if ($config.Notifications -and $config.Notifications.CertificateExpiry -and
        $config.Notifications.CertificateExpiry.EnableCustomerNotification -eq $false) {
        Write-Host "[INFO] Notifiche Customer disabilitate (EnableCustomerNotification=false). Messaggio soppresso."
        return $true
    }

    $webhooks = Get-WebhookTable
    $fullTitle = Get-CertamentTitle -BaseTitle $Title

    if (-not $webhooks.ContainsKey('Customer')) {
        $detail = if ([string]::IsNullOrWhiteSpace($ContextLabel)) { "Webhook Customer non configurato" } else { $ContextLabel }
        Write-Warning "Webhook Customer non configurato."
        Invoke-Heartbeat -Status "NotificationFailed" -Stage "CustomerNotificationMissing" -Detail $detail | Out-Null

        $fallbackMsg = @"
Invio notifica CUSTOMER non possibile su server **$env:COMPUTERNAME**.

**Cliente:** $(Get-CustomerLabel)
**Contesto:** $detail
**Motivo:** Webhook Customer non configurato.
"@
        $null = Send-InternalNotification -Title "CERTAMENT - Alert notifica Customer fallita" -Message $fallbackMsg
        return $false
    }

    $sent = Send-Notification -Title $fullTitle -Message $Message -Target "Customer" -Webhooks $webhooks
    if ($sent) { return $true }

    $failDetail = if ([string]::IsNullOrWhiteSpace($ContextLabel)) { "Invio notifica Customer fallito" } else { $ContextLabel }
    Invoke-Heartbeat -Status "NotificationFailed" -Stage "CustomerNotification" -Detail $failDetail | Out-Null

    $fallbackMsg = @"
Invio notifica CUSTOMER fallito su server **$env:COMPUTERNAME**.

**Cliente:** $(Get-CustomerLabel)
**Contesto:** $failDetail
**Azione:** verificare webhook Customer / flow Power Automate.
"@
    $null = Send-InternalNotification -Title "CERTAMENT - Alert notifica Customer fallita" -Message $fallbackMsg
    return $false
}

# ============================================================
# Helper: send failure notification
# ============================================================
function Send-FailureNotification {
    param([string]$Context, [string]$ErrorDetail)

    $webhooks = Get-WebhookTable
    if (-not $webhooks.ContainsKey('Internal')) { return }

    $hostname = $env:COMPUTERNAME
    $msg = @"
Si e' verificato un errore durante l'esecuzione di CERTAMENT sul server **$hostname**.

**Cliente:** $(Get-CustomerLabel)
**Contesto:** $Context
**Errore:** $ErrorDetail
"@

    $null = Send-InternalNotification -Title "CERTAMENT - Errore" -Message $msg
}

# ============================================================
# Helper: heartbeat settings
# ============================================================
function Get-HeartbeatSettings {
    $enabled = $false
    $url = $null
    $timeoutSec = 10
    $notifyInternalOnFailure = $true

    if ($config.Heartbeat) {
        if ($null -ne $config.Heartbeat.Enabled) {
            $enabled = ($config.Heartbeat.Enabled -eq $true)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$config.Heartbeat.Url)) {
            $url = [string]$config.Heartbeat.Url
        }

        if ($null -ne $config.Heartbeat.TimeoutSec) {
            try {
                $parsedTimeout = [int]$config.Heartbeat.TimeoutSec
                if ($parsedTimeout -gt 0) { $timeoutSec = $parsedTimeout }
            }
            catch { }
        }

        if ($null -ne $config.Heartbeat.NotifyInternalOnFailure) {
            $notifyInternalOnFailure = ($config.Heartbeat.NotifyInternalOnFailure -eq $true)
        }
    }

    if ([string]::IsNullOrWhiteSpace($url)) {
        $enabled = $false
    }

    return [PSCustomObject]@{
        Enabled                 = $enabled
        Url                     = $url
        TimeoutSec              = $timeoutSec
        NotifyInternalOnFailure = $notifyInternalOnFailure
    }
}

# ============================================================
# Helper: send heartbeat to Azure
# ============================================================
function Invoke-Heartbeat {
    param(
        [string]$Status,
        [string]$Stage,
        [string]$Detail = ""
    )

    $hb = Get-HeartbeatSettings
    if (-not $hb.Enabled) { return $true }

    $payload = @{
        tool      = "CERTAMENT"
        customer  = (Get-CustomerLabel)
        server    = $env:COMPUTERNAME
        status    = $Status
        stage     = $Stage
        detail    = $Detail
        timestamp = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6

    try {
        Invoke-RestMethod -Method POST -Uri $hb.Url -ContentType "application/json; charset=utf-8" `
            -Body $payload -TimeoutSec $hb.TimeoutSec -ErrorAction Stop | Out-Null
        Write-Host "Heartbeat Azure inviato: $Status / $Stage"
        return $true
    }
    catch {
        $errMsg = if ($_.Exception) { $_.Exception.Message } else { $_.ToString() }
        Write-Warning "Heartbeat Azure fallito ($Status / $Stage): $errMsg"

        if ($hb.NotifyInternalOnFailure -and -not $script:HeartbeatFailureNotified) {
            $script:HeartbeatFailureNotified = $true
            try {
                Send-FailureNotification -Context "Heartbeat Azure ($Status / $Stage)" -ErrorDetail $errMsg
            }
            catch { }
        }

        return $false
    }
}

# ============================================================
# Helper: wait for web services with polling
# ============================================================
function Wait-ForWebServices {
    param(
        [int]$MaxWaitSec = 600,
        [int]$IntervalSec = 30,
        [string]$ExpectedThumbprint = '',
        [string[]]$InstanceNames = @()
    )

    $deadline = (Get-Date).AddSeconds($MaxWaitSec)
    $attempt = 0
    $wsParams = @{ TimeoutSec = 15 }
    if ($ExpectedThumbprint) { $wsParams['ExpectedThumbprint'] = $ExpectedThumbprint }
    if ($InstanceNames.Count -gt 0) { $wsParams['InstanceNames'] = $InstanceNames }

    while ((Get-Date) -lt $deadline) {
        $attempt++
        Write-Host ("  Attesa servizi web (tentativo {0}, max {1}s)..." -f $attempt, $MaxWaitSec)
        $results = Test-BCWebServices @wsParams
        if ($results) {
            $errors = @($results | Where-Object { $_.Status -eq 'ERROR' })
            $sslMismatches = @($results | Where-Object { $_.SslMatch -eq $false })
            if ($errors.Count -eq 0 -and $sslMismatches.Count -eq 0) {
                Write-Host "  Servizi web tutti operativi, SSL verificato."
                return $results
            }
            if ($errors.Count -gt 0) {
                $errSummary = ($errors | ForEach-Object { "$($_.Instance): $($_.Error)" }) -join '; '
                Write-Host "  Servizi non ancora pronti: $errSummary"
            }
            if ($sslMismatches.Count -gt 0) {
                $sslSummary = ($sslMismatches | ForEach-Object { "$($_.Instance): SSL $($_.SslThumbprint)" }) -join '; '
                Write-Host "  SSL mismatch: $sslSummary"
            }
        }
        else {
            Write-Host "  Test-BCWebServices non ha restituito risultati."
        }
        if ((Get-Date).AddSeconds($IntervalSec) -ge $deadline) { break }
        Start-Sleep -Seconds $IntervalSec
    }
    Write-Warning "Timeout ($MaxWaitSec s): alcuni servizi non rispondono."
    return $results
}

# ============================================================
# Helper: snapshot netsh http sslcert bindings (port-level SSL)
# ============================================================
function Get-SslCertBindingSnapshot {
    param(
        [string]$Thumbprint = ""
    )

    $snapshot = @()
    $thumbNorm = if ($Thumbprint) { ($Thumbprint -replace '\s', '').ToUpper() } else { "" }

    try {
        $output = netsh http show sslcert 2>&1 | Out-String
        # Parse netsh output into binding blocks
        $blocks = $output -split '(?=\s*IP:port\s+:|\s*Hostname:port\s+:)'

        foreach ($block in $blocks) {
            if ($block -notmatch '(IP:port|Hostname:port)\s*:\s*(.+)') { continue }
            $endpoint = $Matches[2].Trim()
            $isHostnamePort = $block -match 'Hostname:port'

            $hash = ''
            if ($block -match 'Certificate Hash\s*:\s*([0-9a-fA-F]+)') {
                $hash = $Matches[1].Trim().ToUpper()
            }

            $appId = ''
            if ($block -match 'Application ID\s*:\s*(\{[^}]+\})') {
                $appId = $Matches[1].Trim()
            }

            $storeName = $null
            if ($block -match 'Certificate Store Name\s*:\s*(\S+)') {
                $raw = $Matches[1].Trim()
                if ($raw -ne '(null)') { $storeName = $raw }
            }

            # If filtering by thumbprint, only include matching bindings
            if ($thumbNorm -and $hash -ne $thumbNorm) { continue }

            $snapshot += [PSCustomObject]@{
                Endpoint       = $endpoint
                IsHostnamePort = $isHostnamePort
                CertHash       = $hash
                AppId          = $appId
                StoreName      = $storeName
            }
        }
    }
    catch {
        Write-Warning "Errore snapshot SSL bindings: $($_.Exception.Message)"
    }

    return $snapshot
}

# ============================================================
# Helper: verify netsh SSL bindings post-update
# ============================================================
function Test-SslCertBindings {
    param(
        [string]$ExpectedThumbprint,
        [array]$Snapshot
    )

    if (-not $Snapshot -or $Snapshot.Count -eq 0) { return @() }

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $errors = @()

    try {
        $currentSnapshot = Get-SslCertBindingSnapshot
    }
    catch {
        return @("Impossibile leggere SSL bindings correnti: $($_.Exception.Message)")
    }

    foreach ($snap in $Snapshot) {
        $current = $currentSnapshot | Where-Object { $_.Endpoint -eq $snap.Endpoint }
        if (-not $current) {
            $errors += "SSL binding $($snap.Endpoint) : MANCANTE (era $($snap.CertHash))"
            continue
        }
        if ($current.CertHash -ne $expectedNorm) {
            $errors += "SSL binding $($snap.Endpoint) : hash $($current.CertHash) (atteso $expectedNorm)"
        }
    }

    return $errors
}

# ============================================================
# Helper: repair netsh SSL bindings from snapshot
# ============================================================
function Repair-SslCertBindings {
    param(
        [array]$Snapshot,
        [string]$NewThumbprint
    )

    if (-not $Snapshot -or $Snapshot.Count -eq 0) {
        Write-Warning "Nessun snapshot SSL bindings disponibile per il ripristino."
        return @()
    }

    $newNorm = ($NewThumbprint -replace '\s', '').ToUpper()
    $results = @()

    # Verify the cert exists in the store before attempting repairs
    $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { ($_.Thumbprint -replace '\s', '').ToUpper() -eq $newNorm }
    if (-not $cert) {
        return @([PSCustomObject]@{ Endpoint = '*'; Action = 'Error'; Detail = "Certificato $newNorm non trovato nello store" })
    }

    # Get current state
    try {
        $currentBindings = Get-SslCertBindingSnapshot
    }
    catch {
        return @([PSCustomObject]@{ Endpoint = '*'; Action = 'Error'; Detail = "Impossibile leggere bindings correnti: $($_.Exception.Message)" })
    }

    foreach ($snap in $Snapshot) {
        $endpoint = $snap.Endpoint
        $current = $currentBindings | Where-Object { $_.Endpoint -eq $endpoint }

        if ($current -and $current.CertHash -eq $newNorm) {
            $results += [PSCustomObject]@{ Endpoint = $endpoint; Action = 'OK'; Detail = 'Certificato corretto' }
            continue
        }

        # Need to fix: delete existing (if any) then add with new cert
        try {
            if ($current) {
                # Delete existing binding first (regardless of who owns it)
                if ($current.IsHostnamePort) {
                    $null = netsh http delete sslcert hostnameport="$endpoint" 2>&1
                }
                else {
                    $null = netsh http delete sslcert ipport="$endpoint" 2>&1
                }
                Write-Host "  SSL Repair: rimosso binding $endpoint (era hash=$($current.CertHash), AppId=$($current.AppId))"
            }

            # Re-add with new cert hash
            $appIdParam = if ($snap.AppId) { "appid=$($snap.AppId)" } else { "appid={00000000-0000-0000-0000-000000000000}" }
            $addArgs = @("certhash=$newNorm", $appIdParam)
            if ($snap.StoreName) { $addArgs += "certstorename=$($snap.StoreName)" }

            if ($snap.IsHostnamePort) {
                $addOut = netsh http add sslcert hostnameport="$endpoint" @addArgs 2>&1
            }
            else {
                $addOut = netsh http add sslcert ipport="$endpoint" @addArgs 2>&1
            }

            $addOutStr = $addOut | Out-String
            if ($LASTEXITCODE -ne 0 -or $addOutStr -match 'Error|errore') {
                # Conflict: port may be occupied by a binding we didn't see (race) -- force delete + retry
                Write-Warning "  SSL Repair: add fallito per $endpoint, tentativo force-delete + retry..."
                if ($snap.IsHostnamePort) {
                    $null = netsh http delete sslcert hostnameport="$endpoint" 2>&1
                    $addOut2 = netsh http add sslcert hostnameport="$endpoint" @addArgs 2>&1
                }
                else {
                    $null = netsh http delete sslcert ipport="$endpoint" 2>&1
                    $addOut2 = netsh http add sslcert ipport="$endpoint" @addArgs 2>&1
                }

                $addOutStr2 = $addOut2 | Out-String
                if ($LASTEXITCODE -ne 0 -or $addOutStr2 -match 'Error|errore') {
                    $results += [PSCustomObject]@{ Endpoint = $endpoint; Action = 'Error'; Detail = "netsh add fallito anche dopo force-delete: $addOutStr2" }
                    Write-Warning "  SSL Repair: errore ricreazione binding $endpoint anche dopo force-delete"
                }
                else {
                    $action = if ($current) { 'ForceFixed' } else { 'ForceRecreated' }
                    $results += [PSCustomObject]@{ Endpoint = $endpoint; Action = $action; Detail = "Binding ricreato dopo rimozione conflitto (certificato $newNorm)" }
                    Write-Host "  SSL Repair: binding $endpoint $($action.ToLower()) dopo rimozione conflitto."
                }
            }
            else {
                $action = if ($current) { 'Fixed' } else { 'Recreated' }
                $results += [PSCustomObject]@{ Endpoint = $endpoint; Action = $action; Detail = "Binding aggiornato con certificato $newNorm" }
                Write-Host "  SSL Repair: binding $endpoint $($action.ToLower())."
            }
        }
        catch {
            $results += [PSCustomObject]@{ Endpoint = $endpoint; Action = 'Error'; Detail = "Errore: $($_.Exception.Message)" }
            Write-Warning "  SSL Repair: errore binding $endpoint : $($_.Exception.Message)"
        }
    }

    return $results
}

# ============================================================
# Helper: snapshot netsh http urlacl reservations (BC ports)
# ============================================================
function Get-UrlAclSnapshot {
    param(
        [string[]]$InstanceNames = @()
    )

    $snapshot = @()

    try {
        $output = netsh http show urlacl 2>&1 | Out-String

        # Parse blocks: each starts with "    Reserved URL"
        $blocks = $output -split '(?=\s+Reserved URL\s+:)'

        foreach ($block in $blocks) {
            if ($block -notmatch 'Reserved URL\s*:\s*(.+)') { continue }
            $url = $Matches[1].Trim()

            # If filtering by instance names, check URL path contains /<ShortName>/
            # BC instance names come as "MicrosoftDynamicsNavServer$PROD_NUP" but
            # URL ACLs use the short name "/PROD_NUP/" -- extract after "$" if present
            if ($InstanceNames.Count -gt 0) {
                $matched = $false
                foreach ($inst in $InstanceNames) {
                    $shortName = if ($inst -match '\$(.+)$') { $Matches[1] } else { $inst }
                    if ($url -match "/$([regex]::Escape($shortName))/") {
                        $matched = $true
                        break
                    }
                }
                if (-not $matched) { continue }
            }

            $sddl = ''
            if ($block -match 'SDDL:\s*(.+)') {
                $sddl = $Matches[1].Trim()
            }

            $snapshot += [PSCustomObject]@{
                Url  = $url
                SDDL = $sddl
            }
        }
    }
    catch {
        Write-Warning "Errore snapshot URL ACL: $($_.Exception.Message)"
    }

    return $snapshot
}

# ============================================================
# Helper: verify URL ACL reservations still exist
# ============================================================
function Test-UrlAcls {
    param(
        [array]$Snapshot
    )

    if (-not $Snapshot -or $Snapshot.Count -eq 0) { return @() }

    $errors = @()

    try {
        $currentSnapshot = Get-UrlAclSnapshot
    }
    catch {
        return @("Impossibile leggere URL ACL correnti: $($_.Exception.Message)")
    }

    $currentUrls = $currentSnapshot | ForEach-Object { $_.Url }

    foreach ($snap in $Snapshot) {
        if ($snap.Url -notin $currentUrls) {
            $errors += "URL ACL MANCANTE: $($snap.Url)"
        }
    }

    return $errors
}

# ============================================================
# Helper: repair missing URL ACL reservations from snapshot
# ============================================================
function Repair-UrlAcls {
    param(
        [array]$Snapshot
    )

    if (-not $Snapshot -or $Snapshot.Count -eq 0) {
        Write-Warning "Nessun snapshot URL ACL disponibile per il ripristino."
        return @()
    }

    $results = @()

    # Get current state
    try {
        $currentSnapshot = Get-UrlAclSnapshot
    }
    catch {
        return @([PSCustomObject]@{ Url = '*'; Action = 'Error'; Detail = "Impossibile leggere URL ACL correnti: $($_.Exception.Message)" })
    }

    # Build lookup: URL -> current SDDL
    $currentMap = @{}
    foreach ($cur in $currentSnapshot) { $currentMap[$cur.Url] = $cur.SDDL }

    foreach ($snap in $Snapshot) {
        if ($currentMap.ContainsKey($snap.Url)) {
            # URL ACL exists -- verify SDDL matches
            $curSddl = $currentMap[$snap.Url]
            if ($snap.SDDL -and $curSddl -and $curSddl -ne $snap.SDDL) {
                # SDDL mismatch -- delete and recreate with correct SDDL
                Write-Host "  URL ACL Repair: SDDL diverso per $($snap.Url), correzione..."
                try {
                    $null = netsh http delete urlacl url="$($snap.Url)" 2>&1
                    $addOut = netsh http add urlacl url="$($snap.Url)" sddl="$($snap.SDDL)" 2>&1
                    $addOutStr = $addOut | Out-String
                    if ($LASTEXITCODE -ne 0 -or $addOutStr -match 'Error|errore') {
                        $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'Error'; Detail = "Correzione SDDL fallita: $addOutStr" }
                    }
                    else {
                        $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'Fixed'; Detail = "SDDL corretto da $curSddl a $($snap.SDDL)" }
                    }
                }
                catch {
                    $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'Error'; Detail = "Errore correzione SDDL: $($_.Exception.Message)" }
                }
            }
            else {
                $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'OK'; Detail = 'Presente' }
            }
            continue
        }

        # Missing -- recreate
        try {
            if ($snap.SDDL) {
                $addOut = netsh http add urlacl url="$($snap.Url)" sddl="$($snap.SDDL)" 2>&1
            }
            else {
                # Fallback: grant NETWORK SERVICE listen permission
                $addOut = netsh http add urlacl url="$($snap.Url)" user="NT AUTHORITY\NETWORK SERVICE" listen=yes 2>&1
            }

            $addOutStr = $addOut | Out-String
            if ($LASTEXITCODE -ne 0 -or $addOutStr -match 'Error|errore') {
                # Conflict: URL ACL might exist from a different source -- force delete + retry
                Write-Warning "  URL ACL Repair: add fallito per $($snap.Url), tentativo force-delete + retry..."
                $null = netsh http delete urlacl url="$($snap.Url)" 2>&1

                if ($snap.SDDL) {
                    $addOut2 = netsh http add urlacl url="$($snap.Url)" sddl="$($snap.SDDL)" 2>&1
                }
                else {
                    $addOut2 = netsh http add urlacl url="$($snap.Url)" user="NT AUTHORITY\NETWORK SERVICE" listen=yes 2>&1
                }

                $addOutStr2 = $addOut2 | Out-String
                if ($LASTEXITCODE -ne 0 -or $addOutStr2 -match 'Error|errore') {
                    $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'Error'; Detail = "netsh add urlacl fallito anche dopo force-delete: $addOutStr2" }
                    Write-Warning "  URL ACL Repair: errore ricreazione $($snap.Url) anche dopo force-delete"
                }
                else {
                    $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'ForceRecreated'; Detail = "URL ACL ricreata dopo rimozione conflitto" }
                    Write-Host "  URL ACL Repair: ricreata $($snap.Url) dopo rimozione conflitto"
                }
            }
            else {
                $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'Recreated'; Detail = "URL ACL ricreata" }
                Write-Host "  URL ACL Repair: ricreata $($snap.Url)"
            }
        }
        catch {
            $results += [PSCustomObject]@{ Url = $snap.Url; Action = 'Error'; Detail = "Errore: $($_.Exception.Message)" }
            Write-Warning "  URL ACL Repair: errore $($snap.Url) : $($_.Exception.Message)"
        }
    }

    return $results
}

# ============================================================
# Helper: verify BC post-update (thumbprint + Running state)
# ============================================================
function Test-BCPostUpdate {
    param(
        [string]$ExpectedThumbprint,
        # When provided, only verify instances that previously used this thumbprint.
        # Instances with a different certificate are not checked.
        [string]$OldThumbprint = ""
    )

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $oldNorm = if ($OldThumbprint) { ($OldThumbprint -replace '\s', '').ToUpper() } else { "" }
    $errors = @()

    try {
        $instances = Get-NAVServerInstance -ErrorAction Stop
    }
    catch {
        return @("Impossibile enumerare istanze BC: $($_.Exception.Message)")
    }

    foreach ($inst in $instances) {
        $name = $inst.ServerInstance

        # Skip disabled services (StartupType = Disabled)
        try {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled') { continue }
        }
        catch { }

        $hasThumb = $false

        try {
            $thumb = Get-NAVServerConfiguration -ServerInstance $name -KeyName "ServicesCertificateThumbprint" -ErrorAction Stop
            if ($thumb -and $thumb.Trim() -ne "") {
                $hasThumb = $true
                $thumbNorm = ($thumb -replace '\s', '').ToUpper()

                # If OldThumbprint filter is set, skip instances that are unrelated to this renewal.
                # An instance is relevant only if its current thumbprint is the expected new value
                # or still the old value (not yet updated).
                if ($oldNorm -and $thumbNorm -ne $expectedNorm -and $thumbNorm -ne $oldNorm) {
                    $hasThumb = $false
                    continue
                }

                if ($thumbNorm -ne $expectedNorm) {
                    $errors += "$name : thumbprint $thumbNorm (atteso $expectedNorm)"
                }
            }
        }
        catch {
            $errors += "$name : errore lettura thumbprint - $($_.Exception.Message)"
        }

        # Controlla Running solo per istanze con thumbprint configurato
        if ($hasThumb -and $inst.State -and $inst.State -ne 'Running') {
            $errors += "$name : stato $($inst.State) (atteso Running)"
        }
    }

    return $errors
}

# ============================================================
# Helper: snapshot IIS HTTPS bindings (pre-update safety net)
# ============================================================
function Get-IISBindingSnapshot {
    param(
        [string]$SiteName = "Microsoft Dynamics 365 Business Central Web Client",
        [string]$Thumbprint = ''
    )

    $snapshot = @()
    $thumbFilter=($Thumbprint -replace '\s','').ToUpper()

    try {
        if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "Microsoft.Web.Administration" })) {
            $dllPath = "C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll"
            if (Test-Path $dllPath) { [void][Reflection.Assembly]::LoadFrom($dllPath) }
            else { Write-Warning "Microsoft.Web.Administration.dll non trovata (snapshot)."; return $snapshot }
        }

        $sm = New-Object Microsoft.Web.Administration.ServerManager
        $site = $sm.Sites[$SiteName]
        if (-not $site) { Write-Warning "Sito '$SiteName' non trovato in IIS (snapshot)."; return $snapshot }

        foreach ($binding in $site.Bindings) {
            if ($binding.Protocol -ne 'https') { continue }
            $thumb = ''
            if ($binding.CertificateHash) {
                $thumb = ([System.BitConverter]::ToString($binding.CertificateHash) -replace '-', '').ToUpper()
            }
            if($thumbFilter -and $thumb -ne $thumbFilter){continue}
            $snapshot += [PSCustomObject]@{
                BindingInformation   = $binding.BindingInformation
                CertificateStoreName = $(if ($binding.CertificateStoreName) { $binding.CertificateStoreName } else { 'My' })
                SslFlags             = $(try { $binding.SslFlags } catch { 0 })
                Thumbprint           = $thumb
            }
        }
    }
    catch {
        Write-Warning "Errore snapshot IIS: $($_.Exception.Message)"
    }

    return $snapshot
}

# ============================================================
# Helper: repair missing/broken IIS HTTPS bindings from snapshot
# ============================================================
function Repair-IISBindings {
    param(
        [array]$Snapshot,
        [string]$NewThumbprint,
        [string]$SiteName = "Microsoft Dynamics 365 Business Central Web Client"
    )

    if (-not $Snapshot -or $Snapshot.Count -eq 0) {
        Write-Warning "Nessun snapshot IIS disponibile per il ripristino."
        return @()
    }

    $newNorm = ($NewThumbprint -replace '\s', '').ToUpper()
    $results = @()

    try {
        if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "Microsoft.Web.Administration" })) {
            $dllPath = "C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll"
            if (Test-Path $dllPath) { [void][Reflection.Assembly]::LoadFrom($dllPath) }
            else { return @([PSCustomObject]@{ Binding = '*'; Action = 'Error'; Detail = 'DLL non trovata' }) }
        }

        $cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop |
            Where-Object { ($_.Thumbprint -replace '\s', '').ToUpper() -eq $newNorm }
        if (-not $cert) {
            return @([PSCustomObject]@{ Binding = '*'; Action = 'Error'; Detail = "Certificato $newNorm non trovato nello store" })
        }
        $newHash = $cert.GetCertHash()

        $sm = New-Object Microsoft.Web.Administration.ServerManager
        $site = $sm.Sites[$SiteName]
        if (-not $site) {
            return @([PSCustomObject]@{ Binding = $SiteName; Action = 'Error'; Detail = 'Sito non trovato in IIS' })
        }

        foreach ($snap in $Snapshot) {
            $bindingInfo = $snap.BindingInformation
            $existing = $site.Bindings | Where-Object {
                $_.Protocol -eq 'https' -and $_.BindingInformation -eq $bindingInfo
            }

            if ($existing) {
                # Binding exists -- verify cert is correct
                $currentThumb = ''
                if ($existing.CertificateHash) {
                    $currentThumb = ([System.BitConverter]::ToString($existing.CertificateHash) -replace '-', '').ToUpper()
                }
                if ($currentThumb -eq $newNorm) {
                    $results += [PSCustomObject]@{ Binding = $bindingInfo; Action = 'OK'; Detail = 'Certificato corretto' }
                }
                else {
                    try {
                        $existing.CertificateHash = $newHash
                        $existing.CertificateStoreName = 'My'
                        $sm.CommitChanges()
                        $results += [PSCustomObject]@{ Binding = $bindingInfo; Action = 'Fixed'; Detail = "Certificato corretto da $currentThumb a $newNorm" }
                        Write-Host "  Repair: binding $bindingInfo certificato corretto."
                    }
                    catch {
                        $results += [PSCustomObject]@{ Binding = $bindingInfo; Action = 'Error'; Detail = "Errore fix certificato: $($_.Exception.Message)" }
                    }
                }
            }
            else {
                # Binding missing -- recreate it
                try {
                    Write-Host "  Repair: ricreazione binding mancante $bindingInfo..."
                    $null = $site.Bindings.Add($bindingInfo, $newHash, 'My', $snap.SslFlags)
                    $sm.CommitChanges()
                    $results += [PSCustomObject]@{ Binding = $bindingInfo; Action = 'Recreated'; Detail = "Binding ricreato con certificato $newNorm" }
                    Write-Host "  Repair: binding $bindingInfo ricreato."
                }
                catch {
                    # Conflict: another site may have a binding on the same port
                    $conflictMsg = $_.Exception.Message
                    Write-Warning "  Repair: errore ricreazione $bindingInfo ($conflictMsg). Ricerca conflitto..."

                    # Try to find and remove the conflicting binding from other sites
                    $conflictResolved = $false
                    try {
                        $sm2 = New-Object Microsoft.Web.Administration.ServerManager
                        foreach ($otherSite in $sm2.Sites) {
                            if ($otherSite.Name -eq $SiteName) { continue }
                            $conflicting = $otherSite.Bindings | Where-Object {
                                $_.Protocol -eq 'https' -and $_.BindingInformation -eq $bindingInfo
                            }
                            if ($conflicting) {
                                Write-Host "  Repair: conflitto trovato su sito '$($otherSite.Name)' -- rimozione binding..."
                                $otherSite.Bindings.Remove($conflicting)
                                $sm2.CommitChanges()
                                $conflictResolved = $true
                                break
                            }
                        }
                    }
                    catch {
                        Write-Warning "  Repair: errore ricerca conflitto: $($_.Exception.Message)"
                    }

                    if ($conflictResolved) {
                        # Retry with fresh ServerManager
                        try {
                            $sm3 = New-Object Microsoft.Web.Administration.ServerManager
                            $site3 = $sm3.Sites[$SiteName]
                            $null = $site3.Bindings.Add($bindingInfo, $newHash, 'My', $snap.SslFlags)
                            $sm3.CommitChanges()
                            $results += [PSCustomObject]@{ Binding = $bindingInfo; Action = 'ForceRecreated'; Detail = "Binding ricreato dopo rimozione conflitto da altro sito" }
                            Write-Host "  Repair: binding $bindingInfo ricreato dopo rimozione conflitto."
                        }
                        catch {
                            $results += [PSCustomObject]@{ Binding = $bindingInfo; Action = 'Error'; Detail = "Errore retry dopo rimozione conflitto: $($_.Exception.Message)" }
                        }
                    }
                    else {
                        $results += [PSCustomObject]@{ Binding = $bindingInfo; Action = 'Error'; Detail = "Errore ricreazione: $conflictMsg (nessun conflitto cross-site trovato)" }
                    }
                }
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Binding = '*'; Action = 'Error'; Detail = "Errore generale repair: $($_.Exception.Message)" }
    }

    return $results
}

# ============================================================
# Helper: verify IIS binding post-update
# ============================================================
function Test-IISPostUpdate {
    param(
        [string]$ExpectedThumbprint,
        [string]$SiteName = "Microsoft Dynamics 365 Business Central Web Client",
        [array]$BindingSnapshot = @()
    )

    $expectedNorm = ($ExpectedThumbprint -replace '\s', '').ToUpper()
    $errors = @()

    try {
        if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "Microsoft.Web.Administration" })) {
            $dllPath = "C:\Windows\System32\inetsrv\Microsoft.Web.Administration.dll"
            if (Test-Path $dllPath) { [void][Reflection.Assembly]::LoadFrom($dllPath) }
            else { return @("Microsoft.Web.Administration.dll non trovata") }
        }

        $sm = New-Object Microsoft.Web.Administration.ServerManager
        $site = $sm.Sites[$SiteName]
        if (-not $site) { return @("Sito '$SiteName' non trovato in IIS") }

        if($BindingSnapshot.Count -eq 0){return @()}
        $scopedBindings=@($site.Bindings|Where-Object{$bindingInfo=[string]$_.BindingInformation;@($BindingSnapshot|Where-Object{[string]$_.BindingInformation -eq $bindingInfo}).Count -gt 0})
        foreach ($binding in $scopedBindings) {
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
    }
    catch {
        $errors += "Errore verifica IIS: $($_.Exception.Message)"
    }

    return $errors
}

# ============================================================
# Main
# ============================================================
function Main {
    Write-Host ("=" * 60)
    Write-Host ("CERTAMENT - Avvio [{0}] su {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME)
    Write-Host ("Cliente: {0}" -f (Get-CustomerLabel))
    Write-Host ("=" * 60)

    $hostname = $env:COMPUTERNAME
    $pfxPath = $config.Pfx.Path
    $hadPipelineErrors = $false

    Invoke-Heartbeat -Status "Started" -Stage "MainStart" -Detail "Esecuzione CERTAMENT avviata" | Out-Null
    $notifyBeforeDaysRaw = $null
    if ($config.Notifications -and $config.Notifications.CertificateExpiry) {
        $notifyBeforeDaysRaw = $config.Notifications.CertificateExpiry.NotifyBeforeDays
    }

    if ($null -ne $notifyBeforeDaysRaw -and -not [string]::IsNullOrWhiteSpace([string]$notifyBeforeDaysRaw)) {
        $expiryThreshold = [int]$notifyBeforeDaysRaw
    }
    else {
        $expiryThreshold = 30
    }

    if ($config.IIS -and -not [string]::IsNullOrWhiteSpace([string]$config.IIS.SiteName)) {
        $iisSiteName = [string]$config.IIS.SiteName
    }
    else {
        $iisSiteName = "Microsoft Dynamics 365 Business Central Web Client"
    }
    $iisRestart = $config.IIS.RestartAfterUpdate -ne $false

    # ----------------------------------------------------------
    # Step 1: Read ALL unique certificates from BC instances
    # ----------------------------------------------------------
    Write-Host "`n[1] Lettura certificati da Business Central..."
    $certGroups = Get-BCThumbprint
    if (-not $certGroups) {
        Write-Warning "Nessun certificato configurato in Business Central."
        Send-FailureNotification -Context "Lettura certificato BC" -ErrorDetail "Nessun thumbprint trovato nelle istanze BC."
        Invoke-Heartbeat -Status "Error" -Stage "ReadBCThumbprint" -Detail "Nessun thumbprint BC configurato" | Out-Null
        Exit-WithCode 1
    }

    $certGroups = @($certGroups)
    Write-Host ("Trovati {0} certificato/i distinto/i tra le istanze BC." -f $certGroups.Count)

    # ----------------------------------------------------------
    # Step 2: Check each certificate for expiry
    # ----------------------------------------------------------
    Write-Host "`n[2] Verifica scadenza certificati..."
    $expiringCerts = @()

    foreach ($group in $certGroups) {
        $certDetails = Get-CertDetails -Thumbprint $group.Thumbprint
        if (-not $certDetails) {
            Write-Warning ("Certificato {0} non trovato nello store (istanze: {1})." -f $group.Thumbprint, ($group.Instances -join ', '))
            Send-FailureNotification -Context "Dettagli certificato" -ErrorDetail ("Certificato {0} non trovato nello store. Istanze: {1}" -f $group.Thumbprint, ($group.Instances -join ', '))
            $hadPipelineErrors = $true
            continue
        }

        $daysLeft = [math]::Floor(($certDetails.NotAfter - (Get-Date)).TotalDays)
        $certAlreadyExpired = $daysLeft -lt 0
        if ($certAlreadyExpired) { $daysLeft = 0 }

        $instanceList = $group.Instances -join ', '
        if ($certAlreadyExpired) {
            Write-Warning ("  [{0}] {1} - GIA' SCADUTO (istanze: {2})" -f $group.Thumbprint, $certDetails.Subject, $instanceList)
        }
        else {
            Write-Host ("  [{0}] {1} - {2} giorni rimanenti (istanze: {3})" -f $group.Thumbprint, $certDetails.Subject, $daysLeft, $instanceList)
        }

        if ($daysLeft -le $expiryThreshold) {
            $expiringCerts += [PSCustomObject]@{
                Group       = $group
                CertDetails = $certDetails
                DaysLeft    = $daysLeft
                IsExpired   = $certAlreadyExpired
            }
        }
    }

    # ----------------------------------------------------------
    # Step 3: If no certificate is expiring, exit healthy
    # ----------------------------------------------------------
    if ($expiringCerts.Count -eq 0) {
        Write-Host "`nTutti i certificati sono validi. Nessuna azione necessaria."
        Invoke-Heartbeat -Status "Healthy" -Stage "NoActionNeeded" -Detail "Tutti i certificati validi" | Out-Null
        Exit-WithCode 0
    }

    Write-Host ("`n{0} certificato/i in scadenza." -f $expiringCerts.Count)

    # ----------------------------------------------------------
    # Steps 4-7: Renew each expiring certificate independently
    # ----------------------------------------------------------
    $passwordFile = Join-Path $pfxPath "password.txt"

    foreach ($expiring in $expiringCerts) {
        if($hadPipelineErrors){Write-Warning 'Pipeline interrotta dopo un errore precedente; nessun gruppo successivo verra aggiornato.';break}
        $oldThumb      = $expiring.Group.Thumbprint
        $certDetails   = $expiring.CertDetails
        $daysLeft      = $expiring.DaysLeft
        $certAlreadyExpired = $expiring.IsExpired
        $instanceList  = $expiring.Group.Instances -join ', '
        $expiryLabel   = if ($certAlreadyExpired) { "GIA' SCADUTO" } else { "in scadenza ($daysLeft giorni)" }

        Write-Host ("`n" + ("-" * 60))
        Write-Host ("Rinnovo: {0} [{1}]" -f $certDetails.Subject, $oldThumb)
        Write-Host ("Istanze BC interessate: {0}" -f $instanceList)
        Write-Host ("-" * 60)

        # ---- Step 4: Find PFX ----
        Write-Host "[4] Verifica PFX disponibile..."
        $pfxCandidates = @(Get-PfxCandidates -Path $pfxPath)

        # Case 1: No PFX found
        if ($pfxCandidates.Count -eq 0) {
            Write-Warning "Nessun file PFX trovato in $pfxPath"
            $null = Send-CustomerNotification -Title "CERTAMENT - Certificato in scadenza" `
                -Message ("Il certificato **$($certDetails.Subject)** e' **$expiryLabel**.`nCaricare un nuovo PFX sul server **$hostname** in: **$pfxPath**`nIncludere anche un file **password.txt** con la password del PFX nella stessa cartella.") `
                -ContextLabel "Certificato in scadenza - PFX mancante"
            Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxMissing" -Detail ("Nessun PFX trovato in $pfxPath per $oldThumb") | Out-Null
            $hadPipelineErrors = $true
            continue
        }

        # --- Resolve PFX password: password.txt > config fallback ---
        $pfxPasswordPlain = $null
        if (Test-Path $passwordFile) {
            $pfxPasswordPlain = (Get-Content -Path $passwordFile -Raw -ErrorAction Stop).Trim()
            Write-Host "Password letta da: $passwordFile"
        }
        elseif ($config.Pfx.Password -and $config.Pfx.Password.Trim() -ne "") {
            $pfxPasswordPlain = $config.Pfx.Password
            Write-Host "Password da config.json (fallback)"
        }

        if ([string]::IsNullOrWhiteSpace($pfxPasswordPlain)) {
            Write-Warning "Nessuna password PFX disponibile. Creare password.txt in $pfxPath"
            $null = Send-CustomerNotification -Title "CERTAMENT - Password PFX mancante" `
                -Message ("Il certificato **$($certDetails.Subject)** e' **$expiryLabel**.`nE' stato trovato un PFX ma manca la password.`nCreare il file **password.txt** in **$pfxPath** con la password del PFX.") `
                -ContextLabel "Certificato in scadenza - password PFX mancante"
            Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxNoPassword" -Detail "Nessuna password PFX disponibile" | Out-Null
            $hadPipelineErrors = $true
            continue
        }

        $pfxPassword = ConvertTo-SecureString $pfxPasswordPlain -AsPlainText -Force
        $endpointIdentity=Get-ConfiguredEndpointDnsNames -SiteName $iisSiteName -BindingInformation '*:443:'
        if($endpointIdentity.Conflict){throw 'Configurazione endpoint DNS incoerente: IIS.ExpectedDnsNames e HostHeader non coincidono.'}
        $expectedDnsNames=@($endpointIdentity.Names)
        Write-Host ("Identita' DNS endpoint configurata: {0}" -f ($(if($expectedDnsNames.Count -gt 0){$expectedDnsNames -join ', '}else{'nessuna'})))
        $selection=Select-PfxCandidate -Candidates $pfxCandidates -Password $pfxPassword -CurrentCertificate $certDetails -ExpectedDnsNames $expectedDnsNames
        $selected=$selection.Selected
        if($null -eq $selected){
            Write-Warning "Nessun PFX valido e pertinente trovato in $pfxPath"
            $null = Send-CustomerNotification -Title "CERTAMENT - Certificato in scadenza" `
                -Message ("Il certificato **$($certDetails.Subject)** e' **$expiryLabel** ma nessun PFX e' leggibile, piu' recente e pertinente.`nVerificare password, SAN, EKU Server Authentication e validita'.") `
                -ContextLabel "Certificato scaduto - PFX non valido"
            Invoke-Heartbeat -Status "AwaitingPfx" -Stage "PfxInvalid" -Detail "Nessun PFX valido e pertinente" | Out-Null
            $hadPipelineErrors = $true
            continue
        }
        $pfxFile=$selected.File.FullName;$pfxData=$selected.Data;$pfxExpiry=$selected.Certificate.NotAfter;$pfxThumb=$selected.Certificate.Thumbprint
        Write-Host ("PFX selezionato: {0} (NotAfter={1}, Thumbprint={2})" -f $pfxFile,$pfxExpiry,$pfxThumb)

        # ---- Step 5: Install PFX ----
        Write-Host "[5] Installazione nuovo certificato..."
        $installedCert = Install-PfxCert -PfxPath $pfxFile -Password $pfxPassword
        if (-not $installedCert -or $installedCert -eq $false) {
            Send-FailureNotification -Context "Installazione PFX" -ErrorDetail "Install-PfxCert ha restituito errore per $pfxFile"
            Invoke-Heartbeat -Status "Error" -Stage "InstallPfx" -Detail "Install-PfxCert fallita" | Out-Null
            $hadPipelineErrors = $true
            continue
        }

        $newThumb = $installedCert.Thumbprint
        Write-Host "Installato: $($installedCert.Subject) [$newThumb]"

        # ---- Snapshot SSL cert bindings BEFORE BC update (safety net) ----
        Write-Host "`nSnapshot SSL bindings (netsh http sslcert) per vecchio certificato..."
        $sslSnapshot = Get-SslCertBindingSnapshot -Thumbprint $oldThumb
        if ($sslSnapshot.Count -gt 0) {
            Write-Host ("  Snapshot acquisito: {0} SSL binding(s) per porta." -f $sslSnapshot.Count)
            $sslSnapshot | ForEach-Object { Write-Host ("    {0} -> {1}" -f $_.Endpoint, $_.CertHash) }
        }
        else {
            Write-Host "  Nessun SSL binding trovato per il vecchio certificato."
        }

        # ---- Snapshot URL ACL reservations BEFORE BC update (safety net) ----
        Write-Host "`nSnapshot URL ACL (netsh http urlacl) per istanze BC..."
        $urlAclSnapshot = Get-UrlAclSnapshot -InstanceNames $expiring.Group.Instances
        if ($urlAclSnapshot.Count -gt 0) {
            Write-Host ("  Snapshot acquisito: {0} URL ACL reservation(s)." -f $urlAclSnapshot.Count)
            $urlAclSnapshot | ForEach-Object { Write-Host ("    {0}" -f $_.Url) }
        }
        else {
            Write-Host "  Nessuna URL ACL trovata per le istanze BC."
        }

        # ---- Persist snapshots to disk (safety net for crash recovery) ----
        $snapshotPath=Save-BindingSnapshot -OldThumbprint $oldThumb -NewThumbprint $newThumb `
            -SslSnapshot $sslSnapshot -UrlAclSnapshot $urlAclSnapshot
        if([string]::IsNullOrWhiteSpace([string]$snapshotPath) -or -not (Test-Path -LiteralPath $snapshotPath)){
            throw "Snapshot persistence fallita prima dell'aggiornamento BC per $oldThumb"
        }

        # ---- Step 6: Update BC (only instances using the old certificate) ----
        Write-Host "[6] Aggiornamento istanze Business Central (vecchio thumb: $oldThumb)..."
        $bcResults = Update-BCServiceCert -NewThumbprint $newThumb -OldThumbprint $oldThumb
        if ($bcResults) { $bcResults | Format-Table -AutoSize }

        $bcErrors = @($bcResults | Where-Object { $_.Result -eq 'Error' })
        if ($bcErrors.Count -gt 0) {
            $errText = ($bcErrors | ForEach-Object { "$($_.Instance): $($_.ErrorMessage)" }) -join "; "
            Send-FailureNotification -Context "Aggiornamento BC" -ErrorDetail $errText
            $hadPipelineErrors = $true
        }

        # --- Post-BC verification with auto-remediation ---
        Write-Host "`nVerifica post-aggiornamento BC (attesa avvio servizi)..."
        Start-Sleep -Seconds (Get-TestSleepSeconds 15)
        $bcVerifyErrors = Test-BCPostUpdate -ExpectedThumbprint $newThumb -OldThumbprint $oldThumb
        if ($bcVerifyErrors) {
            Write-Warning "Verifica BC fallita: $($bcVerifyErrors -join '; ')"
            Write-Host "Retry aggiornamento BC..."
            $bcRetry = Update-BCServiceCert -NewThumbprint $newThumb -OldThumbprint $oldThumb
            if ($bcRetry) { $bcRetry | Format-Table -AutoSize }
            Start-Sleep -Seconds (Get-TestSleepSeconds 15)
            $bcVerifyErrors2 = Test-BCPostUpdate -ExpectedThumbprint $newThumb -OldThumbprint $oldThumb
            if ($bcVerifyErrors2) {
                $errDetail = $bcVerifyErrors2 -join "; "
                Send-FailureNotification -Context "Verifica post-aggiornamento BC" -ErrorDetail "Fallita anche dopo retry: $errDetail"
                $hadPipelineErrors = $true
            }
            else {
                Write-Host "Remediation BC riuscita dopo retry."
            }
        }
        else {
            Write-Host "Verifica BC OK: thumbprint e stato Running confermati."
        }

        if($hadPipelineErrors){
            Write-Warning 'Errore BC: pipeline interrotta prima di SSL, URLACL, IIS, notifiche e archivio.'
            continue
        }

        # --- Post-BC SSL binding verification + repair ---
        if ($sslSnapshot.Count -gt 0) {
            Write-Host "`nVerifica SSL bindings per porta (netsh http sslcert)..."
            $sslErrors = Test-SslCertBindings -ExpectedThumbprint $newThumb -Snapshot $sslSnapshot
            if ($sslErrors -and $sslErrors.Count -gt 0) {
                Write-Warning "SSL bindings non corretti: $($sslErrors -join '; ')"
                Write-Host "Tentativo repair SSL bindings da snapshot..."
                $sslRepairResults = Repair-SslCertBindings -Snapshot $sslSnapshot -NewThumbprint $newThumb
                if ($sslRepairResults) { $sslRepairResults | Format-Table -AutoSize }

                $sslRepairErrors = @($sslRepairResults | Where-Object { $_.Action -eq 'Error' })
                $sslRepairFixed = @($sslRepairResults | Where-Object { $_.Action -in @('Fixed', 'Recreated', 'ForceFixed', 'ForceRecreated') })

                if ($sslRepairFixed.Count -gt 0) {
                    Write-Host "SSL Repair: corretti/ricreati $($sslRepairFixed.Count) binding."
                    # Re-verify after repair
                    $sslErrors2 = Test-SslCertBindings -ExpectedThumbprint $newThumb -Snapshot $sslSnapshot
                    if ($sslErrors2 -and $sslErrors2.Count -gt 0) {
                        $errDetail = $sslErrors2 -join "; "
                        Send-FailureNotification -Context "Verifica SSL bindings porta" -ErrorDetail "Fallita anche dopo repair: $errDetail"
                        $hadPipelineErrors = $true
                    }
                    else {
                        Write-Host "SSL bindings porta verificati dopo repair."
                    }
                }
                elseif ($sslRepairErrors.Count -gt 0) {
                    $errDetail = ($sslErrors + ($sslRepairErrors | ForEach-Object { $_.Detail })) -join "; "
                    Send-FailureNotification -Context "Verifica SSL bindings porta" -ErrorDetail "Repair fallito: $errDetail"
                    $hadPipelineErrors = $true
                }
            }
            else {
                Write-Host "Verifica SSL bindings porta: tutti corretti."
            }
        }

        # --- Post-BC URL ACL verification + repair ---
        if ($urlAclSnapshot.Count -gt 0) {
            Write-Host "`nVerifica URL ACL reservations (netsh http urlacl)..."
            $urlAclErrors = Test-UrlAcls -Snapshot $urlAclSnapshot
            if ($urlAclErrors -and $urlAclErrors.Count -gt 0) {
                Write-Warning "URL ACL mancanti: $($urlAclErrors -join '; ')"
                Write-Host "Tentativo repair URL ACL da snapshot..."
                $urlAclRepairResults = Repair-UrlAcls -Snapshot $urlAclSnapshot
                if ($urlAclRepairResults) { $urlAclRepairResults | Format-Table -AutoSize }

                $urlAclRepairErrors = @($urlAclRepairResults | Where-Object { $_.Action -eq 'Error' })
                if ($urlAclRepairErrors.Count -gt 0) {
                    $errDetail = ($urlAclErrors + ($urlAclRepairErrors | ForEach-Object { $_.Detail })) -join "; "
                    Send-FailureNotification -Context "Verifica URL ACL" -ErrorDetail "Repair fallito: $errDetail"
                    $hadPipelineErrors = $true
                }
                else {
                    # Re-verify
                    $urlAclErrors2 = Test-UrlAcls -Snapshot $urlAclSnapshot
                    if ($urlAclErrors2 -and $urlAclErrors2.Count -gt 0) {
                        Send-FailureNotification -Context "Verifica URL ACL" -ErrorDetail "Fallita anche dopo repair: $($urlAclErrors2 -join '; ')"
                        $hadPipelineErrors = $true
                    }
                    else {
                        Write-Host "URL ACL verificate dopo repair."
                    }
                }
            }
            else {
                Write-Host "Verifica URL ACL: tutte presenti."
            }

            if($hadPipelineErrors){
                Write-Warning 'Errore SSL/URLACL: pipeline interrotta prima di IIS, notifiche e archivio.'
                continue
            }
        }

        # ---- Step 7: Update IIS (only bindings using the old certificate) ----
        Write-Host "`n[7] Aggiornamento binding IIS (vecchio thumb: $oldThumb)..."

        # Snapshot HTTPS bindings BEFORE update (safety net for repair)
        $iisSnapshot = Get-IISBindingSnapshot -SiteName $iisSiteName -Thumbprint $oldThumb
        if ($iisSnapshot.Count -gt 0) {
            Write-Host ("  Snapshot acquisito: {0} binding HTTPS." -f $iisSnapshot.Count)
        }
        else {
            Write-Warning "  Nessun binding HTTPS trovato per lo snapshot."
        }

        # Update persisted snapshot with IIS data
        $snapshotPath=Save-BindingSnapshot -OldThumbprint $oldThumb -NewThumbprint $newThumb `
            -SslSnapshot $sslSnapshot -UrlAclSnapshot $urlAclSnapshot -IISSnapshot $iisSnapshot
        if([string]::IsNullOrWhiteSpace([string]$snapshotPath) -or -not (Test-Path -LiteralPath $snapshotPath)){
            throw "Snapshot persistence IIS fallita per $oldThumb"
        }

        try {
            $iisResults = Update-IISBinding -NewThumbprint $newThumb -OldThumbprint $oldThumb -SiteName $iisSiteName -RestartIIS:$iisRestart
            if ($iisResults) { $iisResults | Format-Table -AutoSize }
        }
        catch {
            Send-FailureNotification -Context "Aggiornamento IIS" -ErrorDetail $_.Exception.Message
            $hadPipelineErrors = $true
        }

        # --- Post-IIS verification with auto-remediation ---
        Write-Host "`nVerifica post-aggiornamento IIS..."
        $iisVerifyErrors = Test-IISPostUpdate -ExpectedThumbprint $newThumb -SiteName $iisSiteName -BindingSnapshot $iisSnapshot
        if ($iisVerifyErrors) {
            Write-Warning "Verifica IIS fallita: $($iisVerifyErrors -join '; ')"
            Write-Host "Retry aggiornamento IIS scoped al vecchio thumbprint..."
            try {
                $iisRetry = Update-IISBinding -NewThumbprint $newThumb -OldThumbprint $oldThumb -SiteName $iisSiteName -RestartIIS:$iisRestart
                if ($iisRetry) { $iisRetry | Format-Table -AutoSize }
            }
            catch {
                Write-Warning "Retry IIS fallito: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds (Get-TestSleepSeconds 10)
            $iisVerifyErrors2 = Test-IISPostUpdate -ExpectedThumbprint $newThumb -SiteName $iisSiteName -BindingSnapshot $iisSnapshot
            if ($iisVerifyErrors2) {
                # Last resort: repair from snapshot (recreates missing bindings)
                Write-Host "Tentativo repair binding IIS da snapshot..."
                $repairResults = Repair-IISBindings -Snapshot $iisSnapshot -NewThumbprint $newThumb -SiteName $iisSiteName
                if ($repairResults) { $repairResults | Format-Table -AutoSize }

                $repairErrors = @($repairResults | Where-Object { $_.Action -eq 'Error' })
                $repairSuccess = @($repairResults | Where-Object { $_.Action -in @('Fixed', 'Recreated', 'ForceRecreated') })

                if ($repairSuccess.Count -gt 0) {
                    Write-Host "Repair IIS: corretti/ricreati $($repairSuccess.Count) binding."
                    Start-Sleep -Seconds (Get-TestSleepSeconds 5)

                    # Final verification after repair
                    $iisVerifyErrors3 = Test-IISPostUpdate -ExpectedThumbprint $newThumb -SiteName $iisSiteName -BindingSnapshot $iisSnapshot
                    if ($iisVerifyErrors3) {
                        $errDetail = $iisVerifyErrors3 -join "; "
                        Send-FailureNotification -Context "Verifica post-aggiornamento IIS" -ErrorDetail "Fallita anche dopo repair da snapshot: $errDetail"
                        $hadPipelineErrors = $true
                    }
                    else {
                        Write-Host "Repair IIS riuscito: tutti i binding verificati."
                    }
                }
                else {
                    $errDetail = ($iisVerifyErrors2 + ($repairErrors | ForEach-Object { $_.Detail })) -join "; "
                    Send-FailureNotification -Context "Verifica post-aggiornamento IIS" -ErrorDetail "Fallita anche dopo retry e repair: $errDetail"
                    $hadPipelineErrors = $true
                }
            }
            else {
                Write-Host "Remediation IIS riuscita dopo retry."
            }
        }
        else {
            Write-Host "Verifica IIS OK: binding aggiornati correttamente."
        }

        # Per-cert completion notification
        $certStatusLabel = if ($hadPipelineErrors) { "con warning" } else { "con successo" }
        $certNotifTitle  = if ($hadPipelineErrors) { "CERTAMENT - Certificato aggiornato (con warning)" } else { "CERTAMENT - Certificato aggiornato" }

        $bcUpdated  = @($bcResults | Where-Object { $_.Result -eq 'UpdatedAndRestarted' } | ForEach-Object { $_.Instance })
        $bcSkipped  = @($bcResults | Where-Object { $_.Result -eq 'Skipped' }             | ForEach-Object { $_.Instance })
        $iisUpdated = @($iisResults | Where-Object { $_.Result -eq 'Updated' }            | ForEach-Object { $_.Binding })

        $certMsg = @"
Nuovo certificato installato $certStatusLabel su server **$hostname**.

**Cliente:** $(Get-CustomerLabel)
**Dettagli:**
- Soggetto: $($installedCert.Subject)
- Thumbprint: $newThumb
- Scadenza: $($installedCert.NotAfter)
- Istanze BC aggiornate: $(if ($bcUpdated) { $bcUpdated -join ', ' } else { 'nessuna' })$(if ($bcSkipped) { "`n- Istanze BC saltate (certificato diverso): $($bcSkipped -join ', ')" })
- Binding IIS aggiornati: $(if ($iisUpdated) { $iisUpdated -join ', ' } else { 'nessuno' })
"@
        if ($hadPipelineErrors) {
            $certMsg += "`n`n**Attenzione:** si sono verificati errori durante la pipeline. Verificare i log."
        }
        $null = Send-InternalNotification -Title $certNotifTitle -Message $certMsg

        # Archive only after the complete group pipeline has succeeded.
        if(-not $hadPipelineErrors){
            $installedDir = Join-Path $pfxPath "installed"
            if (-not (Test-Path $installedDir)) { New-Item -ItemType Directory -Path $installedDir -Force | Out-Null }
            try {
                Move-Item -Path $pfxFile -Destination $installedDir -Force
                Write-Host "PFX archiviato in: $installedDir"
            }
            catch {
                Write-Warning "Impossibile archiviare PFX: $($_.Exception.Message)"
                $hadPipelineErrors=$true
            }
        }
    }

    # --- Cleanup: delete password.txt after all renewals ---
    if (-not $hadPipelineErrors -and (Test-Path $passwordFile)) {
        Remove-Item -Path $passwordFile -Force -ErrorAction SilentlyContinue
        Write-Host "File password.txt eliminato."
    }

    if ($hadPipelineErrors) {
        Invoke-Heartbeat -Status "CompletedWithWarnings" -Stage "MainEnd" -Detail "Pipeline completata con warning/errori parziali" | Out-Null
    }
    else {
        Invoke-Heartbeat -Status "Completed" -Stage "MainEnd" -Detail "Pipeline completata con successo" | Out-Null
    }
    if ($hadPipelineErrors) {
        Write-Warning "CERTAMENT completato con warning/errori. Verificare i log."
        Exit-WithCode 1
    }
    Write-Host "`nCERTAMENT completato con successo."
}

try {
    Main
}
catch {
    Write-Error "Errore critico CERTAMENT: $($_.Exception.Message)"
    try { Invoke-Heartbeat -Status "Error" -Stage "UnhandledException" -Detail $_.Exception.Message | Out-Null } catch {}
    try { Send-FailureNotification -Context "Errore critico" -ErrorDetail $_.Exception.Message } catch {}
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
    try { if ($script:mutex) { $script:mutex.ReleaseMutex(); $script:mutex.Dispose() } } catch {}
}
