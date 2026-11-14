# services/monitor

Avana's monitoring service: the signals `M-01` to `M-29` of [services/README.md](../README.md#monitoring-and-alerting) at warn and page levels, each sent to its responders with its playbook, every page re-read on a second RPC provider at the same block before it goes out, every notice logged with its block (`EMG-075`).

## How it works

Each chain is read every `MONITOR_INTERVAL_SECONDS` (12 by default), one round at a time:

1. The keeper's findings at the head: alerts the keeper instances posted (held while they keep arriving, resolved two blocks after the last report) and each instance's heartbeat (3 blocks behind the head pages its on-call engineer).
2. Each probe ([src/probes.ts](src/probes.ts)) reads its inputs at the head on the primary provider and judges them: the chain snapshot of `@avana/services-common/views`, the oracles, coverage and pools, contract events since the last round, issuer probes, route depth (daily), and where configured the Safes, the Core Hub GHO rate and the frontend. A subject whose read fails is unread: its open alert is neither resolved nor re-sent.
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
| M-11 | routes | Once a day, every route slot swapped by `eth_call` with state overrides at 120 % and 100 % of its `routeDepthThreshold` (the stress size), counting when the output covers the stress value less the market's slippage allowance: 120 % ok, only 100 % warns, less pages; a slot without a threshold warns |
| M-12 | routes | For a GSM route, the GSM's exposure room (cap less underlying held) against the stress input: below 2x warns, below 1x pages |
| M-10 | events, keeper | RouteFailed per market (1 / 3 in the hour) and the share of collateral seized by LiquidationSettled (10 % / 20 % in the hour); the keeper's simulation reverts when it posts them |
| M-13 | coverage | Lens `getTailCoverage` funded against the reserve minimum (150 % / 100 %); the DAO deficit offset against its `firstLossReserveMinimum` (warn) |
| M-14 | coverage | `getTailCoverage` ratio: 150 % / 100 % |
| M-15 | snapshot | Any deficit warns; uncovered by both loss layers for 24 hours pages |
| M-16, M-17 | keeper | Routed when the keeper posts them; the keeper does not emit them yet |
| M-18 | snapshot | CDP Spoke owed against its draw cap: 80 % / 90 % |
| M-19 | snapshot | Utilization 90 % / 98 %; a Lend Spoke's supply down more than 10 % within the hour pages |
| M-20 | events | Aave configuration events and upgrades of every CDP Spoke warn; RiskModule `ConfigDriftDetected` pages |
| M-21 | coverage, events | Lens `checkBacking` invariants and `CounterSaturated` page |
| M-22 | events | Timelock `CallScheduled` warns; role changes, upgrades, `setShortDelaySelector`, `setNormalDelay`, `unfreezeAddress`, `restorePriceRoute` and Timelock role grants page |
| M-23 | safes | Owners, threshold, guard slot and modules of each `MONITOR_SAFES` Safe; any change pages. Signer liveness: once a period's answer window has passed, fewer than threshold + 1 current owners answering pages (see Signer liveness) |
| M-24 | snapshot, events | Pause state and Hub application state changes, manual trips, address freezes, the standby switch, pause reasons |
| M-25 | issuers, events | `paused()` and `basisPointsRate()` of every pool token and debt asset (a change warns); a blocklist naming LPVaultSwap, an LPVault, Collateralization or the AaveAdapter pages, another Avana contract warns |
| M-26 | keeper | As the keeper posts it |
| M-27 | frontend | The page's sha256 against `MONITOR_FRONTEND_SHA256` (a mismatch pages; without it a change warns); DNS records and the `server` header (a change warns). No second RPC provider applies: the confirming read fetches again |
| M-28 | coverage | Each listed pool's in-range `liquidity()`: −20 % / −40 % within the hour |
| M-29 | snapshot, ghoRate | Any rate-curve change warns; GHO's `baseDrawnRate` below the Core Hub's (`MONITOR_CORE_HUB_GHO`) pages |

M-16 and M-17 are routed once the keeper emits them (the keeper chat has the request).

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
| `GET /healthz` | none | 503 when a chain has gone 5 intervals without a successful round, for the uptime check that watches the monitor |

## Run and test

Configuration names are in [.env.example](.env.example).

```bash
npm run start -w services/monitor
npm run typecheck -w services/monitor
npm run test -w services/monitor
```

The tests cover the catalog against the services README table, every rule at its boundaries (snapshot rules on the services-common fixture snapshot, the probes on a scripted chain), the alert lifecycle, routing and its refusals, the PagerDuty and webhook payloads, retries, the second-provider confirmation, the keeper ingest (tokens, line checks, heartbeats), one round end to end on a scripted chain, and the configuration's refusals.
