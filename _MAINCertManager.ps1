
param(
    [string]$ConfigPath = "$PSScriptRoot\config.json",
    [switch]$SkipIisReset,
    [switch]$SkipNotifications,
    [switch]$WhatIf
)

function Write-Log {
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]$Level = 'INFO',
        [string]$Message
    )

    $prefix = "[$Level]"
    switch ($Level) {
        'INFO'  { Write-Host "$prefix $Message" }
        'WARN'  { Write-Warning "$Message" }
        'ERROR' { Write-Error "$Message" }
        'DEBUG' { Write-Verbose "$Message" }
    }
}

function Assert-Admin {
    $isAdmin = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { return }

    Write-Log -Level WARN -Message "Lo script richiede privilegi amministrativi. Rilancio come Admin..."
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($ConfigPath) { $args += " -ConfigPath `"$ConfigPath`"" }
    if ($SkipIisReset) { $args += " -SkipIisReset" }
    if ($SkipNotifications) { $args += " -SkipNotifications" }
    if ($WhatIf) { $args += " -WhatIf" }
    Start-Process powershell $args -Verb RunAs
    exit
}

function Load-Config {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "File di configurazione non trovato: $Path"
    }
    try {
        return Get-Content -Raw -Path $Path | ConvertFrom-Json
    } catch {
        throw "Impossibile leggere o analizzare il JSON di configurazione: $($_.Exception.Message)"
    }
}

function Ensure-BcModule {
    param([bool]$UseLatest)

    if (-not $UseLatest -and (Get-Command -Name Get-NAVServerInstance -ErrorAction SilentlyContinue)) {
        return
    }

    $bcModulePaths = Get-ChildItem -Path "C:\Program Files\Microsoft Dynamics 365 Business Central" -Recurse -Filter "Microsoft.Dynamics.Nav.Management.psm1" -ErrorAction SilentlyContinue
    if (-not $bcModulePaths) {
        throw "Nessun modulo Business Central trovato."
    }

    $bcModulePath = $bcModulePaths | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    Import-Module $bcModulePath -Force | Out-Null
    Write-Log -Message "Modulo BC importato da: $bcModulePath"
}

function Resolve-PfxPassword {
    param($Config)

    if ($Config.Pfx.Password) {
        return ConvertTo-SecureString $Config.Pfx.Password -AsPlainText -Force
    }

    $envPassword = $env:CERTAMENT_PFX_PASSWORD
    if ($envPassword) {
        return ConvertTo-SecureString $envPassword -AsPlainText -Force
    }

    $prompt = Read-Host -AsSecureString "Password PFX (non salvata)"
    return $prompt
}

function Invoke-Certament {
    Assert-Admin

    $config = Load-Config -Path $ConfigPath
    Ensure-BcModule -UseLatest $config.BusinessCentral.UseLatestModule

    Import-Module "$PSScriptRoot\Get-BCThumbprint.psm1" -Force
    Import-Module "$PSScriptRoot\Get-CertDetails.psm1" -Force
    Import-Module "$PSScriptRoot\Get-PfxFile.psm1" -Force
    Import-Module "$PSScriptRoot\Get-PfxDetails.psm1" -Force
    Import-Module "$PSScriptRoot\Install-PfxCert.psm1" -Force
    Import-Module "$PSScriptRoot\Update-BCServiceCert.psm1" -Force
    Import-Module "$PSScriptRoot\Update-IISBinding.psm1" -Force
    Import-Module "$PSScriptRoot\Test-BCWebServices.psm1" -Force
    Import-Module "$PSScriptRoot\Send-Notification.psm1" -Force

    Write-Log -Message "Avvio CERTAMENT"

    $currentThumb = Get-BcThumbprint
    $currentCert  = $null
    if ($currentThumb) {
        $currentCert = $currentThumb | Get-CertDetails
        Write-Log -Message "Certificato attuale BC: $($currentCert.Thumbprint) (scade $($currentCert.NotAfter))"
    } else {
        Write-Log -Level WARN -Message "Nessun certificato configurato nelle istanze BC."
    }

    $pfxPath = Get-PfxFile -Path $config.Pfx.Path
    if (-not $pfxPath) {
        Write-Log -Level WARN -Message "Nessun file .pfx trovato in $($config.Pfx.Path)"
        return
    }

    $pfxPassword = Resolve-PfxPassword -Config $config

    try {
        $pfxData = Get-PfxData -FilePath $pfxPath -Password $pfxPassword -ErrorAction Stop
    } catch {
        Write-Log -Level ERROR -Message "Errore nella lettura del PFX: $($_.Exception.Message)"
        return
    }

    $pfxCert = $pfxData.EndEntityCertificates
    Write-Log -Message "PFX selezionato: $pfxPath (scade $($pfxCert.NotAfter))"

    $shouldInstall = $false
    if ($currentCert) {
        if ($pfxCert.Thumbprint -eq $currentCert.Thumbprint) {
            Write-Log -Message "Il PFX contiene lo stesso certificato già installato."
        } elseif ($pfxCert.NotAfter -gt $currentCert.NotAfter) {
            Write-Log -Message "Il PFX è più recente del certificato corrente. Procedo all'installazione."
            $shouldInstall = $true
        } else {
            Write-Log -Level WARN -Message "Il PFX non è più recente del certificato attuale."
        }
    } else {
        Write-Log -Message "Nessun certificato attuale: installazione necessaria."
        $shouldInstall = $true
    }

    if (-not $shouldInstall) { return }

    if ($WhatIf) {
        Write-Log -Message "WhatIf attivo: nessuna modifica eseguita."
        return
    }

    Write-Log -Message "Installazione nuovo certificato..."
    $installedCert = Install-PfxCert -PfxPath $pfxPath -Password $pfxPassword
    if (-not $installedCert) {
        Write-Log -Level ERROR -Message "Installazione certificato fallita."
        return
    }

    Write-Log -Message "Aggiornamento istanze Business Central..."
    $bcResults = Update-BCServiceCert -NewThumbprint $installedCert.Thumbprint
    if ($bcResults) { $bcResults | Format-Table -AutoSize }

    Write-Log -Message "Aggiornamento binding IIS..."
    $iisResults = Update-IISBinding -NewThumbprint $installedCert.Thumbprint -RestartIIS:(!$SkipIisReset)
    if ($iisResults) { $iisResults | Format-Table -AutoSize }

    if (-not $SkipNotifications -and $config.Notifications.EnableWebhook) {
        $msg = "Certificato aggiornato con successo. Thumbprint: $($installedCert.Thumbprint). Scadenza: $($installedCert.NotAfter)."
        Send-Notification -Title "CERTAMENT" -Message $msg -Target "Internal" -ConfigPath $ConfigPath
    }

    Write-Log -Message "Completato."
}

Invoke-Certament
