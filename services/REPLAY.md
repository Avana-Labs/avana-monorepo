# Indexer replay into a local Convex

Runs the local rehearsal on anvil, indexes every block of it, replays the index from scratch into a local Convex deployment and checks Convex against the chain. Nothing runs in Docker or in the cloud: the indexer uses PGlite and Convex runs as an anonymous local deployment (`convex dev`, no account).

## Run it

From `contracts/`, after `npm ci` at the repo root and `make build build-aave build-external`:

```bash
E2E_STEPS="deploy day2 exotic manifest replay drills scenarios" script/e2e/e2e-local.sh
```

The `replay` step needs the `deploy` step in the same run (the indexer reads past blocks, which a node reloaded from `anvil-state.json` does not hold). Expect the whole run to take about as long as the rehearsal itself plus a few minutes for the replay.

With the `replay` step, the drills `offboard-close`, `cancel-registration` and `retire-spoke` are recorded as not run. They put the chain back with `evm_snapshot` and `evm_revert`, and the live indexer cannot follow anvil back: it is still reading blocks the revert removed, fails to fetch their logs and stops. Run those drills in a rehearsal without the `replay` step. The `hostile` step also reverts the chain, but it runs before the indexer starts.

The outcome is the `replay:start` and `replay` entries of `deployments-local/anvil/e2e-status.json`. Logs:

| File | Contents |
|---|---|
| `deployments-local/anvil/logs/replay-start.log` | The live indexer reaching the head after the manifest step |
| `deployments-local/anvil/logs/replay.log` | The replay and every check, one line each |
| `deployments-local/anvil/replay/indexer-live.log`, `indexer-replay.log` | Ponder's JSON logs of the two passes |
| `deployments-local/anvil/replay/convex.log` | The local Convex deployment's logs |
| `deployments-local/anvil/replay/rpc-record.jsonl`, `rpc-recorder.log` | The recorder's kept answers and its log; `replay.log` has its counts |
| `deployments-local/anvil/replay/replay-check.log` | The check's output |

## What it does

1. **Live pass** (`services-replay.sh start`, right after the manifest step). The indexer starts on the release manifest (schema `live`, port 42070) and follows the chain while the drills and the scenarios run. It has to run during the rehearsal: anvil keeps only its recent states, and the indexer reads contracts at past blocks. Ponder stores every log, block and pinned read it fetched in its sync store, except a read that reverts or returns no data. The hourly sampler makes such reads (it probes Hubs and Spokes that have no code yet at early blocks), so the indexer reads the node through `contracts/script/e2e/rpc-recorder.ts` (port 8549), which keeps each pinned read's answer, a multicall's sub-calls one by one, in `replay/rpc-record.jsonl`. Anvil would need about 24 MB of disk per block to keep the whole history instead.
2. **Closing samples** (`services-replay.sh finish`, after the last step). Two hourly sampler blocks one day apart (the sampler runs every 300 blocks on anvil), so a daily position bucket and an hourly market-debt bucket close; then 70 blocks, past anvil's finality.
3. **Replay.** A second indexer, in a fresh schema `replay`, indexes every block again from the manifest's start blocks, served from the sync store and the recorder (anvil no longer holds the early blocks' state). It must reach the head with no warning or error line, and every one of its tables must equal the live pass's. Two kinds of warning are the node's and are only counted: Ponder's notice that the RPC URL is a public one, and requests a busy anvil answered after Ponder's timeout, which Ponder retried. Any other RPC error, such as a read of a block anvil no longer holds, fails the run.
4. **Convex.** A fresh local deployment of `services/convex` imports the replay's export and series to the finalized block, samples the chain, rolls up every day that has a liquidation and tracks three intents. `contracts/script/e2e/replay-check.ts` then compares Convex with the chain:

| Entity | Convex | Chain |
|---|---|---|
| Markets | `markets` rows, `MarketRegistered` logs | `MarketRegistered` logs; the snapshot reader at each row's block |
| Hub assets | `hubAssets` added, owed, liquidity, deficit, price | The snapshot reader at each row's block |
| Accounts | `accounts` | `AaveAdapter.UserProxyCreated` logs |
| Positions | `positions` (last closed daily sample) | `Spoke.getUserSuppliedAssets` and `getUserDebt` at that sample's block |
| Debts | `marketReserveDebt`; CDP Spoke `Borrow`, `Repay`, `ReportDeficit` logs | The positions' debts summed per market and reserve; the same logs |
| Liquidations | `LiquidationSettled` and `Deleveraged` logs with their reports; `dailyRollups` counts | The same logs, counted per market and UTC day |
| Payouts | Borrower surplus, deficit funding and cover, reserve funding, escrowed and claimed remainders | The same logs |
| Intents | `intents` after `intents:track` | A rehearsal transaction with protocol logs (`indexed`), one without logs (`included`), one that reverts (`failed`) |

Logs are compared by key (`chainId:txHash:logIndex`) against every log of the event's signature on the chain, from any address, so an address that only the chain knows shows up as missing. A market debt that Convex keeps after the chain has none fails as stale.

## Running the pieces by hand

With the rehearsal's anvil node still running (for example a run stopped before `scenarios`, or `E2E_STEPS="deploy manifest"` with the node left up):

```bash
script/e2e/services-replay.sh start deployments-local/anvil/manifest.json
```

```bash
script/e2e/services-replay.sh finish deployments-local/anvil/manifest.json
```

`finish` moves the clock and signs fresh price rounds with the run's OCR keystores, so export what `e2e-local.sh` exports first (`AVANA_OCR_KEYSTORE_DIR`, `AVANA_OCR_ORACLES`, from `deployments-local/anvil/keystore`). `E2E_REPLAY_KEEP=1` leaves the local Convex deployment running afterwards; `services-replay.sh stop` stops a live indexer and the recorder an aborted run left behind. No step uses a private key: transactions go through anvil's `--auto-impersonate`, and the signers are the run's encrypted keystores.
