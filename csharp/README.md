# CERTAMENT – C# Version

Early-stage C# rewrite of the PowerShell certificate rotation tool.

## Goals
- Type-safe, compiled implementation.
- Better performance and maintainability.
- Easier unit testing and dependency injection.
- Potential for GUI/web admin interface in future.

## Build & Run

### Prerequisites
- .NET 6.0 SDK or later
- Windows 10+ or Windows Server 2016+
- Administrator privileges

### Build
```bash
dotnet build
```

### Run
```bash
dotnet run -- [options]
```

### Options
- `--no-iis-restart` – Skip IIS restart after certificate update.

## Configuration
Copy `config.example.json` to `config.json` and customize paths/webhook URLs.

Set `CERTAMENT_PFX_PASSWORD` environment variable (recommended) or store password in config.json (not recommended).

## Structure
- `Program.cs` – Entry point, orchestration.
- `Services/CertificateService.cs` – Cert store management.
- `Services/IisService.cs` – IIS binding updates.
- `Configuration/ConfigurationLoader.cs` – Config parsing.

## Status
⚠️ **Early development** – core functionality implemented, BC integration and tests pending.
