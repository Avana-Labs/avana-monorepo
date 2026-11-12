# Convex import

How the Convex backend takes chain data from the indexer's [private export](../indexer/EXPORT.md). This folder is the one Convex project: schema, public queries, authenticated mutations for sessions and intents (`convex/protocol/`), ingestion (`convex/ingest/`), daily history snapshots, receipt tracking and migrations; this page is the design the ingestion follows. Convex serves current market and portfolio views, a bounded window of recent activity, transaction progress and authenticated action preparation; it never holds a transaction target, receiver, amount or calldata (REQ-ARCH-140); the web app in `web/` reads it.

## Tables

| Table | Key | Contents |
|---|---|---|
| `ingestCheckpoints` | `chainId` | `throughBlock`, `throughBlockHash`, `schemaVersion`, `lastPageHash`, `updatedAt` |
| `ingestCheckpointHistory` | `chainId + throughBlock` | One verified checkpoint every 1,000 blocks, with its block hash; the rebuild starting points |
| `ingestedLogs` | `key` (`chainId:txHash:logIndex`), unique index | Bounded recent activity (the last 30 days); older activity is fetched from the export's history endpoint on request |
| Derived views (`accounts`, `records`, `markets`, `debtReserves`, `escrowCredits`, `pauseStates`, `breakers`) | Indexer keys | Each row stores `sourceBlock`, the block of the log that last changed it |

## Scheduled pull

A Convex cron runs `ingest.pull` for each chain every 30 s on Ethereum and every 10 s on Base. The action:

1. Reads the checkpoint `(throughBlock, throughBlockHash)`.
2. Checks that `throughBlockHash` is still the hash of `throughBlock` over Convex's own RPC (not the indexer's). A mismatch goes to [reorg rebuild](#reorg-rebuild).
3. Requests `GET /export/v1/pages?chainId&after=throughBlock&limit=500`, signed with the HMAC key from Convex environment variables. A 204 ends the run.
4. Validates the page: known `schemaVersion`; `fromBlock = throughBlock + 1`; `toBlock ≤ finalizedBlock`; records ordered by `(blockNumber, logIndex)` and inside `fromBlock..toBlock`; every record's `blockHash` equal to the page's entry for its block; `pageHash` recomputed from the canonical JSON; `toBlockHash` equal to the hash of `toBlock` over Convex's own RPC.
5. Calls the internal mutation `ingest.applyPage(page)`.
6. Repeats while pages keep coming, up to 20 pages per run, so one run stays within the action time limit.

## Atomic page updates

`applyPage` is one Convex mutation, so a page is applied entirely or not at all:

- It re-reads the checkpoint inside the mutation and applies the page only if `page.after.throughBlock` equals it. Two overlapping runs therefore cannot both apply the same range: the second sees the moved checkpoint and returns without writing.
- Each record is inserted into `ingestedLogs` unless its `key` already exists; an existing key with a different `blockHash` aborts the mutation and starts the rebuild. This is the duplicate protection: a page delivered twice, or a record that appears in two pages, changes nothing the second time.
- Derived views are updated by the same reducer used in the rebuild, in record order.
- The checkpoint moves to `{ throughBlock: toBlock, throughBlockHash: toBlockHash, lastPageHash: pageHash }`; every 1,000 blocks a row is added to `ingestCheckpointHistory`.

A page holds at most 500 records and each record touches at most a few view rows, which keeps one mutation inside Convex's per-transaction read and write limits.

## Reorg rebuild

The export serves only finalized blocks, so a rebuild means something outside normal operation happened: Convex's RPC and the indexer disagree on a finalized hash, the indexer was re-pointed or reindexed differently, or a finalized block was reverted. In each case:

1. Ingestion of that chain stops and an alert goes to engineering.
2. Convex walks `ingestCheckpointHistory` back to the newest checkpoint whose block hash still matches its own RPC.
3. In bounded mutations it deletes `ingestedLogs` rows and resets derived rows with `sourceBlock` above that checkpoint, then sets the checkpoint to it.
4. The pull resumes from there and rebuilds the views from the export.

<a id="rebuild"></a>A new `schemaVersion` rebuilds from block 0 into fresh tables and switches the views when the new tables reach the old checkpoint.

## Live values

Debt, interest, health factor and price states change without events. Convex never serves them from the export: queries that show them call RPC at a stated block (`Spoke.getUserAccountData`, `Lens.getAccount`, `Lens.getPriceState`; the list is in [EVENTS.md](../indexer/EVENTS.md#live-reads)) and return the block with the value.

## Transaction progress

After the user's wallet submits, Convex tracks the receipt over RPC at the head: the intent moves to `included` when the receipt shows success, the account is refreshed by a live read at that block, and the activity is marked `indexed` when the export delivers the same `txHash`. If a reorg removes the block before finality, the intent returns to `pending` (`TEST-143`).

## Tests

- Duplicate page, overlapping page, out-of-order page and a page with a tampered record or hash: the state equals that of a clean run (`TEST-143`).
- An Anvil reorg below the checkpoint on a fork with an indexer pointed at a different branch: the rebuild restores the state of a clean run.
- An end-to-end fork run: pledge, borrow, price drop, keeper liquidation, indexer, export, Convex, UI.
