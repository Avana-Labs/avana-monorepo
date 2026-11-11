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

## Authentication

Every request carries `x-avana-key-id`, `x-avana-timestamp` (unix seconds) and `x-avana-signature = hex(HMAC-SHA256(secret, timestamp + "\n" + METHOD + "\n" + path?query))`. The indexer accepts timestamps within 60 s of its clock and compares in constant time. Keys are listed in `INDEXER_EXPORT_KEYS` as `id:base64secret` (at least 32 bytes); during a rotation both the old and the new key are listed, Convex switches to the new ID, and the old entry is removed. The export listens only on the private network interface; it is never exposed through the public app's hosting.

## Older history

Convex keeps current views and a bounded window of recent activity. Older activity of one wallet is fetched on request by a Convex action from `GET /export/v1/history?chainId=<id>&wallet=<address>&before=<block>&limit=<n>`, under the same authentication, and is shown without being stored. It returns the same `ExportRecord` shape for the wallet's attributed proxies, newest first.

## Reorgs

The indexer serves only finalized blocks, so an export page never contains a block that a reorg removes. Convex still checks `toBlockHash` and its own last checkpoint hash over its own RPC before applying a page, because a misconfigured RPC, a re-pointed indexer or a deep reorg would otherwise go unnoticed; a mismatch triggers the rebuild in [the Convex import](../convex/README.md#reorg-rebuild).
