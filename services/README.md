# services

Off-chain services that read the chain and act on it. No service is trusted by the contracts: every on-chain check uses only on-chain data read in the same transaction (`REQ-ARCH-140`), and every service re-checks what it indexes against RPC before acting.

Data path: contracts and their events → Ponder indexer with PostgreSQL → private versioned export → Convex → frontend. The indexer keeps the full history and the hourly chart series; Convex reads current values from the chain every 30 s and serves the app; live contract reads verify wallet state and every action. The frontend never queries the indexer.

| Path | Contents |
|---|---|
| `indexer/` | Ponder indexer with a Postgres database: Avana and Aave events for the app, the keeper, monitoring and DAO refresh payloads, an hourly sampler of every Hub asset, Spoke slice, market and account, and the series of every listed market's pool. [EVENTS.md](indexer/EVENTS.md) lists every event, sample and live read; [EXPORT.md](indexer/EXPORT.md) specifies the private export |
| `monitor/` | The monitoring service: the signals `M-01` to `M-29` below, routed to their responders, pages confirmed on a second provider, keeper alerts and heartbeats ingested. [README](monitor/README.md) lists the signals wired so far |
| `keeper/` | Avana's liquidation keeper, run as primary and standby instances on each chain, including observe-only mode. [DESIGN.md](keeper/DESIGN.md) maps the rules below onto its code |
| `convex/` | The Convex backend the app reads ([README](convex/README.md)): rows by scope (Hub asset, Spoke slice, CDP debt reserve, market), chart series, listing content, the frontend fee quote, and the import of the export. The frontend fee is 10 bps of every app action (never above the 25 bps ceiling of the ARFC; for pledge and withdraw collateral, of the position's oracle USD value, paid in the debt stablecoin), rounded down and added as one transfer to the action's batch; it goes to the ParameterStore's `feeRecipient`, which the app reads on chain, and the app drops the fee leg if its simulation shows that transfer would revert. No contract charges it, and keeper liquidations pay none |
| `common/` | `@avana/services-common`: chains, environment names, the manifest view the services read, provenance keys, the export and series wire types, and the chain snapshot (`/views`): its rows by scope, the reader that fills them at one block, and their integer math |

The indexer, the keeper and the monitoring service read addresses and start blocks from the verified release manifest named in their configuration and ABIs from [`packages/protocol`](../packages/protocol/), check the manifest's ABI hash against the hash of those ABIs at startup and refuse to run on a mismatch (`TEST-149`).

## Build and test

`services/common`, `services/indexer`, `services/keeper`, `services/monitor`, `services/convex` and `packages/protocol` form one npm workspace. Its root is the repository's [`package.json`](../package.json), with a single `package-lock.json` beside it; `@avana/services-common` and `@avana/protocol` are linked from the workspace with `file:` and never fetched from a registry. Node is the version in [`.nvmrc`](../.nvmrc) (22.18.0) and every direct dependency is pinned to an exact version.

```bash
npm ci --ignore-scripts                        # at the repository root: installs every package, runs no install scripts
(cd services/indexer && npm run codegen)       # writes ponder-env.d.ts, the types of Ponder's virtual modules
npm run typecheck                              # tsc --noEmit in each package
npm run test                                   # vitest run in each package
npm run test -w services/keeper                # one package
```

| Package | Unit tests |
|---|---|
| `services/common` | Manifest loading (ABI-hash refusal, exact bigint IDs), environment reads, chain lookup, provenance keys and ordering; series buckets, merge rules and gap filling; Hub accounting identities on the fixture snapshot, cap room and shared liquidity, rate conversions; the snapshot reader against a scripted multicall |
| `services/indexer` | Factory events match the generated ABIs and decode the child address; every log-only event exists in its contract's ABI; export authentication (signature, key rotation, clock skew); the snapshot reader's ABI fragments against the generated ABIs; pool series aggregation |
| `services/convex` | Spoke slices reconcile to the Hub totals the Lend page shows; the frontend fee (10 bps on each action, the 25 bps ceiling, the LP-value basis, rounding down) and fee + gas totals; chart buckets and quick stats; export page checks, request signing and listing metadata hashes; activity feeds by page |
| `services/monitor` | Signal catalog against this README; snapshot rules at their boundaries; alert lifecycle, routing and its refusals; PagerDuty and webhook payloads and retries; second-provider confirmation of pages; keeper ingest and heartbeats; one round end to end; configuration refusals |
| `services/keeper` | Liquidation decision and sizing rules at their boundaries; the pipeline sends only after a successful simulation with every guard passing, pages `M-26` on a code mismatch and logs observe-only calls |
| `packages/protocol` | `ABI_HASH` matches the committed ABIs; no selector collision inside an ABI |

The [`services`](../.github/workflows/services.yml) workflow runs the same steps for each package on every pull request and push to `main` that touches these packages, the workspace manifests or `.nvmrc`. Before installing it fails if any `@avana/` dependency is not a `file:` or `workspace:` link or the lock file resolves one from a registry; the `gate` job passes only when every package passed.

## Scopes

A chain has several Aave V4 Hubs (on the local deployment three: GHO, USDC and USDT on each). Each Hub has one or more supply-only Lend Spokes and its CDP Spokes (one per AMM protocol), each (Hub, debt asset) its First-Loss Reserve and, behind it, possibly the Aave DAO's deficit offset (a Spoke whose `FIRST_LOSS_LAYER()` is that First-Loss Reserve, the second loss layer), and a CDP Spoke may draw on another Hub's asset through a Hub-to-Hub credit line. The services start from the Hubs and Spokes of the release manifest and add, at every read, each Hub the MarketRegistry has recorded and each CDP Spoke it has approved since; on a Hub that no manifest Lend Spoke supplies, a Spoke shaped like a Lend Spoke (not CDP, not Coverage, not a deficit offset, not the fee receiver, with an add cap and no draw cap) is read as its Lend Spoke. A Hub, Spoke or market listed on chain therefore shows up, with its data and series, without a code or configuration change. The services keep every number at the scope that owns it:

| Scope | Key | Owns |
|---|---|---|
| Hub | chain, Hub | Label (from the manifest), tier, recorded flag, application state, its Lend and CDP Spokes; its totals are the sum of its Hub assets |
| Hub asset | chain, Hub, assetId | Added, owed (drawn + premium), liquidity, deficit, rates, rate curve, reserve factor, every Lend Spoke reserve on it and the price of the first one's oracle, coverage and the deficit offset's funds |
| Spoke slice | chain, Hub, assetId, Spoke | One Spoke's added, owed, deficit and caps on that asset |
| Hub-to-Hub credit line | chain, funding Hub, assetId, Spoke | The registry's cap for a CDP Spoke whose home Hub is another one, and the funding Hub's total of such caps; the draw is the Spoke slice |
| CDP debt reserve | chain, Spoke, reserveId | The reserve's flags, debt price and breaker; its Hub asset is joined, never copied |
| Collateral market | chain, marketId | Pool, range, vault token, accepted price, collateral value, collateral factor, collateral risk, cap headroom; per debt reserve the market's borrow rate and what it can borrow now under the speed limits and when more frees up (`Lens.getBorrowSpeed`); the pledge-speed window (`Lens.getPledgeSpeed`) |
| Market debt | chain, marketId, Spoke, reserveId | Debt the market's accounts owe in that reserve |
| Account | chain, Spoke, proxy | One wallet's position in one market |

A Lend page is one Hub asset; the same token on two Hubs is two Hub assets with two pages, and the Lend totals add the Hub assets of every Hub while the per-Hub breakdown keeps them apart. A Borrow asset page is one CDP Spoke's slice of the same Hub asset, read from the same row; a pool page is one market. The identities that tie them, checked on fixture data by the tests:

- Per Hub asset, Σ CDP slices' owed = the Hub's owed, up to one base unit per Spoke (each Spoke rounds up); only CDP Spokes draw, a CDP Spoke of another Hub on a credit line included.
- Σ slices' added = the Hub's added (Lend Spoke + First-Loss Reserve + deficit offset + fee receiver), each rounding down.
- What a market can borrow now of one debt reserve is `min(⌊market window room × 10^dec / price⌋, (Hub, asset) window room)`, and more frees up at the earlier of the two windows' next expiry. Example: market room $250,000 and USDC at $0.9999 give 250,025.0025 USDC when the (Hub, USDC) window has more room.
- added + accrued fees = liquidity + owed + deficit: "available" is the Hub's liquidity, never added − owed.
- What a Spoke can draw is `min(drawCap − owed − deficit, liquidity)`, and all CDP Spokes together `min(Σ cap room, liquidity)`.
- Σ over a CDP Spoke's markets of the debt they back = the Spoke's owed amount, up to one unit per account.

Every row of one read carries its block, so the indexer's hourly sampler and Convex's 30-second refresh, which run the same reader (`@avana/services-common/views`), produce rows for which these identities hold exactly.

## Running against a manifest

Both services take every address from the release manifests listed in `AVANA_MANIFEST` (comma-separated, one per chain) and the network set from `INDEXER_NETWORK_SET` / `KEEPER_NETWORK_SET`: `production` (Ethereum, Base) and `testnet` (Sepolia, Base Sepolia) load manifests from `deployments/verified/`; `local` (anvil, chain 31337) loads a rehearsal manifest from `contracts/deployments-local/<network>/manifest.json` and is never used for a published deployment. A manifest for a chain outside the set is ignored, and a set with no manifest stops startup.

```bash
# Rehearsal on a local anvil node, after contracts/script/e2e/e2e-local.sh (or its deploy and manifest steps):
export AVANA_MANIFEST=$PWD/contracts/deployments-local/anvil/manifest.json
export RPC_ANVIL=http://127.0.0.1:8545 RPC_ANVIL_FALLBACK=http://127.0.0.1:8545 RPC_ANVIL_WS=ws://127.0.0.1:8545
(cd services/indexer && INDEXER_NETWORK_SET=local npx ponder start)       # PGlite store; production uses DATABASE_URL
(cd services/keeper && KEEPER_NETWORK_SET=local KEEPER_MODE=observe ... npx tsx src/main.ts)
```

`contracts/script/e2e/services-smoke.sh <manifest>` runs both on a manifest with throwaway kill-switch certificates and checks that the indexer reaches `/ready` and the keeper serves its metrics in observe mode. It then starts a fresh local Convex deployment of `services/convex` (`CONVEX_AGENT_MODE=anonymous npx convex dev`, no account), points it at the indexer's export and at the rehearsal's listing metadata files (`contracts/deployments-local/<network>/listing-content/`, served as `LISTING_CONTENT_URL`), writes the deployment row from the manifest, imports the export and samples the chain; every listed market's pool page and every debt reserve's asset page must then show its on-chain numbers and the text of the listing metadata file its listing operation committed to. The manifest is produced and verified with `npm run manifest` in `packages/protocol` ([`deployments/README.md`](../deployments/README.md)); the services check its ABI hash against `@avana/protocol` and refuse a mismatch.

## Indexer (`indexer/`)

### Events

Every borrower or keeper action is one atomic transaction in which each contract emits its own events (`Q-076`). The indexer stores them under four keys (`TEST-061`):

| Entity | Key |
|---|---|
| Account | `chainId + Spoke + proxy` |
| Collateral record | `chainId + Collateralization + recordId` |
| Debt reserve | `chainId + Spoke + debtReserveId` |
| Log | `txHash + logIndex` |

Every event the indexer handles, with its indexed fields, the table it updates and the consumers that read it at each depth, is in [EVENTS.md](indexer/EVENTS.md), generated from the interfaces under `contracts/src/` and, for the Aave V4 Spoke and Hub, from the Aave ABIs at the pinned commit.

Rules:

- Spoke events are attributed only to proxies created by the verified ProxyManager and reported by the AaveAdapter (`ProxyDeployed`, `UserProxyCreated`, both naming the same wallet, Spoke and market); the ProxyManager's `PROXY_CREATION_CODE_HASH` is in the manifest.
- `LiquidationSettled` is valid whoever the caller is: `liquidate` is the one entry point and is open to every address, so the indexer never requires the `caller` field to be a registered committed operator (`Q-404`). A `Repaid` whose payer is not the proxy's borrower is a valid third-party repay (`Q-212`).
- The Borrow Spoke admits only LPVaultSwap to `liquidationCall` (`Q-222`), so every `LiquidationCall` event has `liquidator == LPVaultSwap`; the indexer still attributes Spoke events by proxy, not by the liquidator field (`LIQ-056`).
- Expiry of a timelock operation emits no event; the indexer derives it from `getTimestamp(id) + GRACE_PERIOD` (`REQ-ACCESS-108`).
- Stored debt shares and index snapshots are historical. Displayed health factors and keeper decisions always re-read RPC at a known block.
- After an upgrade, events are decoded with the ABI that was live for each block range.
- Start blocks come from the deployment receipts recorded in the manifest. A full reindex completes in under one hour, and the schema is not changed while the application is Frozen or Paused.
- The indexer supplies the list of every PositionProxy that the Aave DAO's refresh payloads pass to `updateUserRiskPremium` after a `collateralRisk` change (`Q-145`).

### Finality and reorgs

Each consumer has a named finality setting in its service configuration: the indexer and the keeper follow the chain head; Convex ingests exports at `finalized`. When a reorg removes a block, the indexer rolls back to the common ancestor and replays, and an intent that Convex had marked `included` returns to `pending`.

The reorg replay of `TEST-143` and `TEST-144` replays a fork run and compares the indexer's state with RPC reads at the same block, including injected Anvil reorgs and duplicate or out-of-order export pages; every case must leave the same state. It runs against the shared fork environment and needs a deployment manifest from it, so no workflow runs it yet: CI checks the services with the typecheck and unit tests above.

## Keeper (`keeper/`)

Avana's keeper liquidates every Avana account whose health factor falls below 1, on every chain, whatever the account's size. Avana pays its gas, there is no minimum debt or minimum repayment, and no liquidation waits for a keeper profit (`Q-381`, `Q-395`). Avana's keeper is the committed operator of each chain: its primary instances and a standby instance on independent infrastructure. Each chain's LPVaultSwap keeps a registry of committed operators (the keeper list), at least `keeperFloor` = 1 and at most `MAX_KEEPERS` = 32 (`Q-400`); the registry gates no call, so any address can liquidate, and it feeds the borrowing halt at zero active committed operators and monitoring (`Q-404`).

### Funding and the flash liquidation helper

`LPVaultSwap.liquidate`, the one liquidation entry point, is caller-funded: it pulls `debtToCover` of the debt asset from `msg.sender`, measured by balance delta, and takes no flash loan. Flash funding sits in a periphery contract, the flash liquidation helper ([2.11](../spec/02-contracts/11-lpvaultswap.md#flash-liquidation-helper)):

- It is immutable and holds no funds or allowances between transactions.
- It flash-borrows every debt asset, GHO included, from the chain's Aave V3 Pool, its only lender (`flashLoan`, one asset, mode 0). Its callback accepts only that Pool as caller and itself as initiator, and only the asset, amount and calldata hash recorded in a single-use context before the loan, with a premium no higher than the caller's maximum and `maxFlashFeeBps`.
- It calls LPVaultSwap, receives `keeperOut`, repays the flash principal and premium from it (pulling at most the top-up bound from its payer when `keeperOut` falls short), reverts unless the net payout meets the request's `minPayout`, and only after `flashLoan` returns sends the rest to its recipient.
- It has no swap step. The unwind and the swap routes stay in LPVaultSwap, so the keeper never builds swap calldata.

One public helper instance serves any address. Each keeper instance has its own operator helper, bound at deployment to that instance's signer and funding Safe, which refuses every caller except its signer and bounds each top-up. LPVaultSwap sees the helper as its caller, so the per-instance helper addresses are what the registry lists as Avana's committed operator; registration changes no call. The Pool premium is 5 bps at launch, and 0 if Aave grants the helper `FLASH_BORROWER`. LPVaultSwap's own flash source serves only a borrower's `deleverage`.

### Duties

1. **Liquidate.** Liquidate every account with HF < 1 through the instance's helper and `LPVaultSwap.liquidate`, with either route mode, one debt reserve per call, with successive calls until the account is at HF ≥ 1, has no debt, or has its deficit recorded. Accounts with zero collateral are skipped: the Spoke has already reported their deficit.
2. **Registry and freeze.** A helper that is not, or not yet, registered (after a removal or during a rotation) keeps liquidating: the registry gates no call (`Q-404`). A frozen helper is a guardian decision: the keeper stops submitting from it and pages, and does not route around the freeze through the public helper, although LPVaultSwap would accept that (`REQ-SWAP-105`).
3. **Pending settlement.** When Collateralization reports pending units for a market (`SeizureReconciled`, `getPending`), call `LPVaultSwap.settlePending(marketId, settlementReserve(marketId))` once the market's price passes the liquidation gates. It pays the caller nothing; the proceeds fund the market's First-Loss Reserve.
4. **Oracle and breaker pokes.** Call `poke()` on every LPOracle and DebtOracle on each feed update and at least once per feed heartbeat, so cached prices, first disagreement observations, the hourly checkpoint and the grace latch are stored (`Q-199`, `Q-248`). Every block, simulate `RiskModule.pokeConfig(spoke)` for every CDP Spoke and `RiskModule.pokeBreakers(marketId)` for every market, and send a transaction only when the simulated call changes state: `pokeConfig` finds a drift (so `ConfigDriftDetected` is emitted on-chain and `M-20` pages), or `pokeBreakers` finds a reason holding (so `recordBreach` stores the breach time or latches a security freeze). A block with nothing to record sends nothing (`Q-382`).
5. **Deleverage is not a keeper duty.** A borrower starts a repay with collateral through the AaveAdapter's `repayWithCollateral`, which calls `LPVaultSwap.deleverage` with the core flash source. The keeper never calls it.
6. **Public failure log.** Reverted transactions emit no events, so the keeper publishes every failed, replaced and cancelled attempt with its block, parameters and revert reason.

### Discovery and caching

The unit is one PositionProxy: one wallet in one market on one CDP Spoke, keyed `chainId + Spoke + proxy` as in the indexer. Per account the keeper caches the wallet, Spoke, market, vault token, the debt reserves with non-zero debt, the last health factor with its block, and an in-flight flag.

- **Live updates** come from the indexer's stream of the events listed under [Events](#events): `UserProxyCreated` and `ProxyDeployed` add accounts; `CollateralAdded`, `Borrowed`, `Repaid`, `CollateralWithdrawn`, `LiquidationSettled` and the Spoke's `Supply`, `Borrow`, `Repay`, `Withdraw`, `LiquidationCall` and `ReportDeficit` refresh an account; `PriceStateChanged`, `DebtPriceStateChanged` and `GraceStarted` refresh a market or debt reserve; `SeizureReconciled` and `PendingSettled` drive `settlePending`; `KeeperAdded`, `KeeperRemoved`, `AddressFrozen` and `AddressUnfrozen` drive the keeper's own status.
- **Startup backfill.** The keeper loads the account set from the indexer at a known block and, independently, reads every `ProxyDeployed` and `UserProxyCreated` log from the manifest's start blocks over a second RPC provider, in 10,000-block chunks halved whenever a provider refuses the range. It keeps the union of both sets and alerts when they differ (`REQ-LENS-004`).
- **Reconnect backfill.** After any reconnect of the indexer stream or an RPC subscription, the keeper re-reads logs from the chain's last finalized block to the head before it processes new blocks, so no event missed during the outage is lost.
- **Full sweep.** Every 10 minutes the keeper re-enumerates proxies from logs over both providers and re-reads each account's debt reserves, which repairs any cache entry a missed or misdecoded event left wrong.

Cached values only choose what to read. Every decision re-reads the chain at a pinned block.

### The liquidatable decision

For each new block `B`:

1. One multicall pinned to `B` reads `Spoke.getUserAccountData(proxy)` for every cached account, `Lens.getPriceState(marketId)` for every market, `Lens.getDebtPriceState(spoke, debtReserveId)` for every debt reserve, the instance's `isApprovedKeeper(helper)`, `isFrozenAddress(helper)` and `activeKeeperCount()`, and the Aave V3 Pool's idle liquidity of each debt asset. Batches hold at most 300 accounts, so each `eth_call` stays under a node's 50,000,000-gas call limit.
2. An account is a candidate when `healthFactor < 1e18` and its collateral value is above 0.
3. **Market gate.** The seized market's `liquidationState` is Live or Drifting; every input is within `liquidationPriceMaxAge` (the feed's heartbeat plus its 1,800 s margin); no feed disagreement pause is active; the chain's sequencer is up. Cached and Expired markets, and a disagreement older than `disagreementPauseMax` (3,600 s), are skipped (`REQ-SWAP-008`). Inside a grace window (`graceDuration` = 1,800 s after a feed recovery, or the sequencer grace period of 3,600 s on Base) only accounts with HF < `graceHealthFactor` (0.95) are candidates.
4. **Debt reserve choice.** Among the account's debt reserves whose price passes (GHO always; another asset when its DebtOracle is Live and within `liquidationPriceMaxAge`), the keeper repays the largest debt value first. A failing price on another reserve never blocks the call, because Aave already values that reserve at its stress price (`Q-247`).
5. **Sizing.** `Lens.previewLiquidation(proxy, debtReserveId, deadline)` at `B` re-evaluates every gate as LPVaultSwap does and returns ready parameters: `debtToCover` from Aave V4's own sizing (target health factor, bonus, dust rule, with a 500 bps margin on a whole-debt close), the expected seizure, the recovery floor, the expected `keeperOut` and the expected rounding gap. A false gate skips the account and records the reason.
6. The account goes to submission if it is in the instance's shard (or past the takeover window) and its in-flight flag is clear.

Examples:

1. An Ethereum market's USDT feed has an 86,400 s heartbeat, so `liquidationPriceMaxAge = 88,200` s. At 88,300 s since the last round the market fails step 3, the keeper sends nothing for it, and monitoring raises `M-03`. The next stored round makes it liquidatable again.
2. Base's sequencer restarts at `t`. At `t + 1,000` an account at HF 0.97 is skipped and an account at HF 0.93 is liquidated; from `t + 3,600` both are.
3. An account owes USDC and GHO and its USDC DebtOracle is Expired. The keeper repays GHO at once; the USDC reserve waits for a fresh USDC price.

### Building the call

The keeper calls its helper with LPVaultSwap's `LiquidationParams` and the helper's request fields (flash amount, maximum premium, top-up bound, net `minPayout`):

| Field | Value |
|---|---|
| `proxy`, `marketId`, `debtReserveId`, `debtToCover` | From the preview, unchanged |
| `routeMode` | `PrimaryThenBackup`, or `BackupOnly` when the preview reports the primary route unusable |
| `minAmounts` | Empty |
| `deadline` | Block `B`'s timestamp plus three blocks: 36 s on Ethereum, 6 s on Base (`REQ-SWAP-074`) |
| `maxShortfall` | 0; raised on a retry after `RecoveryBelowFloor` to the measured floor gap, funded from inventory |
| `params.minPayout` | 0: the helper's net check binds |
| Flash amount | `debtToCover` when the Pool's idle liquidity covers it with 1 % headroom; otherwise the idle liquidity less 1 %, with the rest from inventory, and on Base larger liquidations spread over successive blocks |
| Inventory amount | `debtToCover` minus the flash amount |
| Maximum premium | The helper's `flashPremium` quote for the flash amount |
| Top-up bound | The most inventory the helper may pull to finish the flash repayment: 0 for a profitable call, otherwise at least `premium + expectedCallerLoss − expectedNetPayout` from the preview (`REQ-LENS-029`), within the operator helper's `MAX_TOP_UP_BPS` |
| Request `minPayout` | On the net payout (`Q-345`): the inventory amount plus `⌊0.99 × net⌋`, where `net = keeperOut − debtToCover − premium` from the keeper's simulation of the call at `B`; for a call the simulation shows losing, the inventory amount less 101 % of the simulated loss |

No swap calldata is built: LPVaultSwap holds the routes and sets every leg's minimum from the oracle. Before using the flash path the keeper checks that no swap route of the market draws on the same Aave V3 Pool reserve it is borrowing (for example an ERC-4626 wrapper of that reserve's aToken). If one does, the call is inventory-funded, so the loan cannot take the liquidity the route's leg needs.

Example (Ethereum, USDC/USDT market, USDC debt):

1. At block `B` an account at HF 0.98 owes 10,000 USDC. The market and the USDC reserve are Live.
2. `previewLiquidation(proxy, usdcReserve, t + 36)` returns `debtToCover = 1,950` USDC, the seizure worth `V = 2,047.5` USDC at the oracle, Avana's fee `A = ⌊0.2 × (2,047.5 − 1,950)⌋ = 19.5` USDC, `expectedPayout = 1,950 + 2,047.5 − 1,950 − 19.5 = 2,028` USDC (the 1,950 pulled is returned inside it), `expectedNetPayout = 78` USDC and `expectedCallerLoss = 0`. The remaining 8,050 USDC of debt is above the dust threshold, so no margin applies.
3. The Pool holds far more idle USDC than 1,950, so the flash amount is 1,950 USDC with a premium of `⌈1,950 × 5 / 10⁴⌉ = 0.975` USDC, the inventory amount is 0 and the top-up bound is 0.
4. The simulation at `B` returns `keeperOut = 2,020.8` USDC after route costs, so `net = 2,020.8 − 1,950 − 0.975 = 69.825` USDC and the request's `minPayout = ⌊0.99 × 69.825⌋ = 69.12675` USDC; `deadline = t + 36`; `routeMode = PrimaryThenBackup`.
5. Included at `B + 1`: Aave pulls 1,950 USDC and seizes the units, the routes return `R = 2,040.3` USDC, `A = 19.5` USDC goes to `feeRecipient` and `keeperOut = 2,020.8` USDC goes to the helper. The helper repays 1,950.975 USDC and sends 69.825 USDC to the instance's funding Safe. Routes returning only 2,035 USDC would give `keeperOut = 2,015.5` and a net payout of 64.525 USDC, and the helper would revert with `PayoutTooLow`.

Example (dust account): an account owes 0.78 USDC and its seizure recovers about 0.77 USDC. The preview returns the margined whole debt, `debtToCover = ⌈0.78 × 1.05⌉ = 0.819` USDC. The keeper calls `liquidate` from its funding Safe's inventory with no flash loan (a helper needs a loan of at least one unit); `keeperOut = 0.819 + 0.77 − 0.78 = 0.809` USDC and `minPayout = 0.819 − ⌈1.01 × 0.01⌉ = 0.8089` USDC. Avana's keeper takes the 0.01 USDC loss and the account is closed.

### Submission

- **Simulation.** Every transaction, replacement and cancellation is simulated with `eth_call` against the latest block on the primary RPC provider, and the candidate's health factor is confirmed on the second provider, before it is signed. A failing simulation is never sent. The gas limit is `⌈1.3 × estimateGas⌉ + 25,000` (`@avana/services-common/gas`, the one rule for every service and the app): the estimate runs at the latest block's timestamp, so a call touching a Hub asset already accrued in that second skips the accrual it pays when mined a second later (a Lend Spoke withdraw: 31,185 gas in the same second, 35,837 one second later). LPVaultSwap's payout headroom check reverts an under-gassed call, so the limit is never cut below the estimate. One liquidation of the largest account (16 records) is modelled at 5,150,000 gas (`REQ-SWAP-032`).
- **Private order flow.** On Ethereum every liquidation, replacement and cancellation goes only to private builder endpoints, never to the public mempool (`Q-345`). Base has no public mempool; transactions go to the sequencer endpoint through two independent RPC providers.
- **Nonces.** Each instance has one signer, and one mutex guards nonce allocation, so two concurrent liquidations never take the same nonce. The local nonce is set from the provider's pending count at startup, after every reorg and after any `nonce too low` error.
- **Retries.** While a transaction is pending and before its deadline, the keeper re-simulates it in every block. If it still succeeds and was not included, it is replaced at the same nonce, through the same private channel, with both fee fields raised by 15 %. Once the deadline has passed the transaction can no longer execute. If the account is still liquidatable, the keeper builds a fresh preview and sends it at the same nonce; otherwise, if the nonce was not consumed within 2 blocks, it sends a zero-value transfer to itself at that nonce.
- **Failure reasons.** `NotLiquidatable` clears the account. `StalePrice` and `DebtPriceStale` wait for a fresh price. `PayoutTooLow`, `MinOutNotMet` and `LockHeld` retry with a new preview in the next block. `RecoveryBelowFloor` retries with `maxShortfall` covering the measured floor gap from inventory and raises `M-10`; `TopUpExceeded` retries with a top-up bound covering the measured loss; `InsufficientProceeds` never fires while the caller funds the debt, so it pages as a fault. `NoRouteAvailable` retries every block and pages (P-04). `AddressIsFrozen` stops submissions from that helper and pages.
- **Races.** The in-flight flag stops a second liquidation of the same account in the same instance until the first is mined, replaced or expired. When another caller (any other address or another shard) liquidates first, the keeper's simulation fails or its transaction is not included; the keeper reads the new health factor, clears the flag, releases the reservation and, if the account is still below 1, starts the next call.
- **Gas.** Avana pays gas as an operating cost. On Ethereum the priority fee is the 90th percentile of the last 5 blocks' priority fees (at least 1 gwei) and the max fee is twice the base fee plus that tip. On Base the same rule applies, and the cost estimate adds the L1 data fee from the chain's gas price oracle. A per-chain fee ceiling exists only to stop a fault from draining the gas wallet; reaching it pages the on-call engineer.

### Safety controls

These run in the same cycle as the scan, before every liquidation, `settlePending` and poke call (`Q-219`):

- **Kill switch.** An authenticated halt and resume endpoint (mutual TLS, on a port separate from metrics) stops new submissions at once. The halt survives a restart. A halted keeper keeps scanning and logging as in observe-only mode, and its pending transactions expire at their 3-block deadline.
- **Code check.** At block `B` the keeper reads the ERC-1967 implementation slot of every upgradeable target the call reaches (LPVaultSwap, the AaveAdapter, the MarketRegistry, the ParameterStore, the RiskModule, the market's CDP Spoke, the market's LPOracle and the repaid reserve's DebtOracle) and the runtime code hash of every immutable target (the instance's helper, the ProxyManager, the market's LPVault, Collateralization, the vault token, PayoutEscrow, the market's swap routes into the debt asset, the Lock and the Lens), and compares them with the verified deployment manifest. On any mismatch it stops submitting, pages (`M-26`) and stays in observe-only mode until a verified manifest lists the new code. A proxy's bytecode never changes on upgrade, so only the implementation slot shows one. Avana upgrades wait the 5-day normal delay, which leaves time to publish the manifest, so an announced upgrade does not interrupt liquidation. The keeper also reads the Aave V3 Pool's implementation slot; a change there stops flash funding and sends every call through inventory until the manifest records the new Pool code.
- **Observe-only mode.** A keeper with no signer configured, or one that has stopped on a code-check mismatch, runs the same scan and sizing and logs every call it would send with its parameters; a fork replay shows each logged call would have succeeded (`TEST-140`). Signing is enabled only after this mode has run against the shared fork environment, and each new market is watched in observe-only mode before its activation executes (`MKT-025`).
- **Registry and freeze.** Every block the keeper reads `isApprovedKeeper(helper)`, `isFrozenAddress(helper)` and `activeKeeperCount()`. Registration gates no call: an unregistered helper keeps liquidating and only raises a warning, because it does not count toward `keeperFloor`. A frozen helper stops and pages. An active committed-operator count at the floor raises a warning, because a freeze of the last active one halts new borrowing on the chain while liquidation stays open to every address (`REQ-SWAP-107`).
- **Inventory reservation.** Each pending transaction reserves the inventory amount and top-up bound it may pull, per chain and debt asset. A new call is sized against the balance minus every open reservation, and a reservation is released when its transaction is mined, replaced or expired, so concurrent liquidations never count on the same funds (`Q-336`).

### Keys

- Each instance's signer key lives in a cloud KMS or HSM as a non-exportable secp256k1 key (`Q-245`). The keeper requests signatures over an authenticated channel under its own service identity, and every request is logged. No raw key is ever placed in an environment variable, file or image.
- The signer holds only gas, topped up to 7 days of its median spend. Inventory sits in the instance's funding Safe, which approves the helper for that chain's inventory target; the helper pulls from it only the amounts the call names, and its payout recipient is that Safe. A stolen signer key can only send liquidations whose payouts return to the Safe.
- Rotation: deploy a helper bound to the new signer and switch over at once (the registry gates no call), schedule `addKeeper(newHelper)` (normal delay, 5 days) so the new helper counts toward `keeperFloor`, then `removeKeeper(oldHelper)` (short delay, 12 hours). A suspected compromise is answered by a guardian freeze of the helper address, which no keeper floor blocks, and by revoking the funding Safe's allowance; the other instances keep liquidating.

### Configuration

The keeper and the indexer use the contracts' variable names, `RPC_<CHAIN>`, with a suffix for each extra endpoint of the same chain, so one name means the same endpoint in every part of the repository. Every name is listed, without values, in [`keeper/.env.example`](keeper/.env.example).

| Variable | Meaning |
|---|---|
| `RPC_MAINNET`, `RPC_BASE` | Primary HTTP endpoint of the chain (the same names as `contracts/.env.example`) |
| `RPC_MAINNET_FALLBACK`, `RPC_BASE_FALLBACK` | Second, independent provider; confirms each candidate's health factor and takes over when the primary disagrees on the head |
| `RPC_MAINNET_WS`, `RPC_BASE_WS` | WebSocket endpoint for new heads and logs |
| `RPC_MAINNET_PRIVATE`, `RPC_BASE_PRIVATE` | Private submission endpoints: builder RPCs on Ethereum, the sequencer endpoint on Base; comma-separated when there are several |
| `KEEPER_KMS_KEY_ID_MAINNET`, `KEEPER_KMS_KEY_ID_BASE` | KMS or HSM key ID of the instance's signer; the key itself never enters the environment |
| `KEEPER_SHARD`, `KEEPER_SHARD_COUNT` | This instance's shard index and the number of primaries; unset on the standby |
| `KEEPER_MODE` | `observe` (default: scan, size and log, never sign) or `active` |
| `KEEPER_KILL_SWITCH_PORT`, `KEEPER_METRICS_PORT` | Ports of the authenticated halt endpoint and of the metrics endpoint, which are always different |
| `AVANA_MANIFEST` | Path of the verified manifest of each chain; every address the keeper calls comes from it, never from code or another service |

### Operations

- **Sharding.** Each chain runs several primary instances, each with its own signer and helper, so their nonce streams are independent. An account belongs to shard `keccak256(proxy) mod N`. Any primary takes over an account that its shard has not liquidated within 2 blocks on Ethereum (24 s) or 6 blocks on Base (12 s) after it became liquidatable.
- **Standby keeper.** The standby is registered as a committed operator like the primaries, on a different cloud provider and region, with its own RPC providers, KMS, monitoring and on-call rota. It scans every block and sends for any account still liquidatable after 60 s (5 Ethereum blocks, 30 Base blocks), the `M-09` warning level. This trigger is an operating rule backed by monitoring, not an on-chain rule (`Q-082`, `Q-147`). The standby holds each chain's debt assets before a market's `activateMarket` executes.
- **RPC.** Each instance uses at least two independent providers per chain. Reads for one decision are pinned to one block; when the providers disagree on the head for more than 2 blocks the keeper pages and acts only on the provider that agrees with the indexer.
- **Reorgs.** The keeper follows the chain head and tracks each of its transactions until finalized. When a reorg removes a block, accounts it touched are re-read, removed transactions return to pending with their in-flight flags and reservations, the nonce is re-read from the provider, and the cache rolls back with the indexer to the common ancestor. A removed transaction past its deadline cannot execute again, so the keeper builds a fresh one.
- **Startup.** The keeper checks the manifest's ABI hash and refuses to run on a mismatch (`TEST-149`).

### Monitoring and alerting

Each instance exposes metrics on a port separate from the kill switch: blocks behind head, scan time per block, accounts below HF 1 with their age, in-flight transactions, simulation failures by revert reason, inclusion delay in blocks, replacements and cancellations, gas wallet balance, free and reserved inventory per debt asset, Pool idle liquidity per debt asset, the code-check result and the mode (active, observe-only, halted). Logs are structured and shipped off the host; the failure log of duty 6 is published from them. The monitoring service turns these into the alerts `M-09` (accounts below HF 1 not liquidated), `M-10` (liquidation reverts and route failures), `M-16` (keeper debt-asset float), `M-17` (keeper gas and Pool liquidity) and `M-26` (code-check mismatch). An instance that stops reporting for 3 blocks pages its on-call engineer.

### Tests before launch

- `TEST-140` observe-only mode with fork replay; `TEST-141` sizing and submission from `previewLiquidation`; `TEST-142` the liquidate-every-account duty on a fork depeg, dust accounts included; `TEST-143` reorg replay; `TEST-149` the ABI-hash check ([5.1](../spec/05-verification/01-test-requirements.md)).
- Fork tests of the helper against the deployed Aave V3 Pool: flash-funded, inventory-funded and split calls; a payout below the flash repayment beyond the top-up bound reverts; a net payout below the request's `minPayout` reverts; a call from anyone but the bound signer reverts; the callback refuses a foreign caller, initiator, asset, amount, calldata, a premium above the bound and a second callback in the same transaction.
- Unit tests of the decision rules (price gates, grace, debt reserve choice, zero-collateral skip), the nonce manager (mutex, replacement, cancellation after the deadline), inventory reservation and the failure-reason table.
- Fault tests: a code-check mismatch set on the fork with `anvil_setStorageAt` moves the keeper to observe-only; the kill switch refuses unauthenticated requests and survives a restart; a 1-wei repay and a repay to just under the dust threshold before inclusion still settle (`Q-345`); another address wins the race; a removed or unregistered helper keeps liquidating and a frozen one stops; a Base sequencer outage and grace window; a dropped indexer stream recovers by reconnect backfill.
- A failover drill: stopping every primary on a fork lets the standby liquidate each account within the `M-09` warning window.

## Monitoring and alerting

The monitoring service, run by Avana Labs on the indexer's data and direct RPC reads, raises two alert levels per market and debt asset: **warn** (drift that needs attention) and **page** (a failure that needs action now). Every alert names its responder and the [3.6 Emergency Operations](../spec/03-operations/06-emergency-operations.md) playbook to follow, so no time is spent deciding who acts. Circuit breakers stop new activity by themselves; only people can switch feeds, cover deficits, fund reserves, cancel operations or ask Aave to act, and each alert fires early enough to act inside the 48-hour window caps are sized for (`Q-244`). Every alert is confirmed on-chain within 15 minutes and logged in the incident log (`EMG-075`).

| # | Signal | Warn | Page | Responder | Playbook |
|---|---|---|---|---|---|
| M-01 | LPOracle and DebtOracle price state per market and debt reserve | Cached on entry | Expired | operators, then the Emergency Guardian (standby switch) | P-02 (`EMG-076`) |
| M-02 | Feed disagreement start | on entry | 30 minutes before `disagreementPauseMax` ends | operators, then the Emergency Guardian | P-02 (`EMG-076`) |
| M-03 | Feed leg age, collateral and DebtOracle legs | above 50 % of `feedMaxAge` | above 90 % | operators | P-02 (`EMG-076`) |
| M-04 | Debt feed age | above `borrowPriceMaxAge` | above 90 % of `liquidationPriceMaxAge` | operators, Aave | P-02 (`EMG-076`) |
| M-05 | USD band distance √(q0·q1) | below 0.95 | below 0.90 | guardians | P-03 (`EMG-077`) |
| M-06 | Collateral value per market at oracle prices | −10 % in 1 hour | −25 % in 1 hour | guardians | P-03 (`EMG-077`) |
| M-07 | Live pool share | above 15 % | above 20 % (POOL_SHARE breaker trips) | risk service providers | P-04 (`EMG-078`) |
| M-08 | Any breaker latched or condition true (Lens `getBreakerStatus`, `getDebtBreakerStatus`) | every | any latched security freeze (`reopensAt = type(uint64).max`) | guardians | per reason |
| M-09 | Accounts below HF 1 not liquidated | 60 s (5 Ethereum blocks, 30 Base blocks) | 300 s (25 Ethereum blocks, 150 Base blocks); 3,600 s escalates to an Emergency Guardian decision on a breaker trip | standby keeper, keeper on-call, guardians | P-08 (`EMG-082`) |
| M-10 | Liquidation reverts by reason (`RecoveryBelowFloor`, `InsufficientProceeds`, `NoRouteAvailable`, `StalePrice`, `DebtPriceStale`) in keeper simulation or on-chain; `RouteFailed` events; share of a market's collateral seized | 1 revert or `RouteFailed` per market per hour; 10 % seized in 1 hour | 3 per market per hour; 20 % seized in 1 hour | governance (routes), guardians | P-04 (`EMG-078`) |
| M-11 | Route depth at stress size against `routeDepthThresholdGho` and `buyRouteDepthThresholdGho` (daily fork simulation) | below 120 % | below 100 % | governance | P-04 (`EMG-078`) |
| M-12 | GSM exposure headroom per token | below 2× the market's stress size | below 1× | risk service providers | P-04 (`EMG-078`) |
| M-13 | First-Loss Reserve balance; DAO deficit offset balance | below 150 % of `firstLossReserveMinimum`; the offset below 100 % of `daoDeficitOffset` | below 100 % (monitoring alert only; no breaker reads it, `Q-399`) | Avana Labs top-up; Aave DAO top-up of the offset (`Q-410`) | P-09 (`EMG-083`) |
| M-14 | Tail coverage ratio (`getTailCoverage`, and the live variant from current debt) | below 150 % | below 100 % | risk service providers, Aave DAO | P-09 (`EMG-083`) |
| M-15 | Hub deficit per asset | any | uncovered after 24 hours (coverage window 72 hours) | `COVERAGE_ROLE` holder | P-09 (`EMG-083`) |
| M-16 | Keeper debt-asset float per chain and asset (free inventory after reservations), which funds inventory calls, helper top-ups and shortfall top-ups | below 150 % of the largest single `debtToCover` the caps allow | below 100 % | Avana Labs | P-09 (`EMG-083`) |
| M-17 | Keeper gas balance per signer; Aave V3 Pool idle liquidity per debt asset | gas below 3 days of median spend; idle liquidity below 2× the largest single `debtToCover` | gas below 1 day; idle liquidity below 1× | Avana Labs | P-08 (`EMG-082`) |
| M-18 | `drawn / drawCap` per asset | 80 % | 90 % | risk service providers | P-10 (`EMG-084`) |
| M-19 | Hub utilization and Lend Spoke withdrawals | utilization 90 % | utilization 98 %, or a withdrawal above 10 % of supply within 1 hour | Aave DAO, guardians | P-10 (`EMG-084`) |
| M-20 | Aave configuration against recorded values (collateral factor, bonus, target HF, caps, Spoke implementation) | any change | `ConfigDrift` live | Emergency Guardian | P-12 (`EMG-086`) |
| M-21 | Backing-check failure (`Lens.checkBacking`), `CounterSaturated` | — | every | engineering | P-05 (`EMG-079`) |
| M-22 | Timelock `CallScheduled` | every | role change, upgrade, `setShortDelaySelector`, `setNormalDelay`, `unfreezeAddress`, `restorePriceRoute` | every canceller | P-06 (`EMG-080`) |
| M-23 | Safe owner, threshold, guard or module change; signer liveness | every | every; liveness answers below threshold + 1 | every signer | P-07 (`EMG-081`) |
| M-24 | Pause state and reason, address freeze, standby switch, manual breaker | every | — | every signer | per reason |
| M-25 | Token issuer: `paused()`, `basisPointsRate()`, blocklist events naming Avana contracts | probe change | blocklist of LPVaultSwap, the LPVault, Collateralization or the AaveAdapter | guardians | P-11 (`EMG-085`) |
| M-26 | Keeper code-check mismatch (implementation slot or code hash) | — | every | keeper on-call | P-08 (`EMG-082`) |
| M-27 | Frontend bundle hash, DNS and hosting change | any | hash mismatch | engineering | P-13 (`EMG-087`) |
| M-28 | Liquidity leaving a listed pool: the pool's total liquidity (and its liquidity around the current price) per listed market, independent of Avana's share | −20 % in 1 hour | −40 % in 1 hour | risk service providers, guardians | P-04 (`EMG-078`) |
| M-29 | Rate curve per lend asset: the Hub's interest-rate data and drawn rate; for GHO, `baseDrawnRate` against the Core Hub GHO base rate (`SPEC-HUB-007`) | any change of a curve's values | GHO `baseDrawnRate` below the Core Hub GHO base rate | Aave DAO, risk service providers | P-10 (`EMG-084`) |

Rules:

- Pages reach both the governance Safe and the Emergency Guardian signers and the Aave Protocol Guardian contact; warns reach the on-call engineer and the named responder.
- Every signal is read from on-chain state at a known block, re-checked against a second RPC source before paging, and stored with the block number in the incident log.
- The live tail-coverage variant of `M-14` replaces each token's cap by the debt currently backed by markets holding that token; `M-11` and `M-12` run against a fork of the latest block once a day and before every listing.
- The app sends each borrower health alerts at the levels that borrower chooses, and shows the state of each of their markets in plain language: price state, breaker, pause reason and what still works.
- The app's Lend page shows each lender, per (Hub, asset), the supply rate, the borrow rate the asset's utilization curve sets, the utilization and idle liquidity it can withdraw now (`M-19` uses the same reads), and any deficit left by both loss layers (the Avana Umbrella, then the DAO deficit offset) with the backed value per share from the Lens; while `UncoveredDeficit(hub, asset, amount)` is raised (`M-15`, P-18) it alerts every lender of that (Hub, asset), builds no new supply into it, keeps withdrawals open, and before each withdrawal shows the backed value per share beside the price Aave will pay, with the plain statement that Aave pays withdrawals in full first-come while liquidity lasts and the last lenders hold the unbacked claims until a loss layer is refilled (`Q-410`).


## Licence

The indexer, keeper and shared code are Avana code under the Business Source License 1.1 in the root [`LICENSE`](../LICENSE) (`"license": "BUSL-1.1"` in each `package.json`). Their npm dependencies (viem, ponder, hono and the build and test tools) keep their own licences, listed in [`THIRD_PARTY_LICENSES.md`](../THIRD_PARTY_LICENSES.md#packages).
