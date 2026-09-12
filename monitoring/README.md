# CERTAMENT Monitoring MVP

Azure Functions PowerShell API with Azure Table Storage, for centralized heartbeat/status
ingest from CERTAMENT installations.

## Status

- **Verified locally**: PowerShell Functions host + Azurite, end-to-end (see "Local E2E test
  results" below). Pester suite `tests/Monitoring.Tests.ps1` is 13/13 PASS.
- **NOT verified**: a real Azure tenant (Storage Account, Function App, networking, auth in a
  deployed environment). This is **not** "Azure production ready" — it is a local MVP backend
  only. Deployment, CI and dashboard integration are separate, not-yet-completed blocks.

## Architecture (local)

```
CERTAMENT runtime (_MAINCertManager.ps1)
   |  POST /api/heartbeat  (x-certament-token header)
   v
Azure Functions host (func start, PowerShell worker)
   |  Heartbeat / Servers / History / Health functions
   v
Azure Table Storage API (Az.Storage + AzTable modules)
   v
Azurite (local Storage emulator, UseDevelopmentStorage=true)
```

No Azure resources are involved in the local flow above. `monitoring/shared/` holds the
functions' shared logic:

- `model.ps1` - heartbeat field/status contract (required/optional fields, statuses, freshness thresholds).
- `keys.ps1` - Table Storage PartitionKey/RowKey derivation.
- `validation.ps1` - request auth, payload validation, response helper, freshness classification.
- `Storage.ps1` - table handle + Latest/History row persistence, dot-sources the three files above.

## Application settings

- `AzureWebJobsStorage`: Azure Storage connection string (`UseDevelopmentStorage=true` for Azurite).
- `CERTAMENT_HEARTBEAT_TOKEN`: secret expected in `x-certament-token`.
- `CERTAMENT_LATEST_TABLE`: defaults to `CertamentLatest`.
- `CERTAMENT_HISTORY_TABLE`: defaults to `CertamentHistory`.

The token is never returned by the API and is not used by the dashboard.

## InstallationId

Every heartbeat requires an `InstallationId`: a persistent, non-secret identifier for a
CERTAMENT installation, used to partition Latest/History rows in Table Storage.

- Generated once by `Install-Certament.ps1` (or by the runtime on first run if missing) via
  `[guid]::NewGuid()`, and persisted in `config.json` under `Context.InstallationId`.
- The runtime (`_MAINCertManager.ps1`) reads it from `config.json` at every run through
  `modules/InstallationIdentity.psm1` (`Get-OrCreateInstallationId`) and includes it unchanged
  in every heartbeat payload.
- It is **not** derived from `Customer + Server` and is never regenerated once set.

## Heartbeat contract

Required fields: `schemaVersion`, `tool` (must be `"CERTAMENT"`), `version`, `runId`,
`customer`, `server`, `status`, `stage`, `timestampUtc`, `InstallationId`.

Optional fields: `detail`, `durationSec`, `certificateDaysRemaining`, `notificationStatus`.

Valid `status` values: `Started`, `Healthy`, `AwaitingPfx`, `Completed`,
`CompletedWithWarnings`, `Error`.

Example payload (`examples/heartbeat.json`, non-sensitive):

```json
{
  "schemaVersion": 1,
  "tool": "CERTAMENT",
  "version": "1.0.0",
  "runId": "run-local-001",
  "InstallationId": "install-example-001",
  "customer": "Example Customer",
  "server": "example-server",
  "status": "Completed",
  "stage": "MainEnd",
  "detail": "Local monitoring example",
  "timestampUtc": "2026-09-12T10:00:00Z",
  "durationSec": 12.4,
  "certificateDaysRemaining": 183,
  "notificationStatus": "Sent"
}
```

## Storage: Latest and History

Both tables partition by `InstallationId` (SHA-256 hashed into `PartitionKey=installation_<hash>`),
so Latest and History rows for the same installation always share the same `PartitionKey`.

Latest table:

- `RowKey=latest` (one row per installation, overwritten on every heartbeat).
- `InstallationId`, `Customer`, `Server`, `Version`, `Status`, `RunStatus`, `Stage`, `Detail`.
- `TimestampUtc`, `DurationSec`, `CertificateDaysRemaining`.
- `NotificationStatus`, `RunId`, `SchemaVersion`.

History table:

- `RowKey=<timestampUtc>_<hashed runId>` (append-only, one row per heartbeat).
- Same properties as Latest.

`Status` is the classification computed by `Get-HeartbeatClassification` (Healthy/Warning/Critical),
distinct from the run's own `RunStatus`/`status`.

## Authentication

`POST /api/heartbeat` requires a `x-certament-token` header matching `CERTAMENT_HEARTBEAT_TOKEN`.
Missing or wrong token -> `401`. The GET endpoints (`servers`, `history`, `health`) are anonymous
locally (no tenant/network boundary to protect in this MVP).

## Local run with Azurite

Prerequisites: Azure Functions Core Tools, PowerShell worker support and Azurite (Node.js). No Azure tenant is required.

1. Copy `local.settings.example.json` to `local.settings.json` and set a local-only `CERTAMENT_HEARTBEAT_TOKEN` plus `AzureWebJobsStorage=UseDevelopmentStorage=true`.
2. Start Azurite from `monitoring/`, in its own terminal:

   ```powershell
   azurite --silent --location .\azurite-data --debug .\azurite-debug.log
   ```

3. Start the Functions host from `monitoring/`, in another terminal:

   ```powershell
   func start --port 7071
   ```

4. Send a heartbeat using the non-sensitive `examples/heartbeat.json`:

   ```powershell
   $body = Get-Content .\examples\heartbeat.json -Raw
   Invoke-RestMethod -Method POST -Uri http://localhost:7071/api/heartbeat `
     -Headers @{ 'x-certament-token' = 'local-only-token' } `
     -ContentType 'application/json' -Body $body
   ```

5. Verify the GETs:

   ```powershell
   Invoke-RestMethod -Uri http://localhost:7071/api/servers
   Invoke-RestMethod -Uri http://localhost:7071/api/history
   Invoke-RestMethod -Uri http://localhost:7071/api/health
   ```

Negative checks:

```powershell
# Missing token -> 401
Invoke-RestMethod -Method POST -Uri http://localhost:7071/api/heartbeat -ContentType 'application/json' -Body $body

# Wrong token -> 401
Invoke-RestMethod -Method POST -Uri http://localhost:7071/api/heartbeat -Headers @{ 'x-certament-token' = 'wrong-token' } -ContentType 'application/json' -Body $body

# Invalid payload (missing required fields) -> 400
Invoke-RestMethod -Method POST -Uri http://localhost:7071/api/heartbeat -Headers @{ 'x-certament-token' = 'local-only-token' } -ContentType 'application/json' -Body '{"schemaVersion":1,"tool":"CERTAMENT"}'
```

Do not commit `local.settings.json`, real tokens or connection strings, `azurite-data/`, or `func-local.log*` (all excluded via `.gitignore`). The local API returns 401 for missing/wrong tokens, 400 for invalid payloads and 500 without internal storage details for storage failures.

Note: the PowerShell worker's managed dependencies (`requirements.psd1`) must include `Az.Resources`, otherwise `AzTable`'s internal helper script fails to load in the Functions worker profile (`profile.ps1`) even when `Az.Resources` is present system-wide.

## Local E2E test results

Executed manually against Azurite + `func start` (PowerShell worker), no Azure tenant involved:

| Check | Result |
|---|---|
| `POST /api/heartbeat` (valid payload + valid token) | `202 Accepted` |
| `GET /api/servers` | `200 OK`, returns the posted installation |
| `GET /api/history` | `200 OK`, returns the posted run |
| `GET /api/health` | `200 OK`, correct Healthy/Warning/Critical counters |
| `POST /api/heartbeat` missing token | `401 Unauthorized` |
| `POST /api/heartbeat` wrong token | `401 Unauthorized` |
| `POST /api/heartbeat` invalid payload | `400 Bad Request` |
| `Invoke-Pester -Path tests\Monitoring.Tests.ps1` | `13/13 PASS` |

Not yet verified (requires an Azure tenant): real Storage Account throughput/latency,
Function App auth/networking, managed dependency resolution behind a real Functions runtime
in Azure, CI/CD deployment, dashboard integration.

## API

- `POST /api/heartbeat` - authenticated ingest.
- `GET /api/servers` - latest row per server.
- `GET /api/history` - latest 20 history rows.
- `GET /api/health` - aggregate Healthy/Warning/Critical state.

Freshness thresholds: under 30 hours is fresh, 30-48 hours is Warning, over 48 hours is Critical. Error runs are Critical; warning/awaiting states are Warning.
