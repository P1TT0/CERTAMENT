# CERTAMENT – Cert rotation helper

## What it does
- Reads `config.json`, picks the newest `.pfx` in `Pfx.Path`, compares with the cert used by Business Central services.
- Installs the newer PFX into `Cert:\LocalMachine\My` and switches BC server instances and IIS bindings to the new thumbprint.
- Optionally restarts IIS and posts a webhook notification.

## Usage
Run from an elevated PowerShell 5.1 session:

```powershell
# Dry run
./_MAINCertManager.ps1 -WhatIf

# Apply with defaults
./_MAINCertManager.ps1

# Skip IIS reset or notifications if needed
./_MAINCertManager.ps1 -SkipIisReset -SkipNotifications
```

### Password handling
- Preferred: set env var `CERTAMENT_PFX_PASSWORD` before running.
- Fallbacks: `config.json` `Pfx.Password` (plaintext, not recommended) or interactive prompt.

### Notifications
- Webhook notifications use the `Notifications.EnableWebhook` flag and URLs in `config.json`. Target used: `Internal`.

### Config fields (snippet)
```json
{
  "Pfx": {
    "Path": "C:\\_install",
    "Password": "",
    "AutoSelectLatest": true
  },
  "BusinessCentral": { "UseLatestModule": true },
  "Notifications": { "EnableWebhook": true }
}
```

## Notes
- Script elevates itself if not already running as Administrator.
- Uses `Get-NAVServerInstance` and assumes IIS site `Microsoft Dynamics 365 Business Central Web Client`.
- Add `-Verbose` to see debug logs.
