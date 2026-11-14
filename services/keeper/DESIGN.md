# Keeper design

How the keeper process is built. What it must do (duties, sizing, submission rules, safety controls) is in [services/README.md](../README.md#keeper-keeper); this page maps those rules onto the code in `src/`.

## Process

`src/main.ts` starts in this order, and any step that fails stops the process before it can sign:

1. Fatal handlers: an uncaught exception or unhandled rejection logs one `keeper.fatal` line and exits with status 1. The supervisor restarts the process, the halt flag is read back from disk, and pending transactions that were lost expire at their 3-block deadline. The keeper never logs an unknown error and carries on.
2. Configuration (`config.ts`): environment names from `.env.example`, each chain's verified manifest with its ABI hash checked (`TEST-149`). Active mode is refused on a chain without a private endpoint.
3. Kill switch (`safety/killSwitch.ts`, mutual TLS) and metrics, on different ports.
4. Per chain: HTTP clients for the primary and fallback providers, a WebSocket client for heads, the KMS signer (none in observe-only mode), the operator helper bound to that signer, `MAX_TOP_UP_BPS` read from the helper, the indexer stream read to the indexer's head, and a backfill of every account from `UserProxyCreated` logs over both providers. Accounts only one source holds, up to the block both have read, are logged as `keeper.discoveryMismatch` (`REQ-LENS-004`).
5. Per chain: a head subscription with missed-block replay, a head watchdog (3 block times without a head triggers a backfill from the last finalized block) and the 10-minute full sweep, which repeats the comparison.

Each chain processes one head at a time; heads arriving during a pass queue behind it.

## The per-block pass

`runtime/chainLoop.ts` runs, for head `B`:

1. **Reorg check** (`discovery/stream.ts`): a head whose parent hash is not the previous head's hash is a reorg. Transactions seen mined whose nonce the new head no longer counts return to pending with their in-flight flags and reservations (`Submitter.onReorg`), then the nonce is re-read from the provider. Every account is re-read in the pass anyway.
2. **Indexer stream** (`discovery/indexerStream.ts`): pages after the keeper's cursor, at most 20 per head, each request bounded to 2 s. Creation events add accounts; the other kinds only name what changed. A failed request is logged once and the pass goes on without it; a 409 (the cursor's block left the canonical chain) rewinds the cursor to the finalized block, and both a 409 and the first success after a failure re-read RPC logs from the finalized block before the pass.
3. **Own status**: `isApprovedKeeper`, `isFrozenAddress` and `activeKeeperCount` of the instance's helper. A frozen helper stops every submission on that chain.
4. **Jobs**, each through the pipeline below: liquidation, `settlePending`, oracle pokes, breaker and configuration pokes.
5. **Follow-ups** of pending transactions (`chain/submit.ts`, `runtime/submitter.ts`).
6. **Block-cadence alerts** (`monitoring/`), each page confirmed on the fallback provider at `B`.

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

The set is the union of the indexer stream and RPC logs read over both providers; entries seen by only one source are reported (`REQ-LENS-004`). Each entry keeps the block of its earliest creation event, so the comparison counts only accounts created at or before the lower of the two sources' read heights. Backfills read 10,000-block ranges and halve the range whenever a provider refuses it (`discovery/backfill.ts`).

## Liquidation call

`jobs/liquidation.ts` and the pure rules in `jobs/liquidationRules.ts`:

1. One multicall at `B` reads `getUserAccountData` for every cached account, in batches of 300.
2. HF < 1 with collateral above 0, in this instance's shard or past the takeover window (`shard.ts`).
3. Market gate from `Lens.getPriceState`, then the largest-value debt reserve whose price passes.
4. `Lens.previewLiquidation(proxy, debtReserveId, B.timestamp + 3 blocks)`; the preview's gates decide.
5. Funding split between the flash loan and inventory, the top-up bound, then one `eth_call` of `flashLiquidate` with `minPayout = 0` at `B` to measure the net result, and the request's `minPayout` from it (99 % of a profit, or at most 101 % of a loss).
6. No swap calldata: the helper calls `LPVaultSwap.liquidate`, which holds the routes.

## Fees, retries and errors

- Fees (`chain/gas.ts`): tip = 90th percentile of the last 5 blocks' priority fees, at least 1 gwei; max fee = 2 × base fee + tip; gas limit ⌈1.3 × estimate⌉ + 25,000 (`@avana/services-common/gas`): `estimateGas` at `latest` runs at that block's timestamp, so a call touching a Hub asset already accrued in that second skips the accrual it pays when mined a second later.
- Fee ceiling (`runtime/submitter.ts`): the worst-case cost, gas limit × max fee plus, on Base and Base Sepolia, the L1 data fee from the `GasPriceOracle` predeploy's `getL1Fee` over the unsigned transaction, is checked under the nonce lock before signing. Above `KEEPER_GAS_CEILING_WEI_<CHAIN>` nothing is signed, `M-17` pages, the attempt is logged `aboveGasCeiling` and the reservation is released; a replacement above it is not sent and the transaction keeps waiting at its fees. Cancellations (21,000 gas) are not held to it, so a nonce can always be closed. A chain with a signer and no ceiling refuses to start.
- Failure reasons (`jobs/failureReasons.ts`): a liquidation whose simulation reverts, in the build's net measurement or in the pipeline's simulation, goes to the job's `onFailure` with the decoded reason and arguments. `RecoveryBelowFloor` (no arguments, so the gap is not measured on-chain) retries with `maxShortfall` and the top-up bound at `MAX_TOP_UP_BPS` of the debt repaid and warns `M-10`; `TopUpExceeded(topUp, bound)` retries with the top-up bound at `topUp` if that cap allows it. A revert in the build is widened and simulated once more in the same block; one in the pipeline's simulation leaves a hint for the account's next build. The widened bounds are ceilings: `minPayout`, taken from the simulation of the widened call, still holds the loss to 101 % of the simulated one, and the reservation covers the larger of the two bounds. `InsufficientProceeds` and `NoRouteAvailable` page `M-10`; `AddressIsFrozen` stops the chain's helper and pages `M-24`; `NotLiquidatable`, stale prices, `PayoutTooLow`, `MinOutNotMet` and `LockHeld` keep no state, because the next block re-reads the account and its gates.
- Follow-up (`chain/submit.ts`, `followUp`): in every block a pending transaction is re-simulated. Mined: release. Still succeeding before its deadline: replace at the same nonce with both fee fields +15 %, through the same private endpoints. Past its deadline and still due: rebuild from a fresh preview at the same nonce. Past its deadline and no longer due: a zero-value transfer from the signer to itself at that nonce after 2 blocks. A nonce handed back for a rebuild that no pass used within 2 blocks is closed the same way.
- Nonces (`chain/nonce.ts`): one lock per signer; reset from the provider at startup, after a reorg and after `nonce too low`.
- Reorgs (`Submitter.onReorg`): a transaction seen mined is kept until its block is finalized. When a reorg leaves its nonce unconsumed at the new head it returns to pending (under `subject@nonce` if a newer transaction of the same subject is pending), its reservation is restored without a balance check (the funds it pulled are back in the Safe) and the account's in-flight flag is set again; the follow-up then replaces it, rebuilds it past its deadline or cancels it.
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
