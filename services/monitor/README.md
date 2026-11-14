# services/monitor

Avana's monitoring service: the signals `M-01` to `M-29` of [services/README.md](../README.md#monitoring-and-alerting) at warn and page levels, each sent to its responders with its playbook, every page re-read on a second RPC provider at the same block before it goes out, every notice logged with its block (`EMG-075`).

## How it works

Each chain is read every `MONITOR_INTERVAL_SECONDS` (12 by default), one round at a time:

1. The keeper's findings at the head: alerts the keeper instances posted (held while they keep arriving, resolved two blocks after the last report) and each instance's heartbeat (3 blocks behind the head pages its on-call engineer).
2. The chain snapshot of `@avana/services-common/views` at the head on the primary provider, judged by the snapshot rules ([src/rules/snapshot.ts](src/rules/snapshot.ts)).
3. Each page is confirmed: the rows it was judged from must read the same on the second provider at the same block. A page they contradict goes out as a warn with a note; with the second provider down it still pages, marked unconfirmed.
4. The alert book turns findings into notices: a condition is sent when it opens, on each level change and when it resolves; an event every time. A page that stays true is sent once.
5. Each notice goes to its recipients' channels (PagerDuty, an https webhook, the log), retried with backoff, and is appended to the incident log with each channel's answer.

Routing (services/README.md, Rules): warns reach the on-call engineer and the signal's responders; pages also reach the governance Safe's and the Emergency Guardian's signers and the Aave Protocol Guardian contact. The service refuses to start if any recipient has no channel, a chain has no second provider, or a keeper instance has no token.

## Signals wired so far

| Signal | Source | State |
|---|---|---|
| M-01 | snapshot | LPOracle price state per market. The DebtOracle side needs `Lens.getDebtPriceState` in the snapshot |
| M-06 | snapshot | Collateral value per market, fall from the hour's peak |
| M-08 | snapshot | Market and debt-reserve breakers; a security freeze (issuer, deficit, manual, configuration drift) pages |
| M-09 | keeper | As the keeper posts it; a silent keeper instance also pages under M-09 |
| M-15 | snapshot | Any deficit warns; uncovered by both loss layers for 24 hours pages |
| M-18 | snapshot | CDP Spoke owed against its draw cap |
| M-19 | snapshot | Utilization; a Lend Spoke's supply falling more than 10 % within the hour |
| M-24 | snapshot | Market and funding-Hub pause state, Hub application state, manual breaker trips. Address freezes and the standby switch need their events |
| M-26 | keeper | As the keeper posts it |
| M-29 | snapshot | Any rate-curve change. The GHO page needs the Core Hub GHO base rate |
| M-10, M-16, M-17 | keeper | Routed when posted; the keeper does not emit them yet |

Not wired yet, each needing a reader: M-02 to M-05 (oracle views and the ParameterStore's ages and bounds), M-07 and M-28 (pool liquidity and Avana's share), M-11 and M-12 (the daily fork simulation), M-13 and M-14 (the ParameterStore's minimums, `getTailCoverage`), M-20 to M-22 (Aave configuration, backing-check and Timelock events), M-23 (Safes and signer liveness), M-25 (issuer probes and blocklists), M-27 (frontend bundle hash, DNS).

## Endpoints

| Path | Auth | Use |
|---|---|---|
| `POST /v1/keeper/alerts` | the instance's bearer token | `{ "instance", "alerts": [keeper.alert lines] }`; refused lines are answered with 422, the others kept |
| `POST /v1/keeper/heartbeat` | the instance's bearer token | `{ "instance", "blockNumber": "<decimal>" }` |
| `GET /v1/status` | `MONITOR_STATUS_TOKEN` | Open alerts |
| `GET /healthz` | none | 503 when a chain has gone 5 intervals without a successful round, for the uptime check that watches the monitor |

## Run and test

Configuration names are in [.env.example](.env.example).

```bash
npm run start -w services/monitor
npm run typecheck -w services/monitor
npm run test -w services/monitor
```

The tests cover the catalog against the services README table, every snapshot rule at its boundaries on the services-common fixture snapshot, the alert lifecycle, routing and its refusals, the PagerDuty and webhook payloads, retries, the second-provider confirmation, the keeper ingest (tokens, line checks, heartbeats), one round end to end on a scripted chain, and the configuration's refusals.
