# Private versioned export

The indexer hands chain data to Convex only through this export. Ponder handlers never write to Convex, and Convex never queries the indexer's tables or a GraphQL or SQL endpoint (none is mounted). The wire types are in [`services/common/src/export.ts`](../common/src/export.ts); the endpoint is [`src/api/index.ts`](src/api/index.ts).

## Endpoint

`GET /export/v1/pages?chainId=<id>&after=<throughBlock>&limit=<n>`

| Response | Meaning |
|---|---|
| 200 + `ExportPage` | The next page after block `after` (or from the start when `after` is absent) |
| 204 | No block after `after` is both finalized and fully indexed yet |
| 400 | A parameter is not a decimal integer, or `limit` is outside 1 to 500 |
| 401 | Authentication failed |

## Pages

- **Order and range.** Records are `event_log` rows in `(blockNumber, logIndex)` order. A page covers whole blocks `fromBlock..toBlock`: every indexed log of those blocks is in the page. `next.throughBlock = toBlock`, so the cursor is a block number and a block is never split. A block with more than `limit` records is served whole in one page.
- **Depth.** `toBlock ≤ min(finalized, indexed − 1)`, where `finalized` is the chain's `finalized` block read over the indexer's RPC when the page is built, and `indexed` is the last block of the `chain_progress` row. Rows at the head stay in Ponder, which can still roll them back; the export only serves blocks no reorg can remove.
- **Bound.** At most 500 records per page (`EXPORT_MAX_RECORDS`), so Convex applies a page in one mutation within its transaction limits.
- **Block hashes.** `blocks` lists the number, hash and timestamp of every block that holds a record, plus `toBlock`; `toBlockHash` is the hash of `toBlock` read when the page was built.
- **Identity.** `pageHash = keccak256(canonical JSON of the page without pageHash)`, keys sorted at every level. The same request against the same chain state returns the same bytes and hash.
- **Version.** `schemaVersion` changes whenever a record kind gains, loses or renames a field. Convex refuses a page whose version it does not know, and a new version starts a rebuild from block 0 on the Convex side ([Convex import](../convex/README.md#rebuild)).
- **Records.** `kind` is `<Contract>.<Event>` from [EVENTS.md](EVENTS.md); `args` are the decoded arguments with integers as decimal strings and addresses in lower case; `key = chainId:txHash:logIndex`.

Example: Convex holds `throughBlock = 21,400,000` for chain 1 and requests `after=21400000&limit=500`. Ethereum's finalized block is 21,400,180 and the indexer has handled 21,400,240. 620 records lie in 21,400,001..21,400,180, the 500th inside block 21,400,151. The page drops the records of block 21,400,151 that fit, so it serves 21,400,001..21,400,150 (say 488 records) with `next.throughBlock = 21400150`; the next request starts at 21,400,151.

## Series

`GET /export/v1/series?chainId=<id>&after=<throughTime>&limit=<n>` (1 to 2,000, default 2,000) returns a `SeriesExportPage` ([`services/common/src/series.ts`](../common/src/series.ts)) of closed buckets of `series_point`, or 204 when none closed after the cursor.

- **Closed buckets only.** A bucket is served once its end is at or before `min(timestamp of the finalized block, timestamp of the last indexed block − 1)`. Every sample and log in it is then final, and the row never changes after it is served.
- **Order and cursor.** Records are ordered by bucket end, then scope kind, scope key and resolution; `next.throughTime` is the last bucket end served, and a full page never splits one bucket end.
- **Identity.** `pageHash` is computed as for event pages; Convex refuses a page whose hash, chain, version or cursor does not match.

Example: Convex holds `seriesThroughTime = 1,767,229,200` (01:00 UTC) for chain 1. At 02:20 the finalized block is from 02:06, so the hourly buckets of 01:00 (end 02:00) are served and the 02:00 buckets are not; the next page starts after 02:00.

## Pool history

`GET /export/v1/pool-history?chainId=<id>&pool=<address>&fromBlock=<n>&toBlock=<n>` returns `{ chainId, pool, fromBlock, toBlock, feePips, records }`: the hourly and daily pool buckets of the pool's Swap, Mint and Burn logs in that range, read over the indexer's RPC with `eth_getLogs` (10,000-block chunks, halved when the provider refuses) and aggregated with the same function as the live handler. It answers 400 for a pool not listed on the chain, a range over 50,000 blocks, a range that reaches the pool's listing block (those logs are in the live series) or one above the finalized block. Block timestamps are interpolated between hourly anchor blocks: exact on Base, within a missed slot on Ethereum. Buckets cut by the range's edges are partial; Convex requests consecutive ranges in order and merges each bucket by the pool series' merge rules, so the result equals one request over the whole range.

## Keeper stream

`GET /keeper/v1/events?chainId=<id>&after=<block>&afterHash=<hash>&limit=<n>` feeds the bot runner's account set at the chain head (the LiquidationBot's discovery) ([`src/api/keeperEvents.ts`](src/api/keeperEvents.ts); wire types in [`services/common/src/keeperStream.ts`](../common/src/keeperStream.ts)). It serves only the `event_log` kinds the bots follow (`KEEPER_STREAM_KINDS`: `AaveAdapter.AccountCreated` and the other account events, liquidations, repayments with collateral, the Spoke's account events, and the RiskModules' `KeeperAdded` and `KeeperRemoved`), under the same authentication as the export with the bot runner's own key ID. Stream version 2.

| Response | Meaning |
|---|---|
| 200 + `KeeperStreamPage` | Records of whole blocks after `after` (from the start blocks when `after` is absent), up to the last block the indexer has fully handled |
| 204 | No block after `after` is fully indexed yet |
| 409 + `KeeperStreamReorg` | `afterHash` is no longer the chain's hash at `after`, or a served block above `finalized` is not canonical: rewind to the `finalized` cursor it returns |
| 400 | Malformed parameter; `after` and `afterHash` go together; `limit` is 1 to 1,000 |
| 401 | Authentication failed |

- **Depth.** Unlike the export, the stream does not wait for finality: `toBlock ≤ indexed − 1`. Rows at the head can still be rolled back by Ponder, which is why each cursor carries its block hash.
- **Cursor.** `next = { block: toBlock, hash }`, the hash read over the indexer's RPC when the page was built. The bot runner sends both back; the indexer re-reads the hash at `after` and answers 409 on a mismatch. Pages never split a block (as in the export), so a cursor always points after a complete block.
- **Catching up.** A page ends at `toBlock < indexedBlock` when it is full; the bot runner asks again until `toBlock = indexedBlock` or 204.
- **What the bot runner does with it.** `AaveAdapter.AccountCreated` adds an account (wallet, market) to the set; every other kind only names what to re-read. Decisions never use a streamed value: the LiquidationBot re-reads every health factor on chain. A stream that fails or answers 409 falls back to the runner's own RPC scan of `AccountCreated` from the finalized block.

Example: the bot runner holds `{ block: 21,400,240, hash: 0xaa… }`. Block 21,400,240 is replaced by `0xbb…`; Ponder rolls back and replays. The next request names `0xaa…`, the indexer reads `0xbb…` at that height and answers 409 with the finalized cursor `{ 21,400,176, 0xcc… }`; the runner re-reads its RPC logs from 21,400,176 and continues the stream from that cursor.

## Authentication

Every request carries `x-avana-key-id`, `x-avana-timestamp` (unix seconds) and `x-avana-signature = hex(HMAC-SHA256(secret, timestamp + "\n" + METHOD + "\n" + path?query))`. The indexer accepts timestamps within 60 s of its clock and compares in constant time. Keys are listed in `INDEXER_EXPORT_KEYS` as `id:base64secret` (at least 32 bytes); during a rotation both the old and the new key are listed, Convex switches to the new ID, and the old entry is removed. The export listens only on the private network interface; it is never exposed through the public app's hosting.

## Older history

Convex keeps current views and a bounded window of recent activity. Older activity of one wallet is fetched on request by a Convex action from `GET /export/v1/history?chainId=<id>&wallet=<address>&before=<block>&limit=<n>`, under the same authentication, and is shown without being stored ([`src/api/history.ts`](src/api/history.ts); wire type `HistoryPage` in [`services/common/src/export.ts`](../common/src/export.ts)).

| Response | Meaning |
|---|---|
| 200 + `HistoryPage` | The records naming the wallet or one of its attributed proxies, from blocks before `before`, newest first |
| 400 | A parameter is not a decimal integer, `wallet` is not an address, or `limit` is outside 1 to 500 |
| 401 | Authentication failed |
| 503 | The indexer has not reached the chain head since it started (a new schema is still backfilling), so `log_party` is incomplete |

- **Which records.** Every indexed log whose arguments name the wallet (its Lend Spoke activity, its proxies' creation) or one of its proxies attributed by both creation events (`account.adapterSeen` and `managerSeen`); `proxies` lists them. The indexer writes one `log_party` row per address a log's arguments name, with the log row, and the history reads that table instead of searching `event_log.args`.
- **Depth.** `before` is capped at the export's servable block + 1 (`min(finalized, indexed − 1)`), so a history page never holds a block a reorg can remove; without `before` the newest page starts there.
- **Order and cursor.** Records are in descending `(blockNumber, logIndex)` order and a page never splits a block: a full page drops its oldest block, which the next page (`next.before`, the oldest block served) starts with, unless that block is the whole page, in which case it is served whole. `next` is null when nothing older exists.

- **Reindex.** `log_party` is written with each log, so a release that adds it (or any schema or handler change) runs under a new `DATABASE_SCHEMA` and reindexes from the manifest start blocks (README, Reorgs and checkpoints). While it backfills, the history answers 503 and Convex's `wallet/history:older` action reports the history as unavailable instead of showing it empty; the export's event pages are unaffected, since Convex follows them by block cursor. Traffic moves to the new schema after `/ready`.

## Risk premium refresh

`GET /export/v1/premium-refresh?chainId=<id>&spoke=<address>` returns a `PremiumRefreshList` ([`services/common/src/export.ts`](../common/src/export.ts)): the attributed proxies of one CDP Spoke that hold drawn debt and whose last `UpdateUserRiskPremium` is older than the Spoke's last `collateralRisk` change (`UpdateReserveConfig` with a new value; a reserve's first configuration is not a change). The Aave DAO's refresh payload passes them to `updateUserRiskPremium` (services/README.md); a proxy left out keeps its premium until its next action. The list is read at the indexer's head (`asOfBlock`), not at finality, and answers 503 before the indexer reaches the head.

Example: reserve 1 of a Spoke moves from collateral risk 1,000 to 1,500 at block 8, log 3. Account A last had its premium updated at block 8, log 2, and account B at block 9; both borrow. The list names A only. Once the payload executes, A's `UpdateUserRiskPremium` at a later block takes it off the list.

## Reorgs

The indexer serves only finalized blocks, so an export page never contains a block that a reorg removes. Convex still checks `toBlockHash` and its own last checkpoint hash over its own RPC before applying a page, because a misconfigured RPC, a re-pointed indexer or a deep reorg would otherwise go unnoticed; a mismatch triggers the rebuild in [the Convex import](../convex/README.md#reorg-rebuild).
