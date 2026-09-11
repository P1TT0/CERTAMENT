# CERTAMENT Monitoring MVP

Azure Functions PowerShell API with Azure Table Storage.

## Application settings

- `AzureWebJobsStorage`: Azure Storage connection string.
- `CERTAMENT_HEARTBEAT_TOKEN`: secret expected in `x-certament-token`.
- `CERTAMENT_LATEST_TABLE`: defaults to `CertamentLatest`.
- `CERTAMENT_HISTORY_TABLE`: defaults to `CertamentHistory`.

The token is never returned by the API and is not used by the dashboard.

## API

- `POST /api/heartbeat` - authenticated ingest.
- `GET /api/servers` - latest row per server.
- `GET /api/history` - latest 20 history rows.
- `GET /api/health` - aggregate Healthy/Warning/Critical state.

Freshness thresholds: under 30 hours is fresh, 30-48 hours is Warning, over 48 hours is Critical. Error runs are Critical; warning/awaiting states are Warning.

## Table schema

Both tables use `PartitionKey=server` for operational queries.

Latest table:

- `RowKey=server name`
- `Customer`, `Version`, `Status`, `RunStatus`, `Stage`, `Detail`
- `TimestampUtc`, `DurationSec`, `CertificateDaysRemaining`
- `NotificationStatus`, `RunId`, `SchemaVersion`

History table:

- `RowKey=<timestampUtc>_<guid>`
- same properties as latest.
