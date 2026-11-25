# services

Off-chain services that read the chain and act on it. No service is trusted by the contracts: every on-chain check uses only on-chain data read in the same transaction, and every service re-checks what it indexes against RPC before acting.

Data path: contracts and their events → Ponder indexer with PostgreSQL → private versioned export → Convex → frontend. The indexer keeps the full history and the hourly chart series; Convex reads current values from the chain every 30 s and serves the app; live contract reads verify wallet state and every action. The frontend never queries the indexer.

| Path | Contents |
|---|---|
| `indexer/` | Ponder indexer with a Postgres database: Avana and Aave events for the app, the keeper, monitoring and DAO refresh payloads, an hourly sampler of every Hub asset, Spoke slice, market and account, and the series of every listed market's pool. [EVENTS.md](indexer/EVENTS.md) lists every event, sample and live read; [EXPORT.md](indexer/EXPORT.md) specifies the private export |
| `keeper/` | The bot runner: hosts the LiquidationBot (`packages/liquidator/`) for every integration of a chain's release manifest. [DESIGN.md](keeper/DESIGN.md) |
| `convex/` | The Convex backend the app reads ([README](convex/README.md)): rows by scope (Hub asset, Spoke slice, CDP debt reserve, market), chart series, listing content, the frontend fee quote, and the import of the export. The frontend fee is 10 bps of every app action (never above the 25 bps ceiling of the ARFC; for pledge and withdraw collateral, of the position's oracle USD value, paid in the debt stablecoin), rounded down and added as one transfer to the action's batch; it goes to the RiskModule's `feeRecipient`, which the app reads on chain, and the app drops the fee leg if its simulation shows that transfer would revert. No contract charges it, and keeper liquidations pay none |
| `common/` | `@avana/services-common`: chains, environment names, the manifest view the services read, provenance keys, the export and series wire types, and the chain snapshot (`/views`): its rows by scope, the reader that fills them at one block, and their integer math |

The indexer and the keeper read addresses and start blocks from the verified release manifest named in their configuration and ABIs from [`packages/protocol`](../packages/protocol/), check the manifest's ABI hash against the hash of those ABIs at startup and refuse to run on a mismatch.

## Build and test

`services/common`, `services/indexer`, `services/keeper`, `services/convex` and `packages/protocol` form one npm workspace. Its root is the repository's [`package.json`](../package.json), with a single `package-lock.json` beside it; `@avana/services-common` and `@avana/protocol` are linked from the workspace with `file:` and never fetched from a registry. Node is the version in [`.nvmrc`](../.nvmrc) (22.18.0) and every direct dependency is pinned to an exact version.

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
| `services/keeper` | The bot runner's pass (stream or RPC accounts, one LiquidationBot per integration, nothing sent while halted, `M-09`, `M-10`, `M-16`), the bot stream client (signing, paging, reorg, failure), configuration (secrets from files, all-or-none sets) and the monitor sink |
| `packages/protocol` | `ABI_HASH` matches the committed ABIs; no selector collision inside an ABI |

The [`services`](../.github/workflows/services.yml) workflow runs the same steps for each package on every pull request and push to `main` that touches these packages, the workspace manifests or `.nvmrc`. Before installing it fails if any `@avana/` dependency is not a `file:` or `workspace:` link or the lock file resolves one from a registry; the `gate` job passes only when every package passed.

## Scopes

A chain has several Aave V4 Hubs (on the local deployment three: GHO, USDC and USDT on each). Each Hub has one or more supply-only Lend Spokes and its CDP Spokes (one per AMM protocol), each (Hub, debt asset) its First-Loss Reserve and, behind it, possibly the Aave DAO's deficit offset (a Spoke whose `FIRST_LOSS_LAYER()` is that First-Loss Reserve, the second loss layer). The services start from the Hubs and Spokes of the release manifest and add, at every read, each Hub the RiskModule has registered and each CDP Spoke it has approved since; on a Hub that no manifest Lend Spoke supplies, a Spoke shaped like a Lend Spoke (not CDP, not Coverage, not a deficit offset, not the fee receiver, with an add cap and no draw cap) is read as its Lend Spoke. A Hub, Spoke or market listed on chain therefore shows up, with its data and series, without a code or configuration change. The services keep every number at the scope that owns it:

| Scope | Key | Owns |
|---|---|---|
| Hub | chain, Hub | Label (from the manifest), tier, recorded flag, application state, its Lend and CDP Spokes; its totals are the sum of its Hub assets |
| Hub asset | chain, Hub, assetId | Added, owed (drawn + premium), liquidity, deficit, rates, rate curve, reserve factor, every Lend Spoke reserve on it and the price of the first one's oracle, coverage and the deficit offset's funds |
| Spoke slice | chain, Hub, assetId, Spoke | One Spoke's added, owed, deficit and caps on that asset |
| CDP debt reserve | chain, Spoke, reserveId | The reserve's flags and debt price; its Hub asset is joined, never copied |
| Collateral market | chain, integrationId, marketId | Pool, range, vault token, accepted price, collateral value, collateral factor, collateral risk, cap headroom; per debt reserve the market's borrow rate |
| Market debt | chain, integrationId, marketId, Spoke, reserveId | Debt the market's accounts owe in that reserve |
| Account | chain, Spoke, proxy | One wallet's position in one market |

A Lend page is one Hub asset; the same token on two Hubs is two Hub assets with two pages, and the Lend totals add the Hub assets of every Hub while the per-Hub breakdown keeps them apart. A Borrow asset page is one CDP Spoke's slice of the same Hub asset, read from the same row; a pool page is one market. The identities that tie them, checked on fixture data by the tests:

- Per Hub asset, Σ CDP slices' owed = the Hub's owed, up to one base unit per Spoke (each Spoke rounds up); only CDP Spokes draw.
- Σ slices' added = the Hub's added (Lend Spoke + First-Loss Reserve + deficit offset + fee receiver), each rounding down.
- What a market can borrow now of one debt reserve is `min(⌊market window room × 10^dec / price⌋, (Hub, asset) window room)`, and more frees up at the earlier of the two windows' next expiry. Example: market room $250,000 and USDC at $0.9999 give 250,025.0025 USDC when the (Hub, USDC) window has more room.
- added + accrued fees = liquidity + owed + deficit: "available" is the Hub's liquidity, never added − owed.
- What a Spoke can draw is `min(drawCap − owed − deficit, liquidity)`, and all CDP Spokes together `min(Σ cap room, liquidity)`.
- Σ over a CDP Spoke's markets of the debt they back = the Spoke's owed amount, up to one unit per account.

Every row of one read carries its block, so the indexer's hourly sampler and Convex's 30-second refresh, which run the same reader (`@avana/services-common/views`), produce rows for which these identities hold exactly.

## Running against a manifest

Both services take every address from the release manifests listed in `AVANA_MANIFEST` (the indexer: comma-separated, one per chain, with the network set from `INDEXER_NETWORK_SET`; the bot runner: one chain's manifest): `production` (Ethereum, Base) and `testnet` (Sepolia, Base Sepolia) load manifests from `contracts/deployments/verified/`; `local` (anvil, chain 31337) loads a rehearsal manifest from `contracts/deployments-local/<network>/manifest.json` and is never used for a published deployment. A manifest for a chain outside the set is ignored, and a set with no manifest stops startup.

```bash
# Rehearsal on a local anvil node, after contracts/script/e2e/e2e-local.sh (or its deploy and manifest steps):
export AVANA_MANIFEST=$PWD/contracts/deployments-local/anvil/manifest.json
export RPC_ANVIL=http://127.0.0.1:8545 RPC_ANVIL_FALLBACK=http://127.0.0.1:8545 RPC_ANVIL_WS=ws://127.0.0.1:8545
(cd services/indexer && INDEXER_NETWORK_SET=local npx ponder start)       # PGlite store; production uses DATABASE_URL
(cd services/keeper && LIQUIDATION_BOT_RPC_URL=http://127.0.0.1:8545 LIQUIDATION_BOT_CHAIN_ID=31337 LIQUIDATION_BOT_KEYSTORE=... KEEPER_HALT_STATE_PATH=/tmp/halt.json npx tsx src/main.ts)
```

`contracts/script/e2e/services-smoke.sh <manifest>` runs both on a manifest with throwaway kill-switch certificates and checks that the indexer reaches `/ready` and the bot runner serves its metrics while halted. It then starts a fresh local Convex deployment of `services/convex` (`CONVEX_AGENT_MODE=anonymous npx convex dev`, no account), points it at the indexer's export and at the rehearsal's listing metadata files (`contracts/deployments-local/<network>/listing-content/`, served as `LISTING_CONTENT_URL`), writes the deployment row from the manifest, imports the export and samples the chain; every listed market's pool page and every debt reserve's asset page must then show its on-chain numbers and the text of the listing metadata file its listing operation committed to. The manifest is produced and verified with `npm run manifest` in `packages/protocol` ([`contracts/deployments/README.md`](../contracts/deployments/README.md)); the services refuse a manifest that does not match the release manifest schema (`@avana/protocol/manifest/schema`, every error listed) or whose ABI hash differs from `@avana/protocol`'s.

## Containers

[`Dockerfile`](Dockerfile) builds one image per long-running service from the repository root (`--target indexer` or `keeper`): the workspace's locked dependencies and the TypeScript sources, run as the `node` user with tsx or Ponder, as in CI. No secret, manifest or state is baked in: configuration comes from each service's `.env.example` names, manifests and certificates from read-only mounts, state files from a `/data` volume. Convex is not containerized: `services/convex` deploys to Convex. The one-host compose file, the monitor and the faucet are operator software and are not in this repository.

## Indexer (`indexer/`)

### Events

Every borrower or keeper action is one atomic transaction in which each contract emits its own events. Every event the indexer handles, with its key, table and consumers, is in [EVENTS.md](indexer/EVENTS.md), generated from the interfaces under `contracts/src/` and the pinned Aave V4 ABIs.

Rules:

- Spoke events are attributed only to account proxies the AaveAdapter reported (`AccountCreated`: wallet, market, account).
- Only the LiquidationModule can receive seized vault tokens, so every Avana liquidation emits `Liquidated` and `FeePaid`; `liquidate` is open to every address.
- A `Repaid` whose payer is not the account's wallet is a valid third-party repay.
- Stored debt shares and index snapshots are historical. Displayed health factors and bot decisions always re-read RPC at a known block.
- Start blocks come from the deployment receipts in the manifest. A full reindex completes in under one hour.

### Finality and reorgs

Each consumer has a named finality setting in its service configuration: the indexer and the keeper follow the chain head; Convex ingests exports at `finalized`. When a reorg removes a block, the indexer rolls back to the common ancestor and replays, and an intent that Convex had marked `included` returns to `pending`.

The reorg replay replays a fork run and compares the indexer's state with RPC reads at the same block, including injected Anvil reorgs and duplicate or out-of-order export pages; every case must leave the same state. It runs against the shared fork environment and needs a deployment manifest from it, so no workflow runs it yet: CI checks the services with the typecheck and unit tests above.

## Bot runner (`keeper/`)

The bot runner hosts Avana's own bots against one chain's release manifest; today the **LiquidationBot** of `packages/liquidator/` (step 8), one instance per AMM integration. [keeper/DESIGN.md](keeper/DESIGN.md) maps the process onto the code and explains the naming: **LiquidationBot** is the liquidation logic (`LIQUIDATION_BOT_*` settings), **keeper** is the generic bot-running infrastructure (`KEEPER_*` settings, the image, the monitor feed) and the contracts' own word for the bots the RiskModules register (`addKeeper`; with no keeper registered, borrowing stops).

- **Duties.** Liquidate every account below health factor 1 in every market of every integration, whether or not the bonus pays (a committed operator), in kind through `LiquidationModule.liquidate`, with the bot's own funds or through the `FlashLiquidator`'s Aave V3 flash loan (premium-free once the Aave DAO grants `FLASH_BORROWER`).
- **Discovery.** `AaveAdapter.AccountCreated` from the indexer's bot stream ([indexer/EXPORT.md](indexer/EXPORT.md#keeper-stream)), or the bot's own RPC scan while the stream fails. Every decision re-reads the chain.
- **Keys.** An encrypted Foundry keystore and its password file; nothing secret in the environment (`LIQUIDATION_BOT_*` refuses a variable named like a key or password). The keystore's address is the `FlashLiquidator`'s `OPERATOR` and the keeper the RiskModules register.
- **Safety.** The mutual-TLS kill switch halts sending at once and persists across restarts; every transaction is simulated first; the flash path's `minProfit` is the simulated profit less `LIQUIDATION_BOT_PROFIT_SLIPPAGE_BPS`, and a sale that falls short is topped up only up to `LIQUIDATION_BOT_MAX_TOP_UP`.
- **Monitoring.** The runner posts `M-09`, `M-10` and `M-16` and a heartbeat per pass to the monitor; the monitor reads the keeper wallets' gas itself (`M-35`).
- **Gas.** Each keeper wallet is refilled from the keeper top-up wallet (`keeperTopUp` in the deploy config, or `KEEPER_TOPUP_WALLET`) by deploy step `11-fund-keepers` when it falls below `minBalanceWei`; `M-35` warns when the step is due.

Configuration: [keeper/.env.example](keeper/.env.example). Run: `npm start -w @avana/keeper`; the bot alone, without the runner: `npm start -w @avana/liquidator`.

### Gas funding runbook

Each keeper wallet (the RiskModules' keepers and the FlashLiquidators' operators) is funded from the keeper top-up wallet (`keeperTopUp.wallet` in the deploy config, or `KEEPER_TOPUP_WALLET`) by `contracts/script/deploy` step `11-fund-keepers`: a wallet below `keeperTopUp.minBalanceWei` is refilled to `targetBalanceWei`, and the step is safe to rerun.

- **Keeper wallet low (`M-35` warn, below `minBalanceWei`).** Run `11-fund-keepers`. If it pages (below a third of the minimum), run it now and find out why the warn was not acted on.
- **Top-up wallet low (`M-35` warn, below one full refill of every keeper).** Treasury refills the top-up wallet.
- **Liquidation proceeds.** The LiquidationBot keeps the pool tokens of a direct liquidation and the profit of a flash liquidation in its own wallet; converting them is a manual treasury decision.

### Tests

`npm test -w @avana/keeper` (the runner's pass, stream client, configuration and monitor sink) and `npm test -w @avana/liquidator` (the LiquidationBot's decision, pass, settings and signer); the FlashLiquidator's Solidity tests run in `packages/liquidator/` with `forge test -j 2`.

## Monitoring and alerting

The signal list below is what the keeper and the app are built against. The paging service that raises them is operator software and is not in this repository.

| # | Signal | Warn | Page | Responder | Playbook |
|---|---|---|---|---|---|
| M-01 | A market's LPOracle refusing to price (`latestAnswer` reverts when an Aave V4 price source of either token answers 0 or reverts): the Spoke cannot price the collateral | — | every | operators, then the Emergency Guardian | P-02 |
| M-02 | Feed disagreement start. Retired: the stateless LPOracle records no disagreement, so nothing raises it | — | — | operators, then the Emergency Guardian | P-02 |
| M-03 | Age of the Aave V4 price sources every market's LPOracle reads (`LPOracle.reserveIds`, `AaveOracle.getReserveSource`, recorded in the manifest with its heartbeat) | past the heartbeat | past 1.5 heartbeats | operators | P-02 |
| M-04 | Debt feed age, against the feed's heartbeat in the manifest | past the heartbeat | past 1.5 heartbeats | operators, Aave | P-02 |
| M-05 | USD band distance. Retired: M-36 watches the Custom band edge | — | — | guardians | P-03 |
| M-06 | Collateral value per market at oracle prices | −10 % in 1 hour | −25 % in 1 hour | guardians | P-03 |
| M-07 | Live pool share. Retired: the new core has no pool-share breaker | — | — | risk service providers | P-04 |
| M-08 | Breakers. Retired: the new core has none; a frozen market or debt reserve is M-24 | — | — | guardians | per reason |
| M-09 | Accounts below HF 1 not liquidated (LiquidationBot reports); a bot runner instance whose heartbeat falls 3 blocks behind | 60 s | 300 s, or a silent bot runner | standby keeper, keeper on-call, guardians | P-08 |
| M-10 | Liquidation failures the LiquidationBot reports per market; the share of a market's collateral seized (`LiquidationModule.Liquidated`) | 1 failure per market per hour; 10 % seized in 1 hour | 3 per market per hour; 20 % seized in 1 hour | governance, guardians | P-04 |
| M-11 | Route depth at stress size. Retired: liquidation is in kind, there are no swap routes | — | — | governance | P-04 |
| M-12 | GSM exposure headroom. Retired with the swap routes | — | — | risk service providers | P-04 |
| M-13 | First-Loss Reserve balance against its `minimum()`; DAO deficit offset balance against its minimum | a reserve below 150 %; the offset below 100 % | a reserve below 100 % | Avana Labs top-up; Aave DAO top-up of the offset | P-09 |
| M-14 | Draw-cap coverage: the First-Loss Reserve's balance against Σ `RiskModule.coverage(hub, asset).required` | below 150 % | below 100 % (borrowing stops: `CoverageBelowRatio`) | risk service providers, Aave DAO | P-09 |
| M-15 | Hub deficit per asset | any | uncovered after 24 hours (coverage window 72 hours) | coverage role holder (the Aave governance executor unless the loss-layers AIP names another caller) | P-09 |
| M-16 | A liquidatable account the LiquidationBot cannot fund (no balance of the debt asset and no flash path) | — | every | Avana Labs, keeper on-call | P-09 |
| M-17 | Keeper gas balance. Retired: M-35, read by the monitor | — | — | Avana Labs | P-08 |
| M-18 | `drawn / drawCap` per asset | 80 % | 90 % | risk service providers | P-10 |
| M-19 | Hub utilization and Lend Spoke withdrawals | utilization 90 % | utilization 98 %, or a withdrawal above 10 % of supply within 1 hour | Aave DAO, guardians | P-10 |
| M-20 | Aave configuration events of every CDP Spoke (reserve and dynamic config, liquidation config, price source, position manager, authority, upgrade) | any change | — | Emergency Guardian | P-12 |
| M-21 | Backing check. Retired: no Collateralization or Lens in the new core | — | — | engineering | P-05 |
| M-22 | Avana AccessManager: `OperationScheduled`; `RoleGranted`, `RoleRevoked`, `TargetFunctionRoleUpdated`, `TargetClosed` | an operation scheduled | a role or function role changed, a target closed | every canceller | P-06 |
| M-23 | Safe owner, threshold, guard or module change; signer liveness | every | every; liveness answers below threshold + 1 | every signer | P-07 |
| M-24 | A market's vault-token reserve or a debt reserve frozen, paused or reopened on its Spoke (a depeg's response is a freeze) | every | — | every signer | per reason |
| M-25 | Token issuer: `paused()`, `basisPointsRate()`, blocklist events naming Avana contracts | probe change; a blocklist naming another Avana contract | a blocklist naming an LPVault, AaveAdapter, LiquidationModule or FlashloanRepay | guardians | P-11 |
| M-26 | Keeper code-check mismatch. Retired: the bot runner calls immutable contracts | — | — | keeper on-call | P-08 |
| M-27 | Frontend bundle hash, DNS and hosting change | any | hash mismatch | engineering | P-13 |
| M-28 | Liquidity leaving a listed pool: the pool's total liquidity (and its liquidity around the current price) per listed market, independent of Avana's share | −20 % in 1 hour | −40 % in 1 hour | risk service providers, guardians | P-04 |
| M-29 | Rate curve per lend asset: the Hub's interest-rate data and drawn rate; for GHO, `baseDrawnRate` against the Core Hub GHO base rate | any change of a curve's values | GHO `baseDrawnRate` below the Core Hub GHO base rate | Aave DAO, risk service providers | P-10 |
| M-30 | Keeper discovery mismatch. Retired with the old keeper | — | — | keeper on-call | P-08 |
| M-31 | Keeper gas spend anomaly. Retired with the old keeper | — | — | Avana Labs, keeper on-call | P-08 |
| M-32 | Keeper class budget reached. Retired with the old keeper | — | — | keeper on-call, Avana Labs | P-08 |
| M-33 | Standby keeper signer balance. Retired: M-35 | — | — | Avana Labs | P-08 |
| M-34 | Oracle poke overdue. Retired: the stateless oracles are never poked, so nothing raises it | — | — | keeper on-call, operators | P-08 |
| M-35 | Keeper wallet gas balance (the RiskModules' keepers and the flash liquidators' operators) and the keeper top-up wallet (`keeperTopUp`, `KEEPER_TOPUP_WALLET`), against the refill rule of `11-fund-keepers` | a keeper wallet below `minBalanceWei`; the top-up wallet below one full refill | a keeper wallet below a third of `minBalanceWei` | Avana Labs, keeper on-call | P-08 |
| M-36 | Band edge: a Custom range market's pool tick against its band (fixed for life) | within 10 % of the band's width from an edge | outside the band | risk service providers, guardians | P-03 |
| M-37 | Depeg above 1 % on a Stable or Correlated pair: the pool price against the LPOracle's fair price, or a Stable token's Chainlink price below $0.99. Response: freeze the market's vault-token reserve | depegged and already frozen | depegged while the reserve is open | Emergency Guardian, guardians, risk service providers | P-03 |

Rules:

- Pages reach both the governance Safe and the Emergency Guardian signers and the Aave Protocol Guardian contact; warns reach the on-call engineer and the named responder.
- Every signal is read from on-chain state at a known block, re-checked against a second RPC source before paging, and stored with the block number in the incident log.
- The app sends each borrower health alerts at the levels that borrower chooses, and shows the state of each of their markets in plain language: price state, a frozen or paused reserve and what still works.
- The app's Lend page shows each lender, per (Hub, asset), the supply rate, the borrow rate the asset's utilization curve sets, the utilization and idle liquidity it can withdraw now (`M-19` uses the same reads), and any deficit left by both loss layers (the Avana First-Loss Reserve, then the DAO Deficit Offset) with the backed value per share; while a deficit stays uncovered (`M-15`) it alerts every lender of that (Hub, asset), builds no new supply into it, keeps withdrawals open, and before each withdrawal shows the backed value per share beside the price Aave will pay, with the plain statement that Aave pays withdrawals in full first-come while liquidity lasts and the last lenders hold the unbacked claims until a loss layer is refilled.


## Licence

The indexer, keeper and shared code are Avana code under the Business Source License 1.1 in the root [`LICENSE`](../LICENSE) (`"license": "BUSL-1.1"` in each `package.json`). Their npm dependencies (viem, ponder, hono and the build and test tools) keep their own licences, listed in [`docs/licenses/THIRD_PARTY_LICENSES.md`](../LICENSES/THIRD_PARTY_LICENSES.md#packages).
