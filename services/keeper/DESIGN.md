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
4. **Jobs**, each through the pipeline below: liquidation, `settlePending`, oracle pokes, breaker and configuration pokes, and the gas vault top-up.
5. **Follow-ups** of pending transactions (`chain/submit.ts`, `runtime/submitter.ts`).
6. **Block-cadence alerts** (`monitoring/`), each page confirmed on the fallback provider at `B`: `M-09` per account; `M-16`, the funding Safe's balance of each debt asset less open reservations, against the largest single `debtToCover` the chain's caps allow (`KEEPER_LARGEST_DEBT_TO_COVER_<CHAIN>`, from each listing's REQ-FLASH-008 sizing; 150 % warns, 100 % pages; an asset without one warns); `M-17`, the helper's `maxFlashLoan` of each debt asset against the same size (2x / 1x) and the signer's gas balance against its daily spend (3 days / 1 day), the spend being the median of the measured daily balance decreases over 7 days, never below `KEEPER_GAS_DAILY_SPEND_WEI_<CHAIN>` (`monitoring/funding.ts`); `M-33`, the standby signer's balance against its minimum (warn). Before them, `M-31` and `M-32` from the spend log (`runtime/budget.ts`, see Fees). A failed read is logged (`keeper.fundingCheck`) and the pass ends normally.
7. **Heartbeat**: the head is reported processed to the monitoring service.

## Monitoring service

Every alert is a `keeper.alert` log line and, with `KEEPER_MONITOR_URL` set, is also posted to the monitoring service (`adapters/monitorSink.ts`): `POST /v1/keeper/alerts` as this chain's instance (`KEEPER_MONITOR_INSTANCE_<CHAIN>`, one of the monitor's `MONITOR_KEEPER_INSTANCES`) with its bearer token (`KEEPER_MONITOR_TOKEN_<CHAIN>`), and `POST /v1/keeper/heartbeat` with each processed head. The monitor holds an alert open while it keeps arriving and resolves it two blocks after the last one; an instance whose heartbeat falls 3 blocks behind pages its on-call engineer. Posting runs in the background and never delays a pass: a failed post keeps its lines (up to 1,000, oldest dropped first) and is retried on the next alert or heartbeat, an outage is logged once (`keeper.monitorSink`), and lines the monitor refuses (422) are logged and dropped. An alert raised outside a pass (the gas ceiling) carries the last processed head.

`M-10` is judged per market: a revert in the keeper's simulation counts once per account per hour in its market (1 account warns, 3 page; `InsufficientProceeds` and `NoRouteAvailable` page at once), and is sent with the subject `market:<marketId>`, the account and reason in the detail (`monitoring/m10.ts`). A single account that keeps reverting is `M-09`'s to escalate. `RouteFailed` events and the share of collateral seized are counted by the monitor from chain events.

## The pipeline

Every job implements `Job` (`types.ts`) and runs through `runJob` (`pipeline.ts`):

| Step | What it does | Where |
|---|---|---|
| Discover | Candidates from the cache or the manifest; cached values only choose what to read | `jobs/*.discover` |
| Live check | Re-reads eligibility at `B` through a reader pinned to `B` | `jobs/*.check`, `chain/reads.ts` |
| Build | Calldata, deadline, reservations and the code-check targets | `jobs/*.build` |
| Code check | ERC-1967 slot of every upgradeable target, runtime code hash of every immutable one, against the manifest; a mismatch moves the instance to observe-only and pages `M-26` | `safety/guards.ts` |
| Simulate | `eth_call` and `estimateGas` at `latest` from the signer; a failing simulation is logged with its decoded revert and never sent | `runtime/submitter.ts` |
| Confirm | A liquidation's account read again on the fallback provider at `B`; not below HF 1 there (or not readable) skips it as `hfNotConfirmed` | `runtime/chainLoop.ts` (`confirm`) |
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
5. Funding split between the flash loan and inventory, the top-up bound, then one `eth_call` of `flashLiquidate` with `minPayout = 0` at `B` to measure the net result, and the request's `minPayout` from it (99 % of a profit, or at most 101 % of a loss). The call is inventory-only (`flashAmount = 0`, which only the operator helper accepts; the Safe prefunds `debtToCover + maxShortfall`, no premium, no top-up) when the Aave V3 Pool's implementation is not the manifest's (flash funding stops, paged once as `M-26`; the Pool then leaves the call's code-check targets), when a route of the market into the debt asset draws on the reserve the loan would borrow (a `dependencies()` entry that is its aToken, or whose `asset()` or `aToken()` is), or when the loan would round to zero (no idle liquidity, a dust repayment).
6. No swap calldata: the helper calls `LPVaultSwap.liquidate`, which holds the routes.

## Fees

Avana pays its keepers' gas from the `feeRecipient` treasury Safe, in lump sums to each signer (primary and standby, per chain), or, where the chain's AvanaGasVault is deployed (manifest `avana.gasVault`), in lump sums to the vault, which refills the signers. The fee rules keep that cost low without slowing anything urgent.

**Gas top-up** (`jobs/gasTopUp.ts`). Each block the keeper reads the vault's view of its own signer. When the vault lists the signer, its balance is below its `minBalance` and `quoteTopUp` is above 0, it sends `topUpAll()`, which refills every listed signer below its minimum (the standby too) within each one's 24-hour cap. The call is permissionless and pays only listed signers, so it goes through the same code check and simulation as any job; it is `urgent` because a signer that runs dry stops every other job. A paused vault, a used-up cap or an empty vault is logged (`conditionFalse`) and left to the monitor's `M-35` and `M-36` and the signer's own `M-17`. With `minBalance` at 3 days of the daily spend, the top-up falls due in the block in which `M-17` would first warn.

**Classes.** Every `TxPlan` carries the `JobClass` its job declares (`types.ts`); the fee rule is `classFees` in `chain/gas.ts`, with each chain's `FeePolicy` from `config.ts`:

| Class | Jobs | Tip | Max fee | When |
|---|---|---|---|---|
| `urgent` | liquidation; breaker or configuration poke whose simulation returned non-zero; oracle poke while the oracle is not Live that would change its stored state; the gas vault's `topUpAll()` | 90th percentile of the last 5 blocks, at least `KEEPER_MIN_TIP_URGENT_<CHAIN>` (1 gwei by default: today's rule) | 2 × base + tip | next block |
| `scheduled` | checkpoint and feed-round oracle pokes | `KEEPER_MIN_TIP_SCHEDULED_<CHAIN>` | 2 × base + tip | decided `POKE_LEAD_SECONDS` (60 s) before the interval ends |
| `lazy` | `settlePending` | `KEEPER_MIN_TIP_LAZY_<CHAIN>` while the base fee is at most `KEEPER_LAZY_BASEFEE_MAX_<CHAIN>`; otherwise waits up to `KEEPER_LAZY_MAX_WAIT_<CHAIN>` seconds from when it first fell due, then scheduled fees | 2 × base + tip | hours |

The defaults (`defaultFeePolicy`) are lower on an OP Stack chain (Base), whose base fee is a few thousandths of a gwei; they are starting points, replaced by the inclusion-delay measurement (a scheduled poke must land inside the 60 s lead in at least 99 % of trials). The tips may not rise from urgent to lazy, so a non-urgent transaction never outbids a liquidation. The per-transaction ceiling (`KEEPER_GAS_CEILING_WEI_<CHAIN>`) applies to every class, a replacement raises a pending transaction's fees by 15 % whatever its class, and a liquidation still pre-empts a pending poke at the higher of its urgent fees and the poke's bumped fees. A lazy transaction that waits is logged `skipped` with `lazyBaseFeeHigh`.

**Budgets.** `runtime/budget.ts` keeps a rolling 24 h spend log per chain: after each included transaction the follow-up reads its receipt and records gas used × effective gas price plus the L1 data fee (Base), the class, and the market and Hub its subject names (market → CDP Spoke from the manifest, Spoke → Hub from `MarketRegistry.hubOf`, read once per Spoke); the `included` line of the attempt log carries the same fields. When the scheduled or lazy class reaches `KEEPER_DAILY_BUDGET_WEI_{SCHEDULED,LAZY}_<CHAIN>` (default 3 and 1 times `KEEPER_GAS_DAILY_SPEND_WEI_<CHAIN>`), it stops sending (`budgetReached`) and `M-32` pages at every head until older spend leaves the window. Urgent is never budget-limited. `M-31` warns when the 24 h spend of every class passes 3× the median daily spend of the last 7 complete days (never below the expected daily spend) and pages above 5×. The log is in memory: a restart starts a new window. `metrics.ts` reports the spend per class and per Hub, and the gas spent per Hub on liquidations whose reward `Kr` (`LiquidationSettled.report.keeperReward`, valued in wei from the debt asset's accepted price and `KEEPER_NATIVE_USD_FEED_<CHAIN>`) was below their gas cost (small-account spend; no alert).

**Send on change.** Liquidations, and oracles that are not Live, are checked every block; the instance's own status, pending settlement, breaker and configuration pokes, the gas vault, the scheduled oracle pokes and the funding reads are checked every `KEEPER_SLOW_JOB_SECONDS` of block time (60 s; 0 checks them every block), and scheduled pokes are sent that much earlier so they still land inside their interval. The funding alerts found at a check are posted again at every block until the next one. The reads of one pass are issued together and travel as Multicall3 `eth_call`s (`chain/client.ts`); simulations of state-changing calls are never batched. A transaction is sent only when it would change state. Breaker and configuration pokes are sent on a non-zero simulated result (above). While an oracle is not Live (`getPriceState().state` is not 0), or right after it was, `jobs/oraclePoke.ts` pokes it only when the poke would emit a timer, latch, grace, state or route event: the logs of an `eth_simulateV1` of the poke at the block decide; where a provider lacks the method, the poke counts as a change when the state it would store differs from the one stored at this instance's last poke, or when the oracle's report read right after the poke differs from the one right before it, both in one `eth_call` through Multicall3. A disagreement held for an hour costs one urgent poke, not one per block; a restart costs at most one more. Converting keeper profits from `FUNDING_SAFE` into gas is a manual treasury decision; nothing does it automatically.

## Retries and errors

- Fees (`chain/gas.ts`, see Fees): urgent tip = 90th percentile of the last 5 blocks' priority fees, at least 1 gwei by default; max fee = 2 × base fee + tip; gas limit ⌈1.3 × estimate⌉ + 25,000 (`@avana/services-common/gas`): `estimateGas` at `latest` runs at that block's timestamp, so a call touching a Hub asset already accrued in that second skips the accrual it pays when mined a second later.
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
