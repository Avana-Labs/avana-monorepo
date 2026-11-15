# services/dashboards

Grafana dashboards for the indexer, the keeper and the monitor, with the Prometheus that scrapes them. They run from [services/compose.yaml](../compose.yaml) under the `dashboards` profile, so a plain `docker compose up` does not start them.

## Start

From the repository root, with the services' usual variables (`POSTGRES_PASSWORD`, `KEEPER_TLS_DIR`) and two more:

```bash
export MONITOR_METRICS_TOKEN=...    # bearer token of the monitor's /metrics; must differ from MONITOR_STATUS_TOKEN
export GRAFANA_ADMIN_PASSWORD=...   # Grafana's admin password
docker compose -f services/compose.yaml --profile dashboards up --build
```

Grafana is at http://127.0.0.1:3000 (user `admin`), Prometheus at http://127.0.0.1:9090; both listen on the loopback address only. Prometheus and Grafana each exit at start when their variable is not set. The compose file passes `MONITOR_METRICS_TOKEN` to the monitor and to Prometheus, so set it in the shell, not in `monitor/.env` (the compose value replaces the file's). Grafana reads `GRAFANA_ADMIN_PASSWORD` only when it first creates its database (the `grafana` volume); change it later with `grafana cli admin reset-admin-password` in the container.

Prometheus keeps 30 days in the `prometheus` volume and scrapes every 15 seconds ([prometheus.yml](prometheus.yml)): `indexer:42069`, `keeper:9464` and `monitor:9470`, each at `/metrics`.

## Files

| Path | Content |
|---|---|
| `prometheus.yml` | Scrape targets by compose service name; the monitor job sends the bearer token |
| `grafana/provisioning/datasources/prometheus.yml` | The Prometheus data source, uid `prometheus` |
| `grafana/provisioning/dashboards/avana.yml` | Loads `grafana/dashboards/*.json` into the folder Avana, read-only in Grafana |
| `grafana/dashboards/*.json` | The dashboards below; edit the JSON, Grafana reloads it within a minute |

## Dashboards

Every dashboard but the overview has a `chain` selector (the chain key, `mainnet`, `base`, `sepolia`, `baseSepolia`, `anvil`, the `chain` label of all three services).

- **Avana services overview**: whether each service answers its scrape, open pages and warns at the monitor, failed notice deliveries in the last hour, the keeper's mode per chain, seconds since the monitor's last successful round (`/healthz` fails after 5 intervals), each keeper instance's heartbeat age at the monitor (3 blocks pages `M-09`), how far the indexer is behind the wall clock, and how many blocks the indexer and the keeper are behind the monitor's head.
- **Avana monitor**: open alerts by signal and level (the subjects are in `GET /v1/status`), time since the last successful round, round duration and rounds per minute by result, probe read failures, the head each round read, each keeper instance's heartbeat age and last reported block, notices per hour by level and transition, failed deliveries per channel.
- **Avana keeper**: mode per chain, the heartbeat age the monitor sees, the alerts the monitor holds for the keeper's signals (`M-09`, `M-10`, `M-16`, `M-17`, `M-24`, `M-26`, `M-30`), the last processed head, blocks behind the indexer, discovered accounts, accounts only one discovery source holds (by source), and the keeper's open alerts.
- **Avana indexer**: realtime or historical per chain, how far indexing is behind the wall clock, historical sync progress, the synced block and its age, events indexed per second by event, indexing function and realtime latency (p95), reorgs, RPC errors and latency, HTTP requests by path and status, database errors, resident memory.

## Metrics read

| Service | Metrics |
|---|---|
| Monitor ([services/monitor](../monitor/README.md#metrics)) | `monitor_open_alerts`, `monitor_rounds_total`, `monitor_round_duration_seconds`, `monitor_round_last_success_timestamp_seconds`, `monitor_head_block`, `monitor_probe_read_failures_total`, `monitor_keeper_heartbeat_block`, `monitor_keeper_heartbeat_age_blocks`, `monitor_notices_total`, `monitor_deliveries_total`, `monitor_start_time_seconds` |
| Keeper ([services/keeper/src/metrics.ts](../keeper/src/metrics.ts)) | `keeper_mode{chain,mode}`, `keeper_head_block{chain}`, `keeper_indexer_block{chain}`, `keeper_rpc_backfill_block{chain}`, `keeper_discovered_accounts{chain}`, `keeper_discovery_one_sided{chain,only}`, `keeper_alerts_open{chain,signal,level}`, `keeper_alerts_total{chain,signal,level}` |
| Indexer (Ponder 0.18) | `ponder_sync_block`, `ponder_sync_block_timestamp`, `ponder_sync_is_realtime`, `ponder_indexing_timestamp`, `ponder_historical_completed_blocks`, `ponder_historical_total_blocks`, `ponder_indexing_completed_events`, `ponder_indexing_function_duration`, `ponder_realtime_latency`, `ponder_realtime_reorg_total`, `ponder_rpc_request_error_total`, `ponder_rpc_request_duration`, `ponder_http_server_request_duration_ms`, `ponder_database_method_error_total`, `process_resident_memory_bytes` |
| Prometheus | `up` |
