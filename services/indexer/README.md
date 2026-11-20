# indexer

Ponder indexer with a PostgreSQL store for Avana and Aave V4 events on Ethereum and Base (or Sepolia and Base Sepolia). It keeps the full history, feeds the keeper and monitoring at the chain head, and hands finalized data to Convex through the [private export](EXPORT.md). Every event it handles and every value it does not hold are listed in [EVENTS.md](EVENTS.md).

| Path | Contents |
|---|---|
| `ponder.config.ts` | Chains and contract sources, built from the verified manifests |
| `ponder.schema.ts`, `src/schema/` | Tables, split by concern |
| `src/handlers/` | One file per area; every event handler writes the `event_log` row first, except pool swaps, mints and burns, which only feed the pool's series (`pools.ts`); `series.ts` is the hourly sampler |
| `src/lib/` | Provenance, the log writer, log-only registration, the series writer and the pool series aggregation |
| `src/config/` | ABIs from `packages/protocol`, the factory events taken from them, and manifest-driven sources |
| `test/` | Unit tests (vitest): the handlers on scripted logs through an in-memory store (`test/harness`; account attribution, debt, custody, reserves and deficit offsets, risk premiums), replay and reorg properties of the whole handler set, event coverage of every followed ABI, factory events and log-only subscriptions against the ABIs, export authentication, the keeper stream's paging rules and kinds, the wallet history's request, parties and paging, the snapshot reader's ABI fragments against the generated ABIs, pool series aggregation |
| `src/api/` | The authenticated export (event pages, series pages, pool history, wallet history, risk premium refresh list) and the keeper stream, the only HTTP routes besides Ponder's own `/health`, `/ready`, `/status` and `/metrics` (Prometheus, read by `services/dashboards`) |

## Configuration

Names are in [`.env.example`](.env.example). `INDEXER_NETWORK_SET` selects `production` (Ethereum, Base) or `testnet` (Sepolia, Base Sepolia); a chain is indexed only when `AVANA_MANIFEST` names a verified manifest for it. Each chain uses `RPC_<CHAIN>` and `RPC_<CHAIN>_FALLBACK` for HTTP and `RPC_<CHAIN>_WS` for new heads, the same names as the keeper and `contracts/.env.example`. At startup the indexer loads each manifest and compares its ABI hash with the hash of the ABIs it was built with; a mismatch stops it (`TEST-149`).

## Provenance

Every row that an event writes or changes stores the chain ID, block number, block hash and log index of that log (`event_log` keeps all of them; entity tables keep `lastBlock`, and where the row is an account's or record's state also `lastBlockHash` and `lastLogIndex`). The keys are those of `TEST-061`: accounts `chainId + Spoke + proxy`, positions `chainId + LPVault + positionKey`, markets `chainId + marketId`, debt reserves `chainId + RiskModule + Spoke + debtReserveId`, logs `chainId + txHash + logIndex`.

## Reorgs and checkpoints

- **At the head.** Ponder follows the head over WebSocket with HTTP polling as fallback. When a block it indexed leaves the canonical chain, Ponder reverts every table to the common ancestor and replays the new branch; Avana's handlers are written for that: the `event_log` insert is keyed by the log, entity updates are pure functions of the log, and the only reads a handler makes go through Ponder's client pinned to the handler's block (the sampler's views, a pool's `fee()`), so a replay reads the same values.
- **Window.** `reorgWindow` is 600 s on every chain. Ethereum finalizes in about 13 minutes; rows between 600 s and finality are no longer reversible inside Ponder, which is why the export serves only `finalized` blocks.
- **Crash recovery.** A restart with the same `DATABASE_SCHEMA` resumes from Ponder's last checkpoint. A restart with a changed schema or handler code starts a new schema and reindexes from the manifest start blocks; the export switches to the new schema only after `/ready`, so Convex never reads a half-built index.
- **Full reindex** completes within one hour from the start blocks (services/README.md); the `Progress` block source starts at `latest`, so it adds no historical blocks. The `SeriesSampler` source adds one sample per hour of chain history since Avana's deployment (8,760 a year per chain), each six multicall rounds plus the account reads, against an archive node; Ponder caches these reads, so only the first build of a schema pays them.
- **Upgrades.** A contract's ABI is the union of every version deployed since its start block, so each block range decodes with the events its implementation emitted; `Upgraded` rows record when each implementation took over.
- **Replay and reorg tests.** `test/replay.test.ts` runs every handler on one scripted history through an in-memory store that applies Ponder's write rules (`test/harness`): delivering every log again, or through every source that follows a Hub, Spoke or reserve, leaves the same tables, and a reorg handled as Ponder does (revert to the common ancestor, run the new branch) leaves exactly the tables of a fresh run over the canonical branch, with no block hash of the dropped branch. They run in CI with the other unit tests (`services.yml`). `TEST-143`, which replays a fork run with Anvil reorgs against RPC reads at the same block, needs the shared fork environment's manifest, and no workflow runs it yet.

## Running

Install once from the repository root (`npm ci --ignore-scripts`, see [services/README.md](../README.md#build-and-test)), then from this folder:

```bash
npm run codegen     # writes ponder-env.d.ts, the types of Ponder's virtual modules
npm run typecheck   # tsc --noEmit
npm run test        # vitest run
npm run dev         # local, against Anvil or a fork
npm run start -- --schema avana_<release>
```

Factory sources (vault tokens, First-Loss Reserves, market pools) take their announcing event from the generated ABIs (`factoryEvents` in `src/config/abis.ts`), so a changed event signature fails the typecheck or the tests instead of leaving a source that matches no log.
