# services/monitor

Avana's monitoring service: the signals `M-01` to `M-34` of [services/README.md](../README.md#monitoring-and-alerting) at warn and page levels, each sent to its responders with its playbook, every page re-read on a second RPC provider at the same block before it goes out, every notice logged with its block (`EMG-075`).

## How it works

Each chain is read every `MONITOR_INTERVAL_SECONDS` (12 by default), one round at a time:

1. The keeper's findings at the head: alerts the keeper instances posted (held while they keep arriving, resolved once the head is more than two blocks past the last report) and each instance's heartbeat (3 blocks behind the head pages its on-call engineer).
2. Each probe ([src/probes.ts](src/probes.ts)) reads its inputs at the head on the primary provider and judges them: the chain snapshot of `@avana/services-common/views`, the oracles, coverage and pools, contract events since the last round, issuer probes, route depth (every `MONITOR_ROUTE_CHECK_HOURS`, 24 by default), each market's oracle checkpoint, and where configured the Safes, the Core Hub GHO rate and the frontend. A subject whose read fails is unread: its open alert is neither resolved nor re-sent.
3. Each page is confirmed: the probe is read again on the second provider at the same block, and the values the page was judged from must match. A page they contradict goes out as a warn with a note; with the second provider down it still pages, marked unconfirmed.
4. The alert book turns findings into notices: a condition is sent when it opens, on each level change and when it resolves; an event every time. A page that stays true is sent once.
5. Each notice goes to its recipients' channels (PagerDuty, an https webhook, the log), retried with backoff, and is appended to the incident log with each channel's answer.

Routing (services/README.md, Rules): warns reach the on-call engineer and the signal's responders; pages also reach the governance Safe's and the Emergency Guardian's signers and the Aave Protocol Guardian contact. The service refuses to start if any recipient has no channel, a chain has no second provider, or a keeper instance has no token.

## Signals

| Signal | Probe | Reads and levels |
|---|---|---|
| M-01 | snapshot, oracle | Market price state and each DebtOracle's (Lens `getDebtPriceState`): Cached warns, Expired pages |
| M-02 | oracle | LPOracle `disagreeSince` against the market's `disagreementPauseMax`: warns from the start, pages 30 minutes before the end |
| M-03 | oracle | Every Chainlink leg of the manifest against its ParameterStore `feedMaxAge`: 50 % / 90 % |
| M-04 | oracle | Debt price age against the DebtOracle's `borrowPriceMaxAge` / 90 % of `liquidationPriceMaxAge`; GHO's fixed price skipped |
| M-05 | oracle | LPOracle `usdLevel` (√(q0·q1)) below 0.95 / 0.90, for markets with a USD band only |
| M-06 | snapshot | Collateral value per market, −10 % / −25 % from the hour's peak |
| M-07 | coverage | Lens `getCapHeadroom` pool share: above 75 % of `poolShareMaxBps` / above it |
| M-08 | snapshot | Market and debt-reserve breakers; a security freeze (issuer, deficit, manual, configuration drift) pages |
| M-09 | keeper | As the keeper posts it; a keeper instance 3 blocks silent pages too |
| M-10 | events, keeper | RouteFailed per market (1 / 3 in the hour) and the share of collateral seized by LiquidationSettled (10 % / 20 % in the hour); the keeper's simulation reverts when it posts them |
| M-11 | routes | Every `MONITOR_ROUTE_CHECK_HOURS` (24 by default), every route slot (market, pool token, debt asset, primary or backup) swapped by `eth_call` with state overrides at 120 % and 100 % of the stress size: the ParameterStore's `routeDepthThreshold(marketId, token, debtAsset, kind)`, in base units of the debt asset, converted into the pool token at the oracle prices. A swap counts when its output covers the stress amount less the market's slippage allowance: 120 % ok, only 100 % warns, less pages; a slot whose threshold is 0 or whose token storage slots are not found warns |
| M-12 | routes | For a GSM route, the GSM's exposure room (cap less underlying held) against the stress input (the pool-token amount worth `routeDepthThreshold`): below 2x warns, below 1x pages |
| M-13 | coverage | Lens `getTailCoverage` funded against the reserve minimum (150 % / 100 %); the DAO deficit offset against its `firstLossReserveMinimum` (warn) |
| M-14 | coverage | `getTailCoverage` ratio: 150 % / 100 % |
| M-15 | snapshot | Any deficit warns; uncovered by both loss layers for 24 hours pages |
| M-16 | keeper | As the keeper posts it, every block per debt asset: the funding Safe's balance less open reservations against the largest single `debtToCover` the caps allow (`KEEPER_LARGEST_DEBT_TO_COVER_<CHAIN>`), 150 % / 100 %; an asset without that size warns |
| M-17 | keeper | As the keeper posts it, every block: the Aave V3 Pool's idle liquidity per debt asset (the helper's `maxFlashLoan`) against the same size, 2x / 1x, and the signer's gas balance against its median daily spend, 3 days / 1 day; a transaction above the gas ceiling pages |
| M-18 | snapshot | CDP Spoke owed against its draw cap: 80 % / 90 % |
| M-19 | snapshot | Utilization 90 % / 98 %; a Lend Spoke's supply down more than 10 % within the hour pages |
| M-20 | events | Aave configuration events and upgrades of every CDP Spoke warn; RiskModule `ConfigDriftDetected` pages |
| M-21 | coverage, events | Lens `checkBacking` invariants and `CounterSaturated` page |
| M-22 | events | Timelock `CallScheduled` warns; role changes, upgrades, `setShortDelaySelector`, `setNormalDelay`, `unfreezeAddress`, `restorePriceRoute` and Timelock role grants and revocations page |
| M-23 | safes | Owners, threshold, guard slot and modules of each `MONITOR_SAFES` Safe; any change pages. Signer liveness: once a period's answer window has passed, fewer than threshold + 1 current owners answering pages (see Signer liveness) |
| M-24 | snapshot, events, keeper | Pause state and Hub application state changes, manual trips, address freezes and unfreezes, the standby switch, pause reasons; the keeper pages when a liquidation reverts with `AddressIsFrozen` (it stops its helper on that chain) |
| M-25 | issuers, events | `paused()` and `basisPointsRate()` of every pool token and debt asset (a change warns); a blocklist naming LPVaultSwap, an LPVault, Collateralization or the AaveAdapter pages, another Avana contract warns |
| M-26 | keeper | As the keeper posts it: a code-check mismatch, or the Aave V3 Pool's implementation changed (flash funding stops) |
| M-27 | frontend | The page's sha256 against `MONITOR_FRONTEND_SHA256` (a mismatch pages; without it a change warns); DNS records and the `server` header (a change warns). No second RPC provider applies: the confirming read fetches again |
| M-28 | coverage | Each listed pool's in-range `liquidity()`: −20 % / −40 % within the hour |
| M-29 | snapshot, ghoRate | Any rate-curve change warns; GHO's `baseDrawnRate` below the Core Hub's (`MONITOR_CORE_HUB_GHO`) pages |
| M-30 | keeper | As the keeper posts it, one alert per chain: accounts only one of its discovery sources holds (the indexer stream or the RPC log backfill) warn, one-sided for `KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS` pages |
| M-31 | keeper | As the keeper posts it, every block: the rolling 24 h gas spend from its spend log above 3x the 7-day median daily spend warns, above 5x pages |
| M-32 | keeper | As the keeper posts it, every block while it holds: a scheduled or lazy fee class at its rolling 24 h budget (`KEEPER_DAILY_BUDGET_WEI_{SCHEDULED,LAZY}_<CHAIN>`) has stopped sending; pages |
| M-33 | keeper | As the keeper posts it, every block: the standby signer's gas balance below `KEEPER_STANDBY_MIN_BALANCE_WEI_<CHAIN>` warns |
| M-34 | checkpoint | Each market's LPOracle `priceCheckpoint().at`, read from the chain at the round's block: older than 7,200 s pages, confirmed on the second provider; resolves once a poke stores a new checkpoint. Independent of the keeper's heartbeat |

The keeper posts `M-09`, `M-10`, `M-16`, `M-17`, `M-24`, `M-26`, `M-30`, `M-31`, `M-32` and `M-33` ([services/keeper/DESIGN.md](../keeper/DESIGN.md#monitoring-service)); the keeper confirms its block-cadence pages on chain state on its fallback provider (`M-31` and `M-32` judge its own spend log, which has nothing to confirm), and the monitor holds each alert open while it keeps arriving without reading it again.

## Route simulation

M-11 runs no fork: each swap is an `eth_call` at the latest block from LPVaultSwap's address with state overrides. The token's balance and allowance slots are found once per token by writing a marker and reading it back (Solidity and Vyper mapping layouts, slots 0 to 63 and OpenZeppelin v5's ERC-7201 base); the Lock's code is replaced by a stub whose `holder()` answers LPVaultSwap, because the real Lock keeps its holder in transient storage. The RPC provider must accept `eth_call` state overrides and a `from` that is a contract (geth, Erigon, Nethermind, Reth and anvil do). A token whose slots are not found is reported as not simulated (warn).

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
