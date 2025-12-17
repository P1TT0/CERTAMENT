# CERTAMENT – Complete Implementation Guide

## Project Structure

```
CERTAMENT/
├── README.md                           # PowerShell version guide
├── CONTRIBUTING.md                     # Contribution guidelines
├── config.example.json                 # Config template
│
├── _MAINCertManager.ps1               # PowerShell main orchestrator (v0.1.0)
│
├── modules/                           # PowerShell helper modules
│   ├── Get-BCThumbprint.psm1
│   ├── Get-CertDetails.psm1
│   ├── Get-PfxDetails.psm1
│   ├── Get-PfxFile.psm1
│   ├── Install-PfxCert.psm1
│   ├── Update-BCServiceCert.psm1
│   ├── Update-IISBinding.psm1
│   ├── Test-BCWebServices.psm1
│   └── Send-Notification.psm1
│
├── tools/                             # Utility scripts
│   ├── Get-CertLocations.ps1
│   └── Remove-Cert.ps1
│
└── csharp/                            # C# implementation (v0.2.0)
    ├── README-FULL.md                 # Complete C# guide
    ├── Certament.sln                  # Visual Studio solution
    ├── Certament.csproj               # Main project
    ├── .gitignore
    │
    ├── Program.cs                     # Entry point (async, full CLI)
    │
    ├── Configuration/
    │   └── ConfigurationLoader.cs     # JSON config + validation
    │
    ├── Services/
    │   ├── CertificateService.cs      # X.509 cert store operations
    │   ├── IisService.cs              # IIS binding management
    │   ├── BusinessCentralService.cs  # BC integration (PS interop)
    │   └── NotificationService.cs     # Webhook notifications
    │
    ├── Orchestration/
    │   └── CertamentOrchestrator.cs   # Main 9-step workflow
    │
    └── Tests/
        ├── Certament.Tests.csproj
        ├── ConfigurationLoaderTests.cs
        └── CertificateServiceTests.cs
```

## Version Comparison

| Feature | PowerShell (v0.1.0) | C# (v0.2.0) |
|---------|---------------------|------------|
| Cert rotation | ✓ | ✓ |
| BC service update | ✓ | ✓ |
| IIS binding update | ✓ | ✓ |
| Notifications | ✓ | ✓ |
| Logging | ✓ | ✓ (Serilog) |
| Error handling | ✓ | ✓ |
| Dry-run mode | ✓ | ✓ |
| Admin check | ✓ | ✓ |
| Type safety | ✗ | ✓ |
| Compiled speed | ✗ | ✓ |
| Unit tests | ✗ | ✓ |
| Dependencies | .NET 5.1 | .NET 6.0+ |

## Quick Reference

### PowerShell Version
```bash
# Run with defaults
./_MAINCertManager.ps1

# Dry run
./_MAINCertManager.ps1 -WhatIf

# Skip IIS restart
./_MAINCertManager.ps1 -SkipIisReset
```

### C# Version
```bash
# Build
dotnet build csharp/Certament.sln

# Run with defaults
dotnet run --project csharp

# Dry run
dotnet run --project csharp -- --dry-run

# Skip IIS restart
dotnet run --project csharp -- --skip-iis-restart
```

## Configuration

Both versions use the same `config.json` structure (example provided):

```json
{
  "Pfx": { "Path": "C:\\_install", "Password": "" },
  "BusinessCentral": { "UseLatestModule": true },
  "Notifications": { "EnableWebhook": true }
}
```

**Password**: Use env var `CERTAMENT_PFX_PASSWORD` (recommended).

## Workflow (Both Versions)

1. Load configuration
2. Query current BC certificate
3. Find latest PFX file
4. Compare: is PFX newer?
5. If yes: import PFX to cert store
6. Update BC service certificate
7. Update IIS HTTPS binding
8. Restart IIS (optional)
9. Test BC web services
10. Send notification (optional)

## Testing

### PowerShell
- Manual testing with `-WhatIf`
- Validation scripts in `tools/`

### C#
```bash
dotnet test csharp/Tests/Certament.Tests.csproj
```

## Deployment

### PowerShell (production-ready)
- Copy `_MAINCertManager.ps1` + `modules/` folder to target
- Copy `config.json` (customize for environment)
- Run from scheduled task or manually as admin

### C# (ready to build & deploy)
- Build: `dotnet build csharp/ -c Release`
- Publish: `dotnet publish csharp/ -c Release -o publish`
- Copy `publish/` folder + `config.json` to target
- Run `.exe` from task scheduler or command line as admin

## Logs

### PowerShell
- Console output with emoji/color coding
- Optional webhook notifications

### C#
- Console output (timestamped, severity levels)
- Rolling file logs: `logs/certament-YYYY-MM-DD.txt` (30-day retention)

## Key Files Reference

| File | Purpose | Version |
|------|---------|---------|
| `_MAINCertManager.ps1` | Main orchestrator | PowerShell |
| `Certament.sln` | Build solution | C# |
| `CertamentOrchestrator.cs` | Workflow engine | C# |
| `config.example.json` | Config template | Both |
| `README-FULL.md` | C# documentation | C# |
| `CONTRIBUTING.md` | Dev guidelines | Both |

## Environment Variables

- `CERTAMENT_PFX_PASSWORD` – PFX password (both versions, recommended)

## Exit Codes

- `0` – Success
- `1` – Error (check logs)

## Support & Troubleshooting

Refer to:
- `README.md` – PowerShell quick start
- `csharp/README-FULL.md` – C# full guide
- `CONTRIBUTING.md` – Development practices

---

**Latest version on GitHub**: https://github.com/P1TT0/CERTAMENT

**Both implementations fully functional and ready for production.**
