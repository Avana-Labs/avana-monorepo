# @avana/export

The consumer side of the indexer's [private export](../../services/indexer/EXPORT.md), in one place for every reader (Convex today; any other service or tool that reads the export). The wire types stay in `@avana/services-common/export` and `@avana/services-common/series`, next to the producer.

| Module | Contents |
|---|---|
| `src/auth.ts` | `signRequest` and `verifyRequest` (HMAC-SHA256 over `timestamp\nMETHOD\npath?query`, 60 s skew, constant-time compare), `parseKeys` for `id:base64secret` lists. Web Crypto only, so it runs in Convex, Node and browsers |
| `src/validate.ts` | `validatePage`, `validateSeriesPage`, `validateHistoryPage`, `validatePoolHistory`, `validatePremiumRefresh`; `pageHashOf` and `withPageHash` (keccak256 of canonical JSON) |
| `src/client.ts` | `createExportClient({ baseUrl, keyId, secretBase64 })`: `pages`, `series`, `history`, `poolHistory`, `premiumRefresh`. Each request is signed, each response validated. 204 returns null, 503 throws `ExportUnavailable`, any other error status throws `ExportHttpError` |

The caller still checks `toBlockHash` of an event page against its own RPC before applying it; the client cannot, because it has no RPC.

## Test

```bash
npm run typecheck
npm run test
```

The tests generate their keys at run time. They check that a signature equals the indexer's `node:crypto` HMAC, that both keys verify during a rotation, and that each validator refuses the pages EXPORT.md rules out.
