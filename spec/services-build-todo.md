# Services build to-do (josue-todo.md section 2.8)

Working list for the off-chain services, in build order: indexer → export → Convex → keeper → frontend import → tests. Temporary: deleted when section 2.8 closes. Each item names its acceptance criteria and the spec IDs it implements. The agent working on the services re-checks this list after each round and ticks only what passed its criteria.

Agreed data path: contracts and events → Ponder + PostgreSQL → private versioned export → Convex → frontend. The frontend never queries Ponder; live contract reads verify current state and every action.

## What exists (scaffolding, 2026-11-11)

| Path | Contents |
|---|---|
| `services/common/` | `@avana/services-common`: chains, env names, manifest view with ABI-hash check, provenance keys, export wire types |
| `services/indexer/` | Ponder project: `ponder.config.ts` (chains and sources from manifests), `ponder.schema.ts` + `src/schema/`, handlers per area, export endpoint with HMAC auth; [EVENTS.md](../services/indexer/EVENTS.md) (event and live-read catalogue), [EXPORT.md](../services/indexer/EXPORT.md), README (provenance, reorgs, checkpoints) |
| `services/keeper/` | Pipeline, jobs (liquidation, `settlePending`, oracle pokes, breaker and config pokes), safety (kill switch, guards, code check), chain I/O (pinned reads, gas, nonce lock, KMS signer, private send, follow-ups), discovery (cache, chunked backfill, head watchdog), monitoring signals M-01…M-26; [DESIGN.md](../services/keeper/DESIGN.md) |
| `services/convex/README.md` | Convex import design: scheduled pull, durable checkpoints, duplicate protection, block-hash checks, atomic page updates, reorg rebuild |

Nothing is installed or built yet; versions are pinned in each `package.json` (Ponder 0.18.2, viem 2.57.11, Hono 4.13.13, TypeScript 6.0.3, Vitest 4.1.12, tsx 4.23.15, `@aws-sdk/client-kms` 3.1156.0, `@types/node` 22.20.5; Node ≥ 22.12).

## 0. Workspace and shared package

- [ ] **Root workspace.** Root `package.json` (private, `BUSL-1.1`) with npm workspaces `packages/*`, `services/*`, `apps/*` and one lockfile; `.nvmrc` 22. *Accept:* `npm install` from the root resolves every pinned version; `npm run typecheck -ws` passes in `services/common`.
- [ ] **`packages/protocol` TypeScript exports.** `@avana/protocol/abis` generated from the release build: one `as const` ABI per Avana contract (`aaveAdapterAbi`, `proxyManagerAbi`, `collateralizationAbi`, `lpVaultAbi`, `vaultTokenAbi`, `vaultTokenFactoryAbi`, `lpVaultSwapAbi`, `payoutEscrowAbi`, `lpOracleAbi`, `debtOracleAbi`, `marketRegistryAbi`, `parameterStoreAbi`, `riskModuleAbi`, `avanaTimelockAbi`, `coverageSpokeAbi`, `flashLiquidatorAbi`, `lensAbi`), the Aave ABIs from `contracts/out-aave/ISpoke.sol/ISpoke.json` and `IHub.sol/IHub.json` (`aaveV4SpokeAbi`, `aaveV4HubAbi`), and `ABI_HASH`. *Accept:* the generator is deterministic; `--check` fails on drift; the hash equals the manifest's. IDs: `TEST-149`, `Q-073`.
- [ ] **Manifest schema covers the services view.** Every field of `ServiceManifest` (`services/common/src/manifest.ts`) exists in the manifest JSON Schema: implementation addresses, code hashes, start blocks, operator helpers with signer and funding Safe, per-market integration ID, feeds with heartbeats and routes, per-reserve DebtOracle and feeds, Aave V3 Pool and GHO flash minter. *Accept:* the shared fork environment writes a manifest that `loadManifest` accepts. IDs: `TEST-004`, `TEST-149`.

## 1. Indexer (`services/indexer/`)

- [ ] **Install, codegen, typecheck.** *Accept:* `ponder codegen` and `tsc --noEmit` clean; `ponder dev` starts against the fork manifest and reaches `/ready`.
- [ ] **Every event of EVENTS.md handled.** *Accept:* a fork run emits each event at least once and each produces its `event_log` row and table change; Ponder refuses to start if a registered name is missing from an ABI. IDs: `TEST-061`, `Q-076`.
- [ ] **Attribution.** Accounts attributed only when `UserProxyCreated` and `ProxyDeployed` agree; Spoke events of unattributed users logged only; `LiquidationCall.liquidator` never used. *Accept:* `TEST-144` passes, including a proxy announced by one source only. IDs: `TEST-144`, `LIQ-056`, `Q-222`, `Q-212`, `Q-404`.
- [ ] **Provenance.** Block hash and log index on every row an event writes. *Accept:* a replay compares every row's `lastBlockHash` with RPC. IDs: `TEST-061`, `TEST-143`.
- [ ] **Timelock expiry and refresh list.** `expiresAt = readyAt + GRACE_PERIOD`; the list of proxies for the DAO's `updateUserRiskPremium` payload. *Accept:* fork test of an expired operation; the list equals every attributed proxy with collateral on the Spoke. IDs: `REQ-ACCESS-108`, `Q-145`.
- [ ] **Reorgs and reindex.** *Accept:* injected Anvil reorgs leave tables equal to a clean run; a full reindex from start blocks finishes in under one hour on the fork history. IDs: `TEST-143`.
- [ ] **Keeper event feed.** An authenticated head-depth endpoint (`GET /keeper/v1/events?chainId&afterBlock`) for the keeper's live updates, same HMAC scheme as the export, rows from `event_log` with block hashes (decision in [Open questions](#open-questions-for-josue), Q-S1). *Accept:* the keeper's cache equals the indexer's account set at a pinned block. IDs: `REQ-LENS-004`.
- [ ] **History endpoint.** `GET /export/v1/history?chainId&wallet&before&limit` as in EXPORT.md, backed by a wallet index on attributed activity. *Accept:* returns the same records as the export for that wallet, newest first.

## 2. Private versioned export

- [ ] **Endpoint.** `GET /export/v1/pages` as in EXPORT.md. *Accept:* pages close at block boundaries, never pass `min(finalized, indexed − 1)`, recompute to the same `pageHash`, and refuse unsigned, expired or wrongly signed requests. IDs: `TEST-143`.
- [ ] **Network exposure.** The export listens only on the private interface; no GraphQL or SQL route is mounted. *Accept:* a deployment check that probes `/graphql` and `/sql` gets 404.

## 3. Convex (`apps/backend/convex/ingest/`, design in `services/convex/README.md`)

- [ ] **New production deployment** and environment variables (export URL, HMAC key ID and secret, RPC URLs per chain).
- [ ] **Tables, pull action, `applyPage` mutation.** *Accept:* duplicate, overlapping and out-of-order pages and a page with a tampered record or hash leave the same state as a clean run. IDs: `TEST-143`.
- [ ] **Block-hash checks and reorg rebuild.** *Accept:* an indexer pointed at a different branch is detected on the next pull and the rebuild restores a clean-run state.
- [ ] **Views and live reads.** Market and portfolio views with debt, interest and health factor read over RPC at a stated block. *Accept:* each displayed value carries its block; none comes from the export. IDs: `REQ-ARCH-140`, `TB-042`.
- [ ] **Intents and transaction progress.** Intent ID and status only; receipt tracking with `included` → `pending` on reorg; `indexed` when the export delivers the same `txHash`. IDs: `TEST-145`, `Q-149`, `Q-106`.

## 4. Keeper (`services/keeper/`)

- [ ] **Install and typecheck.** *Accept:* `tsc --noEmit` clean.
- [ ] **Unit tests of the pure rules.** `liquidationRules.ts` (candidate, market gate, preview gate, debt reserve choice, deadline, route mode, funding split, top-up bound, `minPayout`), `gas.ts`, `nonce.ts` (lock, reuse, resync), `submit.ts` (`followUp` table), `inventory.ts`, `shard.ts`, `alerts.ts`. *Accept:* every row of the services/README.md rules and examples reproduced, including the 1,950 USDC and dust-account examples. IDs: `TEST-141`, `Q-336`, `Q-345`, `REQ-SWAP-074`.
- [ ] **Observe-only mode and fork replay.** *Accept:* with no signer, a fork depeg run logs every call it would send and a replay of each logged call succeeds. IDs: `TEST-140`, `MKT-025`.
- [ ] **Liquidation duty.** *Accept:* on a fork depeg every HF < 1 account is liquidated, dust accounts included, successive calls until HF ≥ 1, no debt or deficit recorded. IDs: `TEST-142`, `Q-381`, `Q-395`.
- [ ] **Flash helper paths.** Flash-funded, inventory-funded and split calls; GHO from the flash minter on Ethereum, other assets from the Aave V3 Pool. *Accept:* fork tests listed in services/README.md (Tests before launch). IDs: `REQ-HELPER-001`…`REQ-HELPER-015`.
- [ ] **`settlePending`, oracle pokes, breaker and config pokes.** *Accept:* pending units settle once the price passes the gates; every oracle is poked on each new round and at least once per heartbeat; `pokeBreakers` and `pokeConfig` are sent exactly in the blocks whose simulation returns non-zero. IDs: `Q-199`, `Q-248`, `EMG-035`, `EMG-053`, `REQ-RISK-090`, `REQ-RISK-091`.
- [ ] **Safety.** Kill switch refuses unauthenticated requests and survives a restart; a code mismatch set with `anvil_setStorageAt` moves the instance to observe-only and pages `M-26`; a frozen helper stops and pages; an unregistered helper keeps liquidating. IDs: `Q-219`, `REQ-SWAP-105`, `REQ-SWAP-107`, `Q-404`.
- [ ] **Keys.** AWS KMS signer: low-s signatures that recover to the key's address; no key material in env, files or images. IDs: `Q-245`.
- [ ] **Discovery.** Indexer feed plus RPC backfill over both providers, union kept and differences alerted; reconnect backfill from the last finalized block; 10-minute sweep. *Accept:* a dropped stream recovers without losing an event. IDs: `REQ-LENS-004`.
- [ ] **Standby and sharding.** *Accept:* failover drill: with every primary stopped, the standby liquidates each account within the `M-09` warning window. IDs: `Q-082`, `Q-147`.
- [ ] **Monitoring signals M-01…M-26.** Block-cadence signals evaluated by the keeper; event, daily-fork and external signals by the monitoring service from the indexer and RPC; every page confirmed on the second provider. IDs: `EMG-075`, `Q-244`.
- [ ] **Public failure log** published from the `keeper.attempt` lines.

## 5. Frontend import (`apps/web/`)

- [ ] Import about 80 % of the sandbox: Swap homepage, detail pages, portfolio and dashboard, Lend, languages, currencies, preferences; connect to the production Convex API; the wallet signs and submits. Multiply and Umbrella later. *Accept:* `TEST-145`…`TEST-148` pass; no request from the browser reaches the indexer. IDs: `TEST-146`, `TEST-147`, `TEST-148`, `INV-022`.

## 6. Tests across the services

- [ ] Keeper fork tests against the Sepolia and fork deployments (`TEST-140`…`TEST-142`).
- [ ] Ponder replay and reorg job in CI; Convex duplicate and reorg tests (`TEST-143`, `TEST-144`).
- [ ] ABI-hash refusal in web, indexer and keeper (`TEST-149`).
- [ ] End-to-end fork run: pledge → borrow → price drop → keeper liquidation → indexer → export → Convex → UI.

## Blocked on contracts

The services read these through generated ABIs, so each item becomes final when its contract passes its gate in `contracts-build-todo.md`.

| Contract | What the services need that is not final |
|---|---|
| 13 CL pricing library and CL LPOracle | The CL implementation's ABI (the LPOracle source follows `MarketRegistered.lpOracle`, so every child decodes with it); `ILPOracleCL.getClPriceState` and `PriceStateView.tokens` for `M-05` and the app's range display; `POKE_MIN_GAS_FLOOR` calibration, which sets the keeper's gas limit for `poke()` |
| 20 AaveAdapter | The implementation that emits `IAaveAdapterEvents` (event order within a pledge: `ProxyDeployed`, `UserProxyCreated`, then the first supply; `Repaid.debtAfter`; `CollateralSupplied` and `CollateralDisabled` are declared on the Adapter, not the PositionProxy); `proxyOf`, `accountOf`, `walletOf`, `borrowNonce`; ERC-1967 `Upgraded` and role events in its ABI |
| 23 LPVaultSwap | `LiquidationSettled` with the final `SettlementReport` layout; `RouteFailed`, `PendingSettlementForwarded`, `KeeperAdded`/`KeeperRemoved`; `isApprovedKeeper`, `activeKeeperCount`, `getKeepers`; `settlePending(marketId, debtReserveId)`; the revert set the keeper decodes (`RecoveryBelowFloor`, `InsufficientProceeds`, `NoRouteAvailable`, `StalePrice`, `DebtPriceStale`, `PayoutTooLow`, `LockHeld`, `NotLiquidatable`, `AddressIsFrozen`) |
| 24 Avana Umbrella (Coverage Spoke) | `ReserveFunded`, `DeficitCovered`, `WithdrawalExecuted` with `balanceAfter`, and `totalFunded`/`totalCovered` for `M-13`; the file exists, final after its gate |
| 25 Lens | Interface and spec 2.17 disagree on keys; the services follow the interface until the Lens lands: `getPriceState(vaultToken)` (spec: `marketId`), `checkBacking(vaultToken)` (spec: `marketId`), `getPendingSettlement(vaultToken)` (spec: `marketId`), `getTailCoverage(debtAsset)` (spec: `(hub, debtAsset)`), `getEscrowClaimable` (spec: `getInKindClaimable`), `previewRecredit(marketId, positionKey)` (spec: `(integrationId, positionKey)`), `getHubState(hub)` (spec only); `RouteStatus.routeKind` values (the keeper reads 0 as primary); every `LiquidationPreview` field the keeper uses (`aaveLiquidatable`, `pricesUsable`, `debtPriceFresh`, `inGrace`, `belowGraceHealthFactor`, reserve-paused flags, `params`, `expectedDebtRepaid`, `expectedNetPayout`, `expectedCallerLoss`, `routeUsable`) |
| Aave V4 Spoke events | Avana's `IAaveV4Spoke` declares none of `Supply`, `Withdraw`, `Borrow`, `Repay`, `LiquidationCall`, `ReportDeficit`, `SetUsingAsCollateral`; the indexer decodes them, `UpdateUserRiskPremium`, the premium-refresh and configuration events from `out-aave/ISpoke.sol/ISpoke.json`, and `EliminateDeficit` from `IHub.json` (absent from `IHubBase`). `packages/protocol` must export both Aave ABIs (section 0) |

## Open questions for Josue

| # | Question | Options | Recommendation |
|---|---|---|---|
| Q-S1 | How does the keeper get head-depth events from the indexer? | (a) authenticated `/keeper/v1/events` polling endpoint on the indexer; (b) read-only Postgres role on `event_log`; (c) RPC logs only | (a): same auth as the export, no database credentials outside the indexer host; RPC backfill stays as the independent second source |
| Q-S2 | Liquidation when no flash liquidity is available (Pool reserve paused or empty, or the Aave V3 Pool implementation changed) | (a) helper accepts `flashAmount = 0` and pulls `debtToCover` from the Safe; (b) a Safe module lets the signer call `liquidate` from the Safe within bounds; (c) a small inventory on the signer address | (a): one line in the operator helper keeps every call on the committed-operator path with the Safe's outflow already bounded by `MAX_TOP_UP_BPS` logic; today the helper reverts `InvalidFlashAmount` on 0 |
| Q-S3 | `pokeConfig` and `pokeBreakers` cadence: the spec says "every block" | (a) send every block; (b) simulate every block, send only when the result is non-zero | (b): the code writes no state when the result is 0, so the on-chain outcome is identical without a transaction per Spoke and market per block; reword EMG-053 and duty 4 to say so |
| Q-S4 | NFPM and Slipstream position-manager events | (a) not indexed; LPVault events and `Lens.previewRecredit` cover custody and added liquidity; (b) index for held positions only | (a): Ponder cannot filter by `tokenId` dynamically, and indexing every position-manager event on Ethereum would dominate the reindex time; update the README's NFPM row |
| Q-S5 | Export authentication | (a) HMAC-signed requests with rotating keys (as scaffolded); (b) mutual TLS | (a): Convex actions can compute HMAC with Web Crypto; mutual TLS needs a Node action and certificate handling in Convex |
| Q-S6 | Where the export wire types live | (a) `services/common` (as scaffolded); (b) a new `packages/export` used by Convex and the indexer | (b) once the root workspace exists: Convex then imports a package rather than a service folder |
| Q-S7 | Stale lines in services/README.md found while scaffolding | ProxyManager listed as upgradeable in the code check (it is immutable, CREATE2); "BeaconProxy init-code hash" (now `PROXY_CREATION_CODE_HASH`); LPVault event names (`NftReceived`, `LiquidityRemoved` → `PositionReceived`, `UnitsUnwound`); flash funding from the Pool only (GHO comes from the flash minter on Ethereum); `Lens.getPriceState(marketId)` (interface takes the vault token) | Corrected in this round: the event table (now EVENTS.md), the init-code hash, the ProxyManager's place in the code check and the GHO flash minter; `Lens.getPriceState(marketId)` waits for the Lens (contract 25) |

## Decisions (Josue, 2026-11-11)

| ID | Decision |
|---|---|
| Q-S1 | Authenticated polling endpoint `GET /keeper/v1/events` on the indexer, versioned, never the database schema. It serves resumable cursors, block hashes and an explicit indexed-head watermark; head events are provisional and support rewind and reconciliation after a reorg. The keeper keeps an independent RPC backfill for gaps and outages: indexer downtime never stops discovery or liquidation. Indexer events only name candidates; live contract checks and a simulation authorize each send, and periodic account checks catch accounts made liquidatable by interest or price with no borrower action. The keeper head feed is separate from the finalized Convex export (shared authentication only); the keeper never waits on the app's finality pipeline. |
| Q-S2 | The operator helper accepts `flashAmount = 0` and pulls the whole repayment from the keeper Safe, whose outflow is already bounded, so every call stays on the committed-operator path. Contract change, tracked in `contracts-build-todo.md`. |
| Q-S3 | `pokeConfig` and `pokeBreakers` are simulated every block and sent only when the result would change state (a zero result writes nothing). EMG-053 and keeper duty 4 are reworded to match. |
| Q-S4 | Held positions only: a targeted ingestion worker tracks position-manager events (liquidity increases and decreases, collections, transfers) for NFTs in Avana custody, using indexed `tokenId` topic filters over RPC. Keyed by chain + position-manager address + `tokenId`; on custody entry the NFT is registered and backfilled from its entry block; on exit, events through the exit transaction are processed, tracking stops and history stays; events are deduplicated and block hashes reconciled after reorgs. Its tables sit apart from Ponder-managed tables and both reach the versioned export. Ponder's indexed-argument filters are not assumed to support a token-ID list that changes during indexing. Live reads still refresh liquidity, collectable fees, composition, debt and health (fees accrue through pool swaps with no collection event). |
| Q-S5 | HMAC-signed requests with rotating keys, as scaffolded. Convex pulls through internal actions and mutations, alongside the app's existing wallet sign-in (SIWE to JWT, wallet identity from authenticated claims). |
| Q-S6 | Export wire types move to a new `packages/export` once the root workspace exists; `services/common` holds them until then. |
| Q-S7 | No decision: `Lens.getPriceState` follows the Lens (contract 25). |

## Re-check log

- 2026-11-11: scaffolding written; nothing installed or compiled (memory constraint for this round). Next round starts at section 0.
