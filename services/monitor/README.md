# services/monitor

Avana's monitoring service: the signals `M-01` to `M-37` of [services/README.md](../README.md#monitoring-and-alerting) at warn and page levels, each sent to its responders with its playbook, every page re-read on a second RPC provider at the same block before it goes out, every notice logged with its block (`EMG-075`).

## How it works

Each chain is read every `MONITOR_INTERVAL_SECONDS` (60 by default), one round at a time:

1. The bot runner's findings at the head: alerts the bot runner instances (services/keeper) posted (held while they keep arriving, resolved once the head is more than two blocks past the last report) and each instance's heartbeat (3 blocks behind the head pages its on-call engineer).
2. Each probe ([src/probes.ts](src/probes.ts)) reads its inputs at the head on the primary provider and judges them: the chain snapshot of `@avana/services-common/views`, the oracles, coverage and pools, band edges and depegs, keeper wallets, contract events since the last round, issuer probes, and where configured the Safes, the Core Hub GHO rate and the frontend. A subject whose read fails is unread: its open alert is neither resolved nor re-sent.
3. Each page is confirmed: the probe is read again on the second provider at the same block, and the values the page was judged from must match. A page they contradict goes out as a warn with a note; with the second provider down it still pages, marked unconfirmed.
4. The alert book turns findings into notices: a condition is sent when it opens, on each level change and when it resolves; an event every time. A page that stays true is sent once.
5. Each notice goes to its recipients' channels (PagerDuty, an https webhook, the log), retried with backoff, and is appended to the incident log with each channel's answer.

Routing (services/README.md, Rules): warns reach the on-call engineer and the signal's responders; pages also reach the governance Safe's and the Emergency Guardian's signers and the Aave Protocol Guardian contact. The service refuses to start if any recipient has no channel, a chain has no second provider, or a keeper instance has no token.

## Signals

| Signal | Probe | Reads and levels |
|---|---|---|
| M-01 | snapshot | A market whose LPOracle `latestAnswer` reverts (a stale or invalid feed leg) pages: the Spoke cannot price its collateral |
| M-03 | oracle | Every LPOracle leg (`feedsOf`, recorded in the manifest) against its heartbeat: past it warns, past 1.5 heartbeats pages |
| M-04 | oracle | Every debt reserve's Chainlink feed, the same limits |
| M-06 | snapshot | Collateral value per market, −10 % / −25 % from the hour's peak |
| M-09 | keeper | As the bot runner posts it; an instance 3 blocks silent pages too |
| M-10 | events, keeper | The share of a market's collateral seized by `LiquidationModule.Liquidated` (10 % / 20 % in the hour); the LiquidationBot's failures when it posts them |
| M-13 | coverage | Each First-Loss Reserve's `fundedBalance()` against its `minimum()` (150 % / 100 %); each DAO deficit offset against its minimum (warn) |
| M-14 | coverage | The First-Loss Reserve's balance against Σ `RiskModule.coverage(hub, asset).required` of the snapshot: 150 % / 100 % |
| M-15 | snapshot | Any deficit warns; uncovered by both loss layers for 24 hours pages |
| M-16 | keeper | As the bot runner posts it: a liquidatable account the LiquidationBot cannot fund pages |
| M-18 | snapshot | CDP Spoke owed against its draw cap: 80 % / 90 % |
| M-19 | snapshot | Utilization 90 % / 98 %; a Lend Spoke's supply down more than 10 % within the hour pages |
| M-20 | events | Aave configuration events and upgrades of every CDP Spoke warn |
| M-22 | events | AccessManager `OperationScheduled` warns; `RoleGranted`, `RoleRevoked`, `TargetFunctionRoleUpdated`, `TargetClosed` page |
| M-23 | safes | Owners, threshold, guard slot and modules of each `MONITOR_SAFES` Safe; any change pages. Signer liveness (see Signer liveness) |
| M-24 | snapshot | A market's vault-token reserve or a debt reserve frozen, paused or reopened on its Spoke (a depeg's response is a freeze) |
| M-25 | issuers, events | `paused()` and `basisPointsRate()` of every pool token and debt asset (a change warns); a blocklist naming an LPVault, AaveAdapter, LiquidationModule or FlashloanRepay pages, another Avana contract warns |
| M-27 | frontend | The page's sha256 with the per-load values blanked, against `MONITOR_FRONTEND_SHA256` (a mismatch pages; without it a change warns); DNS records and the `server` header (a change warns) |
| M-28 | coverage | The in-range liquidity of each pool both markets of a pair share (a v3/Slipstream pool's `liquidity()`, a v4 PoolId's through the PoolManager): −20 % / −40 % within the hour |
| M-29 | snapshot, ghoRate | Any rate-curve change warns; GHO's `baseDrawnRate` below the Core Hub's (`MONITOR_CORE_HUB_GHO`, read from the Hub asset's rate strategy) pages |
| M-35 | wallets | Each keeper wallet (the manifest's `roles.keepers`, the flash liquidators' operators, `MONITOR_KEEPER_WALLETS`) against the `11-fund-keepers` rule of the manifest's `keeperTopUp`: below `minBalanceWei` warns (run the step), below a third of it pages; the top-up wallet below one full refill (`targetBalanceWei` per keeper) warns. `MONITOR_KEEPER_WALLET_WARN_WEI` and `MONITOR_KEEPER_WALLET_PAGE_WEI` override the keeper limits |
| M-36 | markets | A Custom range market's pool tick (`slot0`, or the PoolManager's slot0 of a v4 PoolId) against its band: within 10 % of the width from an edge warns, outside pages |
| M-37 | markets | On a Stable or Correlated pair (`RiskModule.getSpoke(spoke).kind`): the pool price against the LPOracle's fair `sqrtPriceX96` more than 1 % apart, or a Stable token's Chainlink price below $0.99. The response is a freeze: it pages while the market's reserve is open ("freeze the market's vault-token reserve") and warns once it is frozen |

`M-02`, `M-05`, `M-07`, `M-08`, `M-11`, `M-12`, `M-17`, `M-21`, `M-26` and `M-30` to `M-34` are retired rows: the contracts they read (breakers, swap routes, the Lens, Collateralization, the old keeper) are gone.

The bot runner posts `M-09`, `M-10` and `M-16` ([services/keeper/DESIGN.md](../keeper/DESIGN.md)); the monitor holds each alert open while it keeps arriving without reading it again.

## Signer liveness

Each period (`MONITOR_LIVENESS_PERIOD_HOURS`, 24 by default) every signer of a watched Safe signs, with their signer key (EIP-191 `personal_sign`), the text

```
Avana signer liveness
chain <chainId>
safe <safe address, lower case>
period <floor(unix time / period seconds)>
```

and posts `{ "chainId", "safe", "period", "signer", "signature" }` to `/v1/liveness`. Only the current period is accepted, the signature must recover to the named signer, and only current owners count. Once the answer window (`MONITOR_LIVENESS_WINDOW_HOURS`, 12) has passed, fewer than threshold + 1 answers pages; periods before the monitor started are never judged. An owner that is itself a contract (EIP-1271) cannot answer this way.

## Restarts

The state file (`MONITOR_STATE_PATH`) is written after every round and loaded at startup: open alerts are not sent again, the events probe resumes from its next block (events during downtime are read on catch-up, 2,000 blocks a round), and the hour windows, uncovered-deficit start times, last-seen Safes, issuer probes, frontend, route measurements and liveness answers carry over. A file of another version stops the process.

## Endpoints

| Path | Auth | Use |
|---|---|---|
| `POST /v1/keeper/alerts` | the instance's bearer token | `{ "instance", "alerts": [keeper.alert lines] }`; refused lines are answered with 422, the others kept |
| `POST /v1/keeper/heartbeat` | the instance's bearer token | `{ "instance", "blockNumber": "<decimal>" }` |
| `POST /v1/liveness` | the signer's signature | A Safe signer's liveness answer; refused answers get 422 with the reason |
| `GET /v1/status` | `MONITOR_STATUS_TOKEN` | Open alerts |
| `GET /metrics` | `MONITOR_METRICS_TOKEN` | The Prometheus text format (see Metrics); 404 when the token is not set |
| `GET /healthz` | none | 503 when a chain has gone 5 intervals without a successful round, for the uptime check that watches the monitor |

## Metrics

`GET /metrics` serves, with the bearer token `MONITOR_METRICS_TOKEN` (which must differ from the status token), the metrics [services/dashboards](../dashboards/README.md) reads. `chain` is the chain key (`mainnet`, `base`), as in the keeper's and the indexer's metrics; `keeper` is a keeper instance name.

| Metric | Type | Labels | Value |
|---|---|---|---|
| `monitor_start_time_seconds` | gauge | | Unix time the process started |
| `monitor_open_alerts` | gauge | chain, signal, level | Open alerts; every signal and level is listed, 0 when none is open |
| `monitor_rounds_total` | counter | chain, result (`ok`, `failed`) | Rounds |
| `monitor_round_duration_seconds` | gauge | chain | Duration of the last round |
| `monitor_round_last_success_timestamp_seconds` | gauge | chain | Unix time the last successful round ended; absent before the first |
| `monitor_head_block` | gauge | chain | The head the last round read |
| `monitor_probe_read_failures_total` | counter | chain, probe | Probe reads that failed (the round then fails) |
| `monitor_keeper_heartbeat_block` | gauge | keeper, chain | The last block the instance reported; absent until its first report |
| `monitor_keeper_heartbeat_age_blocks` | gauge | keeper, chain | The chain's last head read less that block; 3 or more pages `M-09` |
| `monitor_notices_total` | counter | chain, signal, level, transition | Notices sent |
| `monitor_deliveries_total` | counter | channel, result (`ok`, `failed`) | Deliveries per channel after retries |

## Run and test

Configuration names are in [.env.example](.env.example).

```bash
npm run start -w services/monitor
npm run typecheck -w services/monitor
npm run test -w services/monitor
```

The tests cover the catalog against the services README table, every rule at its boundaries (snapshot rules on the services-common fixture snapshot, the probes on a scripted chain), the alert lifecycle, routing and its refusals, the PagerDuty and webhook payloads, retries, the second-provider confirmation, the keeper ingest (tokens, line checks, heartbeats), one round end to end on a scripted chain, the metrics text and its token, and the configuration's refusals.
