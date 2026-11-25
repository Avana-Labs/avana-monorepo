// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The checks of the indexer replay (services-replay.sh `finish`).
//
// Convex mode, on a local Convex deployment already running from services/convex and the replay indexer serving its
// export: sets the deployment's environment and row, imports the export and the series to the finalized head, samples
// the chain, rolls up every day that holds a liquidation and tracks one intent per transaction outcome. Then it
// compares Convex with the chain, reading the chain directly (logs by event signature from every address, and reads
// pinned to the block a Convex row names):
//   markets      every market of the manifest has its row, each row equal to the chain at its block; the
//                RiskModules' MarketListed and MarketActivated logs
//   accounts     the accounts table is the set of AaveAdapter.AccountCreated (wallet, the adapter's integration and the
//                market ID, account, the market's Spoke)
//   positions    each account's collateral and debt at the last closed daily sample (E2E_SAMPLE_BLOCK)
//   debts        each market's debt per debt reserve at that sample (summed over accounts), and no row for a debt
//                the chain no longer holds; CDP Spoke Borrow, Repay and ReportDeficit logs
//   liquidations LiquidationModule Liquidated and FeePaid logs, and the daily rollup counts
//   payouts      repay with collateral (FlashloanRepay), loss-layer funding and deficit cover
//   intents      a protocol transaction reaches `indexed`, a transaction without logs `included`, a reverted one
//                `failed`
// Every log comparison covers the blocks Convex imported (its checkpoint).
//
// Indexer mode (`--indexer <repo> <pglite dir> <schema a> <schema b>`), after the indexers stopped: every table of the
// two schemas holds the same rows (the live pass and the replay from Ponder's sync store).
//
// Usage, from contracts/:  node script/e2e/replay-check.ts <manifest.json> <repo root>
//                          node script/e2e/replay-check.ts --indexer <repo root> <pglite dir> live replay
// Environment (Convex mode): RPC_ANVIL (the checked node), CHAIN_ID_<SUFFIX> (the chain it stands in for, e.g.
// CHAIN_ID_MAINNET=31337), E2E_EXPORT_URL, E2E_EXPORT_KEY_ID, E2E_EXPORT_SECRET, E2E_SAMPLE_BLOCK.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { type Abi, type AbiEvent, type Address, type Hex, type PublicClient, createPublicClient, getAbiItem, http, parseAbi } from "viem";

type Json = Record<string, any>;
const failures: string[] = [];
const lines: string[] = [];
const fail = (area: string, msg: string) => failures.push(`${area}: ${msg}`);
const ok = (area: string, msg: string) => lines.push(`${area}: ${msg}`);
const lower = (a: unknown) => String(a).toLowerCase();

if (process.argv[2] === "--indexer") {
  const [repo, dataDir, a, b] = process.argv.slice(3) as [string, string, string, string];
  await compareSchemas(repo, dataDir, a, b);
} else {
  await convexMode();
}
for (const l of lines) process.stdout.write(`replay: ${l}\n`);
for (const f of failures) process.stdout.write(`replay: FAIL ${f}\n`);
process.stdout.write(`replay: ${lines.length} checks passed, ${failures.length} failed\n`);
process.exit(failures.length > 0 ? 1 : 0);

// ─── Indexer mode ───

/**
 * Every user table of schema `a` must hold the same rows as the same table of schema `b` (Ponder's own tables aside).
 * `chain_progress` holds the head each indexer stopped at, not chain data: an indexer that waited on a chain held still
 * stops a block or two later (services.ts indexerAtHead), so it is left out.
 */
async function compareSchemas(repo: string, dataDir: string, a: string, b: string) {
  const { PGlite } = await import(pathToFileURL(join(repo, "node_modules/@electric-sql/pglite/dist/index.js")).href);
  const db = new PGlite(dataDir);
  const tables = async (s: string) =>
    ((await db.query(`select table_name from information_schema.tables where table_schema = $1 and table_type = 'BASE TABLE' and table_name not like '\\_%' order by 1`, [s])).rows as { table_name: string }[]).map((r) => r.table_name);
  const ta = await tables(a);
  const tb = await tables(b);
  if (ta.length === 0) fail("indexer", `schema ${a} has no table`);
  const missing = ta.filter((t) => !tb.includes(t));
  if (missing.length > 0) fail("indexer", `tables of ${a} missing from ${b}: ${missing.join(", ")}`);
  let rows = 0;
  // Declared here: the indexer mode runs at the top of the file, before a module-level constant below it is set.
  const perRunTables = new Set(["chain_progress"]);
  for (const t of ta.filter((x) => tb.includes(x) && !perRunTables.has(x))) {
    // A row's text in a stable order: equal digests mean equal tables.
    const digest = async (s: string) =>
      ((await db.query(`select count(*)::int as n, md5(coalesce(string_agg(r::text, '|' order by r::text), '')) as h from "${s}"."${t}" r`)).rows[0] as { n: number; h: string });
    const [da, dbb] = [await digest(a), await digest(b)];
    rows += da.n;
    if (da.n !== dbb.n || da.h !== dbb.h) fail("indexer", `${t}: ${a} has ${da.n} rows, ${b} ${dbb.n}${da.n === dbb.n ? " (contents differ)" : ""}`);
  }
  await db.close();
  ok("indexer", `${ta.length} tables, ${rows} rows: the replay from the sync store equals the live pass`);
}

// ─── Convex mode ───

async function convexMode() {
  const [manifestPath, repo] = process.argv.slice(2) as [string, string];
  const env = (n: string) => {
    const v = process.env[n];
    if (!v) throw new Error(`set ${n}`);
    return v;
  };
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8")) as Json;
  const OUT = dirname(manifestPath);
  const chainId = Number(manifest.chainId);
  const rpc = env("RPC_ANVIL");
  const sampleBlock = BigInt(env("E2E_SAMPLE_BLOCK"));
  const CONVEX_DIR = join(repo, "services/convex");
  const CONVEX = join(repo, "node_modules/convex", JSON.parse(readFileSync(join(repo, "node_modules/convex/package.json"), "utf8")).bin.convex);
  // On Windows, the CLI may print its result and then abort on a libuv assertion while exiting (convex-check.ts).
  const EXIT_ABORT = /^(Assertion failed: !\(handle->flags & UV_HANDLE_CLOSING\), file src\\win\\async\.c, line \d+\s*)+$/;
  const convex = (args: string[]): string => {
    const r = spawnSync(process.execPath, [CONVEX, ...args], { cwd: CONVEX_DIR, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 30 });
    if (r.error) throw r.error;
    if (r.status !== 0 && !(process.platform === "win32" && EXIT_ABORT.test(r.stderr.trim())))
      throw new Error(`convex ${args.slice(0, 2).join(" ")} exited ${r.status ?? r.signal}: ${r.stderr.trim().slice(-1500)}`);
    return r.stdout;
  };
  const run = <T>(fn: string, args: Json = {}, identity?: Json): T => {
    const out = convex(["run", fn, JSON.stringify(args), ...(identity ? ["--identity", JSON.stringify(identity)] : [])]).trim();
    return (out === "" || out === "null" ? null : JSON.parse(out)) as T;
  };
  // `convex data` reads a whole table in one query, which goes over Convex's per-query read limits on a large table
  // (ingestedLogs). The rows are read a page at a time through the deployment's HTTP API instead, with the admin key
  // `convex dev` keeps for the local deployment.
  const table = async (name: string): Promise<Json[]> => {
    const local = JSON.parse(readFileSync(join(CONVEX_DIR, ".convex/local/default/config.json"), "utf8")) as Json;
    const rows: Json[] = [];
    let cursor: string | null = null;
    for (;;) {
      const res = await fetch(`http://127.0.0.1:${local.ports.cloud}/api/query`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Convex ${local.adminKey}` },
        body: JSON.stringify({ path: "_system/cli/tableData", format: "json", args: { table: name, order: "asc", paginationOpts: { numItems: 1000, cursor } } }),
      });
      const body = (await res.json()) as Json;
      if (body.status !== "success") throw new Error(`reading table ${name}: ${body.errorMessage ?? JSON.stringify(body).slice(0, 300)}`);
      rows.push(...(body.value.page as Json[]));
      if (body.value.isDone) return rows;
      cursor = body.value.continueCursor as string;
    }
  };

  const client = createPublicClient({ transport: http(rpc) }) as PublicClient;
  const { ABI_HASH, aaveAdapterAbi, aaveV4SpokeAbi, firstLossReserveAbi, flashloanRepayAbi, liquidationModuleAbi, riskModuleAbi } = await import("@avana/protocol/abis");
  const { MULTICALL3_ADDRESS, loadManifest } = await import("@avana/services-common");
  const { chainDeploymentOf, readChainSnapshot } = await import("@avana/services-common/views");
  // The addresses the services' snapshot reads, from the manifest as the services load it (schema and ABI hash checked).
  const deployment = chainDeploymentOf(loadManifest(manifestPath, ABI_HASH));
  const integrations = manifest.avana.integrations as Json[];

  // ── Import ──
  // The chain's own variables (RPC_MAINNET and CHAIN_ID_MAINNET for a node standing in for Ethereum, RPC_BASE and
  // CHAIN_ID_BASE for Base), so a check of one chain never repoints Convex's reads of another. This process resolves
  // the chain the same way: CHAIN_ID_<SUFFIX> in its environment.
  const { chainById } = await import("@avana/services-common/chains");
  const suffix = chainById(chainId).envSuffix;
  for (const [k, v] of Object.entries({
    [`RPC_${suffix}`]: rpc,
    [`CHAIN_ID_${suffix}`]: String(chainId),
    INDEXER_EXPORT_URL: env("E2E_EXPORT_URL"),
    INDEXER_EXPORT_KEY_ID: env("E2E_EXPORT_KEY_ID"),
    INDEXER_EXPORT_SECRET: env("E2E_EXPORT_SECRET"),
  }))
    convex(["env", "set", k, v]);
  const world = JSON.parse(readFileSync(join(OUT, "world.json"), "utf8")) as Json;
  run("deployments:setFromManifest", { manifest, explorerUrl: rpc, nativeUsdFeed: world.feeds.WETH.primary });
  // The sampler first, so the import resolves each log's Hub asset, Spoke reserve and market keys.
  run("ingest/sampler:refresh", { chainId });
  let through = -1;
  let seriesThrough = -2;
  for (let i = 0; i < 400; i++) {
    run("ingest/pull:pull", { chainId });
    const s = run<{ checkpoint: { throughBlock: string; seriesThroughTime: number } | null }>("ingest/apply:state", { chainId });
    const at = s?.checkpoint ? Number(s.checkpoint.throughBlock) : -1;
    const st = s?.checkpoint?.seriesThroughTime ?? -1;
    if (at === through && st === seriesThrough && at > 0) break;
    through = at;
    seriesThrough = st;
  }
  if (through <= 0) throw new Error("Convex imported no export page from the indexer");
  const finalized = (await client.getBlock({ blockTag: "finalized" })).number;
  if (BigInt(through) < finalized - 1n) fail("import", `checkpoint ${through} stopped below the finalized block ${finalized}`);
  else ok("import", `export imported through block ${through} (finalized ${finalized}), series through ${new Date(seriesThrough * 1000).toISOString()}`);
  const toBlock = BigInt(through);
  run("ingest/sampler:refresh", { chainId });

  const logs = (await table("ingestedLogs")).filter((l) => l.chainId === chainId);
  const byKind = new Map<string, Json[]>();
  for (const l of logs) byKind.set(l.kind, [...(byKind.get(l.kind) ?? []), l]);

  // ── Chain logs by event signature, from every address (a Spoke or reserve added after start-up included) ──
  const chainLogs = async (abi: Abi, name: string, address?: Address[]) =>
    (await client.getLogs({ event: getAbiItem({ abi, name }) as AbiEvent, fromBlock: 0n, toBlock, ...(address ? { address } : {}) })) as unknown as Json[];
  const keyOf = (l: Json) => `${chainId}:${lower(l.transactionHash)}:${l.logIndex}`;
  /** The Convex logs of `kind` must be exactly the chain's logs; `same` compares the decoded arguments of each pair. */
  const sameLogs = async (area: string, kind: string, abi: Abi, address?: Address[], same?: (chain: Json, convex: Json) => string | null) => {
    const chain = await chainLogs(abi, kind.split(".")[1]!, address);
    const have = new Map((byKind.get(kind) ?? []).map((l) => [l.key as string, l]));
    const missing = chain.filter((l) => !have.has(keyOf(l)));
    const extra = [...have.keys()].filter((k) => !chain.some((l) => keyOf(l) === k));
    const wrong = chain.flatMap((l) => {
      const c = have.get(keyOf(l));
      const why = c && same ? same(l.args, c.args) : null;
      return why ? [`${keyOf(l)} ${why}`] : [];
    });
    if (missing.length + extra.length + wrong.length > 0)
      fail(area, `${kind}: chain ${chain.length}, Convex ${have.size}; missing ${missing.slice(0, 3).map(keyOf).join(" ")} extra ${extra.slice(0, 3).join(" ")} wrong ${wrong.slice(0, 3).join(" ")}`);
    else ok(area, `${kind}: ${chain.length} logs, equal`);
    return chain;
  };
  const eqArgs = (fields: string[]) => (c: Json, x: Json) => {
    for (const f of fields) if (lower(c[f]) !== lower(x[f])) return `${f} chain ${c[f]} Convex ${x[f]}`;
    return null;
  };

  // ── Markets ──
  // Market IDs are per RiskModule: a market is its integration and its ID (`integrationId:marketId`), everywhere.
  const mk = (x: { integrationId: unknown; marketId: unknown }) => `${Number(x.integrationId)}:${String(x.marketId)}`;
  const marketRows = (await table("markets")).filter((m) => m.chainId === chainId);
  const latest = await client.getBlockNumber();
  const snapAt = async (block: bigint) => {
    const b = await client.getBlock({ blockNumber: block });
    return readChainSnapshot(
      { multicall: async (calls) => (await client.multicall({ contracts: calls as never, allowFailure: true, blockNumber: block, multicallAddress: MULTICALL3_ADDRESS })) as never },
      deployment,
      { blockNumber: block, timestamp: Number(b.timestamp) },
    );
  };
  const nowSnap = await snapAt(latest);
  const listed = (manifest.markets as Json[]).map((m) => ({ key: mk(m), spoke: lower(m.spoke), name: `${m.name} ${m.kind}` }));
  const rowOf = (x: { key: string; spoke: string }) => marketRows.find((r) => mk(r) === x.key && lower(r.spoke) === x.spoke);
  const missingMarkets = listed.filter((x) => nowSnap.markets.some((m) => mk(m) === x.key && m.spoke === x.spoke) && !rowOf(x));
  if (missingMarkets.length > 0) fail("markets", `no Convex row for ${missingMarkets.map((x) => `${x.name} (${x.key} on ${x.spoke})`).join(", ")}`);
  const extraMarkets = marketRows.filter((r) => !listed.some((x) => x.key === mk(r) && x.spoke === lower(r.spoke)));
  if (extraMarkets.length > 0) fail("markets", `Convex rows for markets the manifest does not list: ${extraMarkets.map((r) => `${mk(r)} on ${r.spoke}`).join(", ")}`);
  const twice = marketRows.filter((r, i) => marketRows.findIndex((y) => mk(y) === mk(r)) !== i);
  if (twice.length > 0) fail("markets", `markets with two Convex rows: ${twice.map(mk).join(", ")}`);
  const snaps = new Map<string, Awaited<ReturnType<typeof snapAt>>>();
  const snapOf = async (block: string) => {
    if (!snaps.has(block)) snaps.set(block, await snapAt(BigInt(block)));
    return snaps.get(block)!;
  };
  const MARKET_FIELDS = ["kind", "active", "pool", "hub", "reserveId", "hubAssetId", "vaultToken", "lpOracle", "acceptedPrice", "priceAvailable", "suppliedUnits", "suppliedUsd8", "ltvBps", "collateralFactorBps", "collateralRiskBps", "paused", "frozen"];
  let marketsEqual = 0;
  for (const r of marketRows) {
    const m = (await snapOf(r.blockNumber)).markets.find((x) => mk(x) === mk(r) && x.spoke === lower(r.spoke));
    if (!m) {
      fail("markets", `market ${mk(r)} on ${r.spoke}: not on chain at block ${r.blockNumber}`);
      continue;
    }
    const diff = MARKET_FIELDS.filter((f) => lower((m as Json)[f]) !== lower(r[f]));
    if (diff.length > 0) fail("markets", `market ${mk(r)} on ${r.spoke} at block ${r.blockNumber}: ${diff.map((f) => `${f} chain ${(m as Json)[f]} Convex ${r[f]}`).join("; ")}`);
    else marketsEqual++;
  }
  ok("markets", `${listed.length} in the manifest, ${marketRows.length} Convex rows, ${marketsEqual} equal to the chain at their block`);
  const riskModules = integrations.map((x) => x.riskModule.address as Address);
  await sameLogs("markets", "RiskModule.MarketListed", riskModuleAbi as Abi, riskModules, eqArgs(["marketId", "pool", "kind", "bandLower", "bandUpper", "unitDecimals"]));
  await sameLogs("markets", "RiskModule.MarketActivated", riskModuleAbi as Abi, riskModules, eqArgs(["marketId", "vaultToken", "reserveId", "lpOracle"]));
  // Hub assets: the Lend and Borrow pages' supply, debt and liquidity.
  const HUB_FIELDS = ["added", "drawn", "premium", "owed", "liquidity", "deficit", "priceUsd8"];
  const hubRows = (await table("hubAssets")).filter((a) => a.chainId === chainId);
  let hubEqual = 0;
  for (const r of hubRows) {
    const a = (await snapOf(r.blockNumber)).hubAssets.find((x) => x.hub === r.hub && x.assetId === r.assetId);
    const diff = a ? HUB_FIELDS.filter((f) => lower((a as Json)[f]) !== lower(r[f])) : ["row"];
    if (diff.length > 0) fail("debts", `Hub asset ${r.hub}:${r.assetId} at block ${r.blockNumber}: ${diff.join(", ")} differ`);
    else hubEqual++;
  }
  ok("debts", `${hubEqual}/${hubRows.length} Hub asset rows (added, owed, liquidity, deficit) equal to the chain at their block`);

  // ── Accounts and positions ──
  const adapters = integrations.map((x) => x.aaveAdapter.address as Address);
  const created = await sameLogs("accounts", "AaveAdapter.AccountCreated", aaveAdapterAbi as Abi, adapters, eqArgs(["wallet", "marketId", "account"]));
  // An account's market is the market of that ID on the emitting adapter's integration, and its Spoke that market's.
  const integrationOfAdapter = (adapter: string) => Number(integrations.find((i) => lower(i.aaveAdapter.address) === lower(adapter))?.integrationId ?? -1);
  const spokeOf = (adapter: string, marketId: unknown) =>
    lower((manifest.markets as Json[]).find((m) => mk(m) === mk({ integrationId: integrationOfAdapter(adapter), marketId }))?.spoke ?? "");
  const accountRows = (await table("accounts")).filter((a) => a.chainId === chainId);
  const accountKey = (a: Json) => `${lower(a.spoke)}:${lower(a.proxy)}:${lower(a.wallet)}:${mk(a)}`;
  const chainAccounts = new Set(
    created.map((l) => accountKey({ spoke: spokeOf(l.address, l.args.marketId), proxy: l.args.account, wallet: l.args.wallet, integrationId: integrationOfAdapter(l.address), marketId: l.args.marketId })),
  );
  const convexAccounts = new Set(accountRows.map(accountKey));
  const accDiff = [...chainAccounts].filter((k) => !convexAccounts.has(k)).concat([...convexAccounts].filter((k) => !chainAccounts.has(k)));
  if (accDiff.length > 0) fail("accounts", `accounts differ: ${accDiff.slice(0, 4).join(" ")}`);
  else ok("accounts", `${accountRows.length} accounts, equal to the chain's AccountCreated`);

  const SPOKE_VIEWS = parseAbi([
    "function getUserSuppliedAssets(uint256 reserveId, address user) view returns (uint256)",
    "function getUserDebt(uint256 reserveId, address user) view returns (uint256, uint256)",
  ]);
  const at = await snapOf(sampleBlock.toString());
  const positionRows = (await table("positions")).filter((p) => p.chainId === chainId);
  const debtRows = (await table("marketReserveDebt")).filter((d) => d.chainId === chainId);
  const debts = new Map<string, { debt: bigint; borrowers: number }>();
  let positionsEqual = 0;
  let sampled = 0;
  for (const l of created) {
    const a = { spoke: spokeOf(l.address, l.args.marketId) as Address, proxy: l.args.account as Address, integrationId: integrationOfAdapter(l.address), marketId: l.args.marketId as bigint };
    const spoke = lower(a.spoke);
    const market = at.markets.find((m) => mk(m) === mk(a) && m.spoke === spoke);
    if (!market) continue; // not a listed market at the sample: the sampler skips it too
    sampled++;
    const collateral = await client.readContract({ address: a.spoke, abi: SPOKE_VIEWS, functionName: "getUserSuppliedAssets", args: [BigInt(market.reserveId), a.proxy], blockNumber: sampleBlock });
    let debtUsd8 = 0n;
    for (const r of at.spokeReserves.filter((x) => x.spoke === spoke)) {
      const [drawn, premium] = await client.readContract({ address: a.spoke, abi: SPOKE_VIEWS, functionName: "getUserDebt", args: [BigInt(r.reserveId), a.proxy], blockNumber: sampleBlock });
      const debt = drawn + premium;
      if (debt === 0n) continue;
      const k = `${mk(market)}:${spoke}:${r.reserveId}`;
      const d = debts.get(k) ?? { debt: 0n, borrowers: 0 };
      debts.set(k, { debt: d.debt + debt, borrowers: d.borrowers + 1 });
      const asset = at.hubAssets.find((h) => h.hub === r.hub && h.assetId === r.assetId);
      if (asset) debtUsd8 += (debt * BigInt(asset.priceUsd8)) / 10n ** BigInt(asset.decimals);
    }
    const collateralUsd8 = (collateral * BigInt(market.acceptedPrice)) / 10n ** BigInt(market.vaultDecimals);
    const row = positionRows.find((p) => p.spoke === spoke && p.proxy === lower(a.proxy));
    const want = { blockNumber: sampleBlock.toString(), integrationId: String(market.integrationId), marketId: market.marketId, collateralUnits: collateral.toString(), collateralUsd8: collateralUsd8.toString(), debtUsd8: debtUsd8.toString() };
    const diff = row ? Object.entries(want).filter(([k, v]) => String(row[k]) !== v) : [["row", "missing"]];
    if (diff.length > 0) fail("positions", `${spoke}:${lower(a.proxy)}: ${diff.map(([k, v]) => `${k} chain ${v} Convex ${row ? row[k] : "none"}`).join("; ")}`);
    else positionsEqual++;
  }
  ok("positions", `${positionsEqual}/${sampled} positions equal to the chain at the daily sample block ${sampleBlock}`);
  let debtsEqual = 0;
  for (const [k, d] of debts) {
    const [integrationId, marketId, spoke, reserveId] = k.split(":");
    const row = debtRows.find((x) => mk(x) === `${integrationId}:${marketId}` && x.spoke === spoke && x.reserveId === reserveId);
    if (!row || row.debt !== d.debt.toString() || row.borrowers !== d.borrowers || row.blockNumber !== sampleBlock.toString())
      fail("debts", `market ${integrationId}:${marketId} reserve ${spoke}:${reserveId}: chain ${d.debt} (${d.borrowers} borrowers) at ${sampleBlock}, Convex ${row ? `${row.debt} (${row.borrowers}) at ${row.blockNumber}` : "none"}`);
    else debtsEqual++;
  }
  // A market's debt in a reserve the chain no longer holds (repaid, liquidated) must not stay on its page.
  const stale = debtRows.filter((x) => !debts.has(`${mk(x)}:${x.spoke}:${x.reserveId}`) && x.debt !== "0");
  for (const x of stale) fail("debts", `market ${mk(x)} reserve ${x.spoke}:${x.reserveId}: Convex keeps ${x.debt} (${x.borrowers} borrowers, block ${x.blockNumber}); the chain has none at ${sampleBlock}`);
  ok("debts", `${debtsEqual}/${debts.size} market debts equal to the chain at block ${sampleBlock}; ${stale.length} stale rows`);
  const cdpSpokes = manifest.aave.borrowSpokes.map((s: Json) => s.address as Address);
  for (const e of ["Borrow", "Repay", "ReportDeficit"]) await sameLogs("debts", `AaveSpoke.${e}`, aaveV4SpokeAbi as Abi, cdpSpokes);

  // ── Liquidations ──
  const modules = integrations.map((x) => x.liquidationModule.address as Address);
  const settled = await sameLogs("liquidations", "LiquidationModule.Liquidated", liquidationModuleAbi as Abi, modules, eqArgs(["account", "marketId", "liquidator", "debtReserveId", "debtRepaid", "seized", "creditUnwound", "amount0", "amount1"]));
  await sameLogs("liquidations", "LiquidationModule.FeePaid", liquidationModuleAbi as Abi, modules, eqArgs(["account", "marketId", "recipient", "units", "fee0", "fee1"]));
  // Daily rollups: each UTC day holding a liquidation, rolled up as the 00:30 cron does, counts the chain's. A
  // liquidation's market is the market of that ID on the emitting LiquidationModule's integration.
  const integrationOfModule = (module: string) => Number(integrations.find((i) => lower(i.liquidationModule.address) === lower(module))?.integrationId ?? -1);
  const perDay = new Map<string, number>();
  for (const l of settled) {
    const t = Number((await client.getBlock({ blockNumber: l.blockNumber })).timestamp) * 1000;
    const k = `${mk({ integrationId: integrationOfModule(l.address), marketId: l.args.marketId })}|${new Date(t).toISOString().slice(0, 10)}`;
    perDay.set(k, (perDay.get(k) ?? 0) + 1);
  }
  for (const day of new Set([...perDay.keys()].map((k) => k.split("|")[1]!))) run("rollups:rollUp", { nowMs: Date.parse(`${day}T00:00:00Z`) + 86_400_000 + 1_800_000 });
  const rollups = (await table("dailyRollups")).filter((r) => r.chainId === chainId && r.scopeKind === "market");
  let rollupsEqual = 0;
  for (const [k, n] of perDay) {
    const [market, day] = k.split("|");
    const r = rollups.find((x) => x.scopeKey === `${chainId}:${market}` && x.day === day);
    if (!r || r.values.liquidations !== n) fail("liquidations", `market ${market} on ${day}: chain ${n} liquidations, rollup ${r ? r.values.liquidations : "none"}`);
    else rollupsEqual++;
  }
  ok("liquidations", `${rollupsEqual}/${perDay.size} market-days rolled up with the chain's liquidation count`);

  // ── Payouts ──
  // Repay with collateral, and both loss layers (each First-Loss Reserve and the DAO deficit offset behind it).
  await sameLogs("payouts", "FlashloanRepay.RepaidWithCollateral", flashloanRepayAbi as Abi, integrations.map((x) => x.flashloanRepay.address as Address), eqArgs(["wallet", "positionKey", "asset", "repaid", "premium", "liquidity"]));
  const layers = [...manifest.coverage.firstLossReserves, ...manifest.coverage.daoDeficitOffsets].map((l: Json) => l.address as Address);
  await sameLogs("payouts", "FirstLossReserve.DeficitCovered", firstLossReserveAbi as Abi, layers, eqArgs(["spoke", "caller", "covered", "shares", "balanceAfter"]));
  await sameLogs("payouts", "FirstLossReserve.Funded", firstLossReserveAbi as Abi, layers, eqArgs(["funder", "amount", "shares", "balanceAfter"]));

  // ── Intents ──
  // One protocol transaction of the rehearsal (a liquidation, else an account creation), one transaction without logs
  // and one that reverts, sent now as an unlocked account (anvil --auto-impersonate: no key).
  const protocolTx = (settled[0] ?? created[0]) as Json | undefined;
  const sender = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8" as Address;
  const quiet = await client.request({ method: "eth_sendTransaction" as never, params: [{ from: sender, to: sender, value: "0x0" }] as never });
  const reverted = await client.request({
    method: "eth_sendTransaction" as never,
    params: [{ from: sender, to: adapters[0], gas: "0x30000", data: "0xdeadbeef" }] as never,
  });
  await client.request({ method: "evm_mine" as never, params: [] as never });
  const intents: { tx: Hex; wallet: Address; kind: string; want: string }[] = [
    { tx: quiet as Hex, wallet: sender, kind: "approve", want: "included" },
    { tx: reverted as Hex, wallet: sender, kind: "borrow", want: "failed" },
  ];
  if (protocolTx) {
    const tx = await client.getTransaction({ hash: protocolTx.transactionHash });
    intents.unshift({ tx: protocolTx.transactionHash, wallet: lower(tx.from) as Address, kind: settled[0] ? "repay" : "pledge", want: "indexed" });
  } else fail("intents", "the rehearsal holds no liquidation or account creation to track");
  for (const i of intents) run("intents:submit", { wallet: i.wallet, chainId, txHash: i.tx, kind: i.kind }, { subject: i.wallet, issuer: "http://127.0.0.1:3000", tokenIdentifier: `replay|${i.wallet}` });
  run("intents:track", { chainId });
  const intentRows = (await table("intents")).filter((r) => r.chainId === chainId);
  for (const i of intents) {
    const r = intentRows.find((x) => x.txHash === lower(i.tx));
    if (!r || r.status !== i.want) fail("intents", `${i.kind} ${i.tx}: want ${i.want}, Convex ${r?.status ?? "none"}`);
    else ok("intents", `${i.kind} ${i.tx.slice(0, 10)}…: ${r.status}`);
  }
}
