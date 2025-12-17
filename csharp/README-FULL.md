# CERTAMENT – C# Implementation

Full-featured C# rewrite of the PowerShell certificate rotation tool for Dynamics 365 Business Central and IIS.

## Features

✅ **Complete Workflow**
- Automatic PFX file detection (newest by timestamp)
- Certificate comparison and update logic
- Business Central service certificate update (via PowerShell interop)
- IIS HTTPS binding certificate update
- Automatic IIS restart
- Web services connectivity testing

✅ **BC Integration**
- Query BC server instances and current certificates
- Update `ServicesCertificateThumbprint` configuration
- Restart BC service instances
- Test OData/SOAP endpoint connectivity

✅ **Notifications**
- Webhook support (Power Automate, Teams, custom)
- Certificate update notifications
- Expiry warnings
- Error reporting

✅ **Security**
- Administrator privilege enforcement
- Environment variable for PFX password (recommended)
- Config file password support (not recommended)
- Secure string handling

✅ **Operational**
- Structured logging (Serilog) with rolling file appender
- Dry-run mode (`--dry-run`)
- Skip IIS restart (`--skip-iis-restart`)
- Command-line argument parsing
- Comprehensive error handling

## Prerequisites

- **OS**: Windows 10+ or Windows Server 2016+
- **.NET**: 6.0 SDK or later
- **Admin**: Script must run as Administrator
- **IIS**: Management Tools (Microsoft.Web.Administration)
- **BC**: Management PowerShell module (optional, for BC integration)

## Quick Start

### Build

```bash
dotnet build csharp/Certament.sln -c Release
```

### Run

```bash
cd csharp
dotnet run -- [options]
```

### Options

```
--dry-run              Simulate workflow without making changes
--skip-iis-restart     Do not restart IIS after certificate update
--skip-notifications   Do not send webhook notifications
```

### Example

```bash
# Dry run to see what would happen
dotnet run -- --dry-run

# Full execution
dotnet run

# Skip IIS restart
dotnet run -- --skip-iis-restart
```

## Configuration

Copy `config.example.json` to `config.json` in the same directory as the executable.

```json
{
  "Pfx": {
    "Path": "C:\\_install",         // Directory containing .pfx files
    "Password": "",                 // Leave empty; use env var CERTAMENT_PFX_PASSWORD
    "AutoSelectLatest": true        // Always pick newest PFX by date
  },
  "BusinessCentral": {
    "UseLatestModule": true,        // Auto-detect latest BC module
    "IisBindingSite": "Microsoft Dynamics 365 Business Central Web Client"
  },
  "Notifications": {
    "EnableWebhook": true,
    "Webhooks": {
      "Internal": "https://your-webhook-url"  // Power Automate, Teams, etc.
    }
  }
}
```

### Password Management

**Recommended**: Set environment variable before running:

```powershell
$env:CERTAMENT_PFX_PASSWORD = "your-pfx-password"
dotnet run
```

**Fallback**: Store plaintext in `config.json` (not recommended for production).

## Logging

Logs are written to:
- **Console**: Real-time output with timestamps and severity
- **Files**: `logs/certament-YYYY-MM-DD.txt` (rolling daily, last 30 days retained)

## Architecture

```
Services/
  ├── CertificateService.cs        – X.509 cert store queries, PFX import
  ├── IisService.cs                – IIS binding management, restart
  ├── BusinessCentralService.cs    – BC instance/config queries
  └── NotificationService.cs       – Webhook notifications

Configuration/
  └── ConfigurationLoader.cs       – JSON config parsing, validation

Orchestration/
  └── CertamentOrchestrator.cs     – Main workflow engine

Tests/
  ├── ConfigurationLoaderTests.cs  – Config loading, password resolution
  └── CertificateServiceTests.cs   – Certificate operations
```

## Workflow

1. **Load config** from `config.json`
2. **Query BC** for current certificate thumbprint
3. **Find latest PFX** in configured directory
4. **Import PFX** into `LocalMachine\My` store
5. **Compare certs** – update if PFX is newer
6. **Update BC** service certificate configuration
7. **Update IIS** HTTPS binding with new thumbprint
8. **Restart IIS** (unless `--skip-iis-restart`)
9. **Test BC web services** (OData/SOAP connectivity)
10. **Send notification** via webhook
11. **Log completion** with summary

## Running Tests

```bash
dotnet test csharp/Tests/Certament.Tests.csproj
```

## Troubleshooting

### "CERTAMENT requires administrator privileges"
- Run PowerShell as Administrator
- Or use `dotnet run` in an admin-elevated terminal

### "Failed to load configuration from config.json"
- Verify `config.json` exists and is valid JSON
- Check file permissions

### "No PFX file found"
- Verify PFX path in config.json exists
- Ensure `.pfx` files are present
- Check file permissions

### "Failed to update BC service certificate"
- Verify BC Management module is installed
- Check BC instance names
- Run as Administrator

### "Failed to update IIS binding"
- Verify IIS is installed and running
- Check site name matches configuration
- Confirm HTTPS bindings exist

## Future Enhancements

- [ ] GUI/web dashboard
- [ ] Scheduled execution (Windows Task Scheduler integration)
- [ ] Email notifications (SMTP)
- [ ] Certificate expiry tracking and warnings
- [ ] Multi-tenancy support
- [ ] Audit logging to database
- [ ] REST API for remote management

## License

Internal tool – no license currently assigned.

## Support

For issues or questions, contact your IT administrator.
