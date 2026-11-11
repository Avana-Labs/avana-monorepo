# Keeper design

How the keeper process is built. What it must do (duties, sizing, submission rules, safety controls) is in [services/README.md](../README.md#keeper-keeper); this page maps those rules onto the code in `src/`.

## Process

`src/main.ts` starts in this order, and any step that fails stops the process before it can sign:

1. Fatal handlers: an uncaught exception or unhandled rejection logs one `keeper.fatal` line and exits with status 1. The supervisor restarts the process, the halt flag is read back from disk, and pending transactions that were lost expire at their 3-block deadline. The keeper never logs an unknown error and carries on.
2. Configuration (`config.ts`): environment names from `.env.example`, each chain's verified manifest with its ABI hash checked (`TEST-149`). Active mode is refused on a chain without a private endpoint.
3. Kill switch (`safety/killSwitch.ts`, mutual TLS) and metrics, on different ports.
4. Per chain: HTTP clients for the primary and fallback providers, a WebSocket client for heads, the KMS signer (none in observe-only mode), the operator helper bound to that signer, `MAX_TOP_UP_BPS` read from the helper, and a startup backfill of every account from `UserProxyCreated` logs over both providers.
5. Per chain: a head subscription with missed-block replay, a head watchdog (3 block times without a head triggers a backfill from the last finalized block) and the 10-minute full sweep.

Each chain processes one head at a time; heads arriving during a pass queue behind it.

## The per-block pass

`runtime/chainLoop.ts` runs, for head `B`:

1. **Reorg check** (`discovery/stream.ts`): a head whose parent hash is not the previous head's hash is a reorg. Touched accounts are re-read and the nonce is re-read from the provider.
2. **Own status**: `isApprovedKeeper`, `isFrozenAddress` and `activeKeeperCount` of the instance's helper. A frozen helper stops every submission on that chain.
3. **Jobs**, each through the pipeline below: liquidation, `settlePending`, oracle pokes, breaker and configuration pokes.
4. **Follow-ups** of pending transactions (`chain/submit.ts`, `runtime/submitter.ts`).
5. **Block-cadence alerts** (`monitoring/`), each page confirmed on the fallback provider at `B`.

## The pipeline

Every job implements `Job` (`types.ts`) and runs through `runJob` (`pipeline.ts`):

| Step | What it does | Where |
|---|---|---|
| Discover | Candidates from the cache or the manifest; cached values only choose what to read | `jobs/*.discover` |
| Live check | Re-reads eligibility at `B` through a reader pinned to `B` | `jobs/*.check`, `chain/reads.ts` |
| Build | Calldata, deadline, reservations and the code-check targets | `jobs/*.build` |
| Code check | ERC-1967 slot of every upgradeable target, runtime code hash of every immutable one, against the manifest; a mismatch moves the instance to observe-only and pages `M-26` | `safety/guards.ts` |
| Simulate | `eth_call` and `estimateGas` at `latest` from the signer; a failing simulation is logged with its decoded revert and never sent | `runtime/submitter.ts` |
| Guards | Kill switch, mode, code mismatch, frozen helper; observe-only logs the call it would send | `safety/guards.ts` |
| Send | Nonce under the lock, KMS signature, private endpoints only | `chain/nonce.ts`, `chain/signer.ts`, `chain/submit.ts` |

A failure on one candidate is logged and the pass continues with the next.

## Candidate cache

`discovery/accountCache.ts` keeps one entry per PositionProxy, keyed `chainId + Spoke + proxy`, with the wallet, market, vault token, last health factor and its block, the first block it was read below HF 1, and two flags: `deciding` (set for one pass, cleared in `finally`) and `pendingTx` (set on send, cleared by the follow-up when the transaction is mined, cancelled or expired). An account with either flag set is skipped by the next pass of this instance.

The set is the union of the indexer stream and RPC logs read over both providers; entries seen by only one source are reported (`REQ-LENS-004`). Backfills read 10,000-block ranges and halve the range whenever a provider refuses it (`discovery/backfill.ts`).

## Liquidation call

`jobs/liquidation.ts` and the pure rules in `jobs/liquidationRules.ts`:

1. One multicall at `B` reads `getUserAccountData` for every cached account, in batches of 300.
2. HF < 1 with collateral above 0, in this instance's shard or past the takeover window (`shard.ts`).
3. Market gate from `Lens.getPriceState`, then the largest-value debt reserve whose price passes.
4. `Lens.previewLiquidation(proxy, debtReserveId, B.timestamp + 3 blocks)`; the preview's gates decide.
5. Funding split between the flash loan and inventory, the top-up bound, then one `eth_call` of `flashLiquidate` with `minPayout = 0` at `B` to measure the net result, and the request's `minPayout` from it (99 % of a profit, or at most 101 % of a loss).
6. No swap calldata: the helper calls `LPVaultSwap.liquidate`, which holds the routes.

## Fees, retries and errors

- Fees (`chain/gas.ts`): tip = 90th percentile of the last 5 blocks' priority fees, at least 1 gwei; max fee = 2 × base fee + tip; gas limit ⌈1.25 × estimate⌉.
- Follow-up (`chain/submit.ts`, `followUp`): in every block a pending transaction is re-simulated. Mined: release. Still succeeding before its deadline: replace at the same nonce with both fee fields +15 %, through the same private endpoints. Past its deadline and still due: rebuild from a fresh preview at the same nonce. Past its deadline and no longer due: a zero-value transfer from the signer to itself at that nonce after 2 blocks. A nonce handed back for a rebuild that no pass used within 2 blocks is closed the same way.
- Nonces (`chain/nonce.ts`): one lock per signer; reset from the provider at startup, after a reorg and after `nonce too low`.
- Every attempt, skip, simulation failure, replacement and cancellation is one structured `keeper.attempt` line (`failureLog.ts`), from which the public failure log is published.

## What the design avoids

- No decision from cached or off-chain estimates: every decision reads the chain at a pinned block.
- No replacement or cancellation through a public endpoint: all sends share one private path.
- No contract-creation cancellations: a cancellation is a transfer to the signer's own address.
- No unbounded log ranges: chunks start at 10,000 blocks and halve on refusal.
- No missed events after a reconnect: logs are re-read from the last finalized block.
- No flag left set by an exception: the deciding flag is cleared in `finally`, the pending flag follows the transaction.
- No raw key in the process: signing goes through the KMS.
- No zero `minPayout`: the request's bound comes from the simulation at the decision block.
