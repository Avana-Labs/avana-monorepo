# Convex

The backend the web app reads. This folder is one Convex project (`@avana/convex` in the services workspace): the schema, the public queries of every Lend and Borrow screen, the import of the indexer's [private export](../indexer/EXPORT.md) (`convex/ingest/`), the current-value sampler, the listing metadata load (`convex/listing/`) and the frontend fee quote. Convex never holds a transaction target, receiver, amount or calldata for a protocol action (REQ-ARCH-140); the app builds every call itself and reads wallet values live over RPC.

| Path | Contents |
|---|---|
| `convex/schema.ts` | Tables, one owner per number (below) |
| `convex/markets.ts`, `detailHydration.ts`, `allocation.ts`, `contractAddresses.ts`, `borrow/`, `lend/` | The screens' queries, under the names and shapes the app calls |
| `convex/hubAssets.ts`, `spokeReserves.ts`, `collateralMarkets.ts`, `series.ts`, `marketContent.ts` | The same rows by scope key, and one chart query for every series |
| `convex/prices.ts`, `liquidity.ts` | The app's price layer (Lend Spoke oracle prices) and its liquidity overlay (always empty: rows are live) |
| `convex/frontendFee.ts` | Fee rules and the fee + gas total shown before signing |
| `convex/ingest/` | Export pull, series pull, pool history, current-value sampler, the mutations that apply them |
| `convex/listing/` | Listing metadata: fetch, hash check, store |
| `convex/wallet/`, `kept.ts` | A wallet's accounts and last samples; typed stubs of kept features (rewards, referrals, swap quotes, the in-app assistant) |
| `convex/lib/` | Pure functions the tests run offline: page numbers, charts, fees, metadata, export checks, event decoding |
| `convex/_generated/` | Convex's generated API and types, committed; `npx convex dev` rewrites them |

## Scopes

Each chain has one Aave V4 Hub with a supply-only Lend Spoke (an Aave standard Spoke with `drawCap = 0`), one CDP Spoke per AMM protocol and one Coverage Spoke per (Hub, debt asset). Every number belongs to the narrowest scope that owns it, and is stored once:

| Table | Key | Holds | Pages |
|---|---|---|---|
| `hubAssets` | chain, Hub, assetId | Added, owed (drawn + premium), liquidity, deficit, fees, rates, rate curve, reserve factor, the Lend Spoke's oracle price, coverage | Lend list and page; the Hub block and Hub charts of every Borrow asset page |
| `hubAssetSpokes` | chain, Hub, assetId, Spoke | One Spoke's added, owed, deficit, caps, kind (lend, cdp, coverage, fee receiver) | Lend allocation by Spoke; "borrowed via this Spoke" on a Borrow asset page |
| `spokeReserves` | chain, Spoke, reserveId | A CDP debt reserve's flags, debt price, breaker. No Hub totals | Borrow list asset rows, Borrow asset page |
| `markets` | chain, marketId | A collateral market: pool, range, vault token, accepted price, collateral value, collateral factor, bonus, collateral risk, liquidation config, cap headroom | Borrow list pool rows, pool page |
| `marketReserveDebt` | chain, marketId, Spoke, reserveId | Debt a market backs in one debt reserve, and its borrowers | Pool page "debt backed"; Borrow asset page split by market |
| `positions` | chain, Spoke, proxy | An account's collateral and debt value at the last daily sample | Wallets at risk, borrower lists |
| `series` | scope kind, scope key, resolution, bucket | Every chart point | Every chart |
| `marketContent` | scope, chain, on-chain key | Names, slugs, descriptions, FAQs, history, long text | Every page's text |

The Lend page reads a `hubAssets` row. A Borrow asset page reads its `spokeReserves` row, the `hubAssetSpokes` row of its Spoke and the **same** `hubAssets` row, so the two pages cannot show different supply, liquidity, utilization, rates or rate curve. "Borrowed" is owed (drawn + premium) everywhere; "available" is the Hub's liquidity, bounded on a Borrow asset page by its Spoke's cap room, never supplied − borrowed. Every USD figure of an asset uses the Lend Spoke's oracle price.

Example (Ethereum, USDC, illustrative): the Hub holds 10,000,000 added (Lend Spoke 9,800,000, Coverage Spoke 200,000) and 3,000,000 owed, 1,000,000 by CDP Spoke U and 2,000,000 by CDP Spoke X, so liquidity is 7,000,000 and utilization 30 %. The Lend page shows 10,000,000 supplied, 3,000,000 borrowed, 7,000,000 available. U's Borrow asset page shows the same 10,000,000 Hub supply and 30 % utilization, 1,000,000 borrowed via U and `min(4,000,000 cap − 1,000,000, 7,000,000) = 3,000,000` available; X's shows 2,000,000 and `min(3,000,000 − 2,000,000, 7,000,000) = 1,000,000`. 1,000,000 + 2,000,000 is the Lend page's 3,000,000. If lenders withdraw 5,000,000, liquidity falls to 2,000,000: U can draw 2,000,000 and X 1,000,000, but together only 2,000,000. Rates: a 6 % drawn rate with a 10 % reserve factor gives lenders `6 % × 30 % × 0.9 = 1.62 %` (APY `e^0.0162 − 1`); a market with 5 % collateral risk charges its borrowers `6 % × 1.05 = 6.30 %`. `test/reconcile.test.ts` checks every one of these sums on fixture data.

## Current values

`ingest/sampler.refresh` runs every 30 s per chain. At one block it reads, over Convex's own RPC (`RPC_<CHAIN>`, `RPC_<CHAIN>_FALLBACK`), the chain snapshot of `@avana/services-common/views`: the Lend Spoke's reserves and oracle prices, each Hub asset's totals, its Spokes, rate curve and Lens exposure, every CDP Spoke's debt reserves (`Lens.getDebtReserves`) and liquidation config, and every market (`Lens.getMarkets`) with its collateral risk. One mutation replaces the rows; every row carries the block. The same reader runs in the indexer's hourly sampler, so current rows and chart points come from the same calls.

A market, pool or asset listed on chain appears at the next run, with a default slug (`ethereum-market-4`) until its listing metadata loads. The same run stores the chain's base fee, priority fee and native USD price (`deployments.nativeUsdFeed`) for the fee quote.

Debt, interest and health factor of a wallet change without events and are never served from Convex: the app reads them live at a stated block (`Spoke.getUserAccountData`, `Lens.getAccount`; [EVENTS.md](../indexer/EVENTS.md#live-reads)).

## Chart series

The indexer samples every Hub asset, Spoke slice, market, market debt and account once an hour of block time and aggregates every pool's swaps, mints and burns; `ingest/pull` imports closed buckets from `/export/v1/series` after the series cursor (`ingestCheckpoints.seriesThroughTime`). A bucket keeps the first sample in it, so all scopes of one bucket share a block and add up as the current rows do.

Queries fill gaps: a sampled value repeats through a bucket with no sample, a summed pool value is 0 for a bucket with no trade. Hourly buckets serve 1D and 1W, daily buckets the longer ranges; a chart's last point is the current row. `series.get` returns any metric of any scope with its block; the screens' hero queries (`markets.get*HeroSeries`, `getSupplyBorrow`) return daily `YYYY-MM-DD` points.

When the import sees `MarketRegistered`, it schedules `ingest/poolHistory.backfill`: the pool's swaps before its listing, from `POOL_HISTORY_DAYS` (default 90) days earlier, in 10,000-block ranges from `/export/v1/pool-history`. Each range is applied once, in order (`poolBackfills`), into `series` rows with source `history`; queries merge them with the live buckets by the pool's merge rules, so a new market's volume, fee and price charts start with data.

## Listing metadata

Names, slugs, descriptions, FAQs, history and long text of the pages a listing adds are one JSON file (`lib/metadata.ts`, version 1): a list of entries, each with its scope (`lend`, `asset`, `pool`, `spoke`, `token`) and on-chain key (`hub:assetId`, `spoke:reserveId`, `marketId`, or an address). The governance listing operation commits to it: its timelock salt is keccak256 of the file's bytes.

1. The import records `AvanaTimelock.CallSalt` of every operation with a non-zero salt.
2. On the operation's first `CallExecuted`, `listing/load.loadMetadata` fetches `<LISTING_CONTENT_URL>/<salt>.json`.
3. It refuses the file unless keccak256 of its bytes equals the salt, it names the chain the operation ran on, every key is in its on-chain form and every slug is unique in its scope.
4. One mutation stores each entry in `marketContent` and sets the slug on the row it names.

A 404 marks the operation as carrying no metadata; a refused file is recorded with its reason and nothing is stored. A later listing's entry for the same key replaces the earlier one.

## Frontend fee

No contract charges a fee (Q-231). The app adds one ERC-20 transfer to the action's batch (`wallet_sendCalls`, EIP-5792, or a smart account's multicall), so fee and action succeed or revert together. `feeConfig` holds the rules: on or off, a default rate, a rate per action, exempt actions and a USD cap per action; until a row is written, no fee is charged, and repay, repay with collateral and collateral withdrawal are exempt. `frontendFee.setConfig` is internal (dashboard or CLI only).

`frontendFee.quote(chainId, action, token, amount, gasUnits, l1FeeWei?)` returns the fee in token base units and USD, the gas cost and the total:

- fee `⌊amount × bps / 10⁴⌋`, then cut to the USD cap (rounded down), so the user never pays above the stated rate;
- gas `gasUnits × (baseFee + priorityFee) + l1Fee`, where `gasUnits` is the wallet's simulation of the whole batch, fee transfer included, and `l1Fee` the OP Stack data fee on Base;
- total: amount + fee + gas for supply, pledge and repay; amount − fee − gas for withdraw and borrow.

Example: supplying 10,000 USDC at 10 bps with 200,000 gas at 20 gwei + 1 gwei and ETH at $3,000: fee 10 USDC, gas 0.0042 ETH = $12.60, total $10,022.60. The app builds the transfer with the same function (`lib/fees.ts`), so the amount shown is the amount sent.

## Screens

| Screen | Queries |
|---|---|
| Lend list | `markets.listLendMarketSnapshots`, `prices.getPriceSnapshot` |
| Lend page | `detailHydration.getLendDetail`, `markets.getQuickStats`, `markets.getLendHeroSeries`, `lend.cashflow.getBreakdown`, `markets.getRecentTransactions`, `hubAssets.allocation` |
| Borrow list | `markets.listBorrowMarketSnapshots` (pool rows: markets; asset rows: CDP debt reserves) |
| Borrow pool page | `detailHydration.getBorrowPoolDetail`, `markets.getQuickStats`, `markets.getPoolHeroSeries`, `borrow.liquidationRisk.getLiquidationRisk` |
| Borrow asset page | `detailHydration.getBorrowAssetDetail`, `markets.getQuickStats`, `markets.getAssetHeroSeries`, `borrow.cashflow.getBreakdownForAsset`, `spokeReserves.byMarket` |
| Action pages | `frontendFee.quote`, `frontendFee.getConfig` |
| Dashboard | `wallet.positions.listForWallet` (accounts and last samples); balances are read live |

## Tables of the import

| Table | Key | Contents |
|---|---|---|
| `ingestCheckpoints` | `chainId` | `throughBlock`, `throughBlockHash`, `schemaVersion`, `lastPageHash`, `seriesThroughTime`, `updatedAt` |
| `ingestCheckpointHistory` | `chainId + throughBlock` | One verified checkpoint every 1,000 blocks, with its block hash; the rebuild starting points |
| `ingestedLogs` | `key` (`chainId:txHash:logIndex`) | The last 30 days of decoded logs with the scope keys each page's feed reads (`hubAssetKey`, `spokeReserveKey`, `marketKey`, `wallet`); older activity is fetched from the export's history endpoint on request |
| `accounts` | `chainId + Spoke + proxy` | Wallet ↔ proxy from `UserProxyCreated` |
| `parameterChanges` | scope, chain, key, time | Changelog rows with previous and current values, from configuration events |
| `listingOperations`, `poolBackfills` | operation; pool | Listing metadata state; pool-history progress |

Each page's activity feed shows its own events and none twice: the Lend page the Lend Spoke's supplies and withdrawals and the CDP Spokes' borrows, repays and liquidations of its asset; a Borrow asset page its CDP Spoke's reserve events; a pool page Avana's account events (`CollateralAdded`, `Borrowed`, `Repaid`, `LiquidationSettled`, …).

## Scheduled pull

A Convex cron runs `ingest/pull.pull` for each chain every 30 s on Ethereum and every 10 s on Base. The action:

1. Reads the checkpoint `(throughBlock, throughBlockHash)`.
2. Checks that `throughBlockHash` is still the hash of `throughBlock` over Convex's own RPC (not the indexer's). A mismatch goes to [reorg rebuild](#reorg-rebuild).
3. Requests `GET /export/v1/pages?chainId&after=throughBlock&limit=500`, signed with the HMAC key from Convex environment variables (`INDEXER_EXPORT_URL`, `INDEXER_EXPORT_KEY_ID`, `INDEXER_EXPORT_SECRET`). A 204 ends the event pages.
4. Validates the page: known `schemaVersion`; `fromBlock = throughBlock + 1`; `toBlock ≤ finalizedBlock`; records ordered by `(blockNumber, logIndex)` and inside `fromBlock..toBlock`; every record's `blockHash` equal to the page's entry for its block; `pageHash` recomputed from the canonical JSON; `toBlockHash` equal to the hash of `toBlock` over Convex's own RPC.
5. Calls the internal mutation `ingest/apply.applyPage(page)`.
6. Repeats while pages keep coming, up to 20 pages per run, then pulls series pages the same way.

## Atomic page updates

`applyPage` is one Convex mutation, so a page is applied entirely or not at all:

- It re-reads the checkpoint inside the mutation and applies the page only if `page.after.throughBlock` equals it. Two overlapping runs therefore cannot both apply the same range: the second sees the moved checkpoint and returns without writing.
- Each record is inserted into `ingestedLogs` unless its `key` already exists; an existing key with a different `blockHash` aborts the mutation and starts the rebuild. A page delivered twice, or a record that appears in two pages, changes nothing the second time.
- The decoded rows (accounts, changelog rows, listing operations) are written by the same decoder the rebuild uses, in record order.
- The checkpoint moves to `{ throughBlock: toBlock, throughBlockHash: toBlockHash, lastPageHash: pageHash }`; every 1,000 blocks a row is added to `ingestCheckpointHistory`.

A page holds at most 500 records and each record touches at most a few rows, which keeps one mutation inside Convex's per-transaction read and write limits. Series pages apply the same way against `seriesThroughTime`.

## Reorg rebuild

The export serves only finalized blocks, so a rebuild means something outside normal operation happened: Convex's RPC and the indexer disagree on a finalized hash, the indexer was re-pointed or reindexed differently, or a finalized block was reverted. In each case:

1. Ingestion of that chain stops and an error is logged for engineering.
2. Convex walks `ingestCheckpointHistory` back to the newest checkpoint whose block hash still matches its own RPC.
3. In bounded mutations (`ingest/apply.rewind`) it deletes `ingestedLogs`, changelog and account rows above that checkpoint, then sets the checkpoint to it.
4. The pull resumes from there and rebuilds the rows from the export.

<a id="rebuild"></a>A new `schemaVersion` rebuilds from block 0 into fresh tables and switches the views when the new tables reach the old checkpoint.

## Transaction progress

After the user's wallet submits, Convex tracks the receipt over RPC at the head: the intent moves to `included` when the receipt shows success, the account is refreshed by a live read at that block, and the activity is marked `indexed` when the export delivers the same `txHash`. If a reorg removes the block before finality, the intent returns to `pending` (`TEST-143`).

## Configuration

Convex environment variables: `RPC_<CHAIN>` and `RPC_<CHAIN>_FALLBACK` (`MAINNET`, `BASE`), `INDEXER_EXPORT_URL`, `INDEXER_EXPORT_KEY_ID`, `INDEXER_EXPORT_SECRET` (base64, at least 32 bytes), `LISTING_CONTENT_URL`, `POOL_HISTORY_DAYS`. Each chain's `deployments` row is written from its verified release manifest with `deployments.setDeployment` (internal).

## Build and test

From the repository root, `npm ci --ignore-scripts` installs this package with the rest of the workspace. Then, from this folder:

```bash
npm run typecheck   # tsc --noEmit, against the committed convex/_generated/
npm run test        # vitest run: offline, no deployment needed
npx convex dev      # against a Convex deployment; regenerates convex/_generated/
```

| Test | Checks |
|---|---|
| `reconcile.test.ts` | Borrow asset pages' borrowed amounts add up to the Lend page's; every page shows the same Hub supply, utilization and rates; available is liquidity bounded by cap room; the Lend allocation adds up to the Hub; a Spoke's split by market adds up to its owed amount |
| `fees.test.ts` | Fee per action, exemptions, USD cap, rounding down, gas with and without an L1 data fee, totals for paying and receiving actions |
| `charts.test.ts` | History and live parts of one bucket merge; gaps filled per metric; ranges and the live last point; quick-stat deltas |
| `ingest.test.ts` | Export page checks (gap, overlap, finality, order, block hash, tampered content); request signature equals the indexer's HMAC; metadata accepted only when its bytes hash to the salt, refused on chain, slug or key errors |
| `activity.test.ts` | Each event lands in the right pages' feeds and in no page twice; changelog rows with previous values; listing operations from the timelock |

The import's fork tests (`TEST-143`): duplicate, overlapping, out-of-order and tampered pages leave the state of a clean run; an Anvil reorg below the checkpoint with an indexer pointed at a different branch rebuilds to the state of a clean run; an end-to-end fork run goes from pledge, borrow, price drop and keeper liquidation through the indexer, export and Convex to the UI.
