// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Step 09-market-metadata: writes the listing metadata file of the next `09-listing-markets` operation, the pages that
// listing adds: one `pool` entry per market of `listing.markets` and one `asset` entry per debt reserve of
// `listing.debtReserves`, with the text of their `content` in the network config. The format is the one Convex loads
// (services/convex/convex/lib/metadata.ts, version 1). The listing operation's timelock salt is keccak256 of the file's
// exact bytes, so the file is written once here and `09-listing-markets` reads the same bytes back and checks the hash.
//
// Only what the listing adds gets a page: the config's markets not listed yet, which take the IDs after
// `MarketRegistry.marketCount()` in config order (the rule `09-listing-markets` applies; it refuses a file written for
// other IDs) or, for a cancelled market relisted, its reserved ID, and the debt reserves not enabled yet. With nothing
// new, no file is written.
//
// Outputs, under deployments-local/<network>/:
//   listing-content/<hash>.json   the file, published at <LISTING_CONTENT_URL>/<hash>.json
//   listing-metadata.json         { hash, file, chainId, firstMarketId, entries }
//
// Usage, from contracts/:  AVANA_NETWORK=anvil AVANA_RPC_URL=http://127.0.0.1:8545 node script/deploy/market-metadata.ts

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type Address, createPublicClient, getAddress, http, keccak256, parseAbi } from "viem";
import { MetadataRejected, parseMetadata } from "../../../services/convex/convex/lib/metadata.ts";

const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const network = process.env.AVANA_NETWORK ?? "anvil";
const rpc = process.env.AVANA_RPC_URL;
if (!rpc) throw new Error("set AVANA_RPC_URL");
const OUT = join(CONTRACTS, "deployments-local", network);

type Json = Record<string, any>;
const config = JSON.parse(readFileSync(process.env.AVANA_CONFIG ? join(CONTRACTS, process.env.AVANA_CONFIG) : join(CONTRACTS, "script/deploy/config", `${network}.json`), "utf8")) as Json;

/** A JSON path of the form `.a.b['c'][0]`, as the deploy scripts write references. */
function at(json: unknown, path: string): unknown {
  let v: any = json;
  for (const m of path.matchAll(/\.([A-Za-z0-9_]+)|\['([^']+)'\]|\[(\d+)\]/g)) v = v?.[m[1] ?? m[2] ?? Number(m[3])];
  return v;
}

/** An address, literal or a `$<file>:<path>` reference to an earlier step's output (DeployInputs._addr). */
function addr(v: string): Address {
  if (!v.startsWith("$")) return getAddress(v);
  const [file, path] = v.slice(1).split(":") as [string, string];
  const out = at(JSON.parse(readFileSync(join(OUT, `${file}.json`), "utf8")), path);
  if (typeof out !== "string") throw new Error(`reference ${v} resolves to nothing: run the step that writes ${file}.json`);
  return getAddress(out);
}

const lower = (a: Address) => a.toLowerCase();
const pct = (bps: number) => `${(bps / 100).toLocaleString("en-US", { maximumFractionDigits: 2 })}%`;
const usd = (whole: string) => `$${BigInt(whole).toLocaleString("en-US")}`;

const client = createPublicClient({ transport: http(rpc) });
const abi = parseAbi([
  "function marketCount() view returns (uint256)",
  "function marketOfKey(bytes32 key) view returns (uint256)",
  "function isApprovedDebtReserve(address spoke, uint256 reserveId) view returns (bool)",
  "function marketKeyOf(uint32 integrationId, address pool, bytes32 poolId, (uint8 kind, int24 tickLower, int24 tickUpper) shape) view returns (bytes32)",
  "function tickSpacing() view returns (int24)",
  "function tokenOf(address spoke, bytes32 marketKey) view returns (address)",
  "function marketId() view returns (uint256)",
  "function getAssetId(address underlying) view returns (uint256)",
  "function getReserveId(address hub, uint256 assetId) view returns (uint256)",
]);

/** The market's VaultTokenFactory key: integration, pool and tick range (the pool's full range when both are 0), as
 * `09-listing-markets` computes it. */
async function marketKey(factory: Address, m: Json): Promise<`0x${string}`> {
  const pool = addr(config.listing.pools[m.pool]);
  let [lower, upper] = [Number(m.tickLower), Number(m.tickUpper)];
  if (lower === 0 && upper === 0) {
    const sp = await client.readContract({ address: pool, abi, functionName: "tickSpacing" });
    upper = Math.trunc(887_272 / sp) * sp;
    lower = -upper;
  }
  return client.readContract({
    address: factory,
    abi,
    functionName: "marketKeyOf",
    args: [m.integrationId, pool, `0x${"0".repeat(64)}`, { kind: 1, tickLower: lower, tickUpper: upper }],
  });
}

const spokes = config.listing.spokes as { label: string; hub: string; spoke: string }[];
const spokeOf = (label: string) => {
  const s = spokes.find((x) => x.label === label);
  if (!s) throw new Error(`listing.spokes has no ${label}`);
  const hub = (config.aave.hubs as { label: string; hub: string }[]).find((h) => h.label === s.hub);
  if (!hub) throw new Error(`aave.hubs has no ${s.hub}`);
  return { spoke: addr(s.spoke), hub: addr(hub.hub) };
};
const debtAsset = (symbol: string) => {
  const d = (config.listing.debtAssets as { symbol: string; address: string }[]).find((x) => x.symbol === symbol);
  if (!d) throw new Error(`listing.debtAssets has no ${symbol}`);
  return addr(d.address);
};

/** The page text of a config entry: every field but the generated ones, which the config may not set. */
function text(where: string, c: Json | undefined) {
  if (!c) throw new Error(`${where} has no content`);
  for (const f of ["slug", "name", "description", "faqs"]) if (c[f] === undefined) throw new Error(`${where}.content.${f} missing`);
  const { stats: _s, history: _h, ...rest } = c;
  return rest;
}

async function main() {
  const chainId = await client.getChainId();
  const block = await client.getBlock();
  const date = new Date(Number(block.timestamp) * 1000).toISOString().slice(0, 10);
  const avana = JSON.parse(readFileSync(join(OUT, "avana.json"), "utf8")) as Json;
  const registry = addr(avana.marketRegistry.proxy);
  const factory = addr(avana.vaultTokenFactory);
  const firstMarketId = (await client.readContract({ address: registry, abi, functionName: "marketCount" })) + 1n;

  // Pages only for what this listing adds: markets not listed yet (the next IDs, in config order) and debt reserves
  // not enabled yet. A market or reserve listed earlier kept the page of its own listing.
  const entries: Json[] = [];
  let next = firstMarketId;
  for (const [i, m] of (config.listing.markets as Json[]).entries()) {
    const key = await marketKey(factory, m);
    const listed = await client.readContract({ address: registry, abi, functionName: "marketOfKey", args: [key] });
    if (listed !== 0n) continue;
    // A cancelled market is relisted under its reserved ID (its vault token names it); a new one takes the next ID.
    const token = await client.readContract({ address: factory, abi, functionName: "tokenOf", args: [spokeOf(m.spoke).spoke, key] });
    const id = /^0x0{40}$/i.test(token) ? next++ : await client.readContract({ address: token, abi, functionName: "marketId" });
    entries.push({
      scope: "pool",
      key: String(id),
      ...text(`listing.markets[${i}]`, m.content),
      stats: [
        { label: "Collateral factor", value: pct(m.collateralFactorBps) },
        { label: "Liquidation bonus, at most", value: pct(m.maxLiquidationBonus - 10_000) },
        { label: "Market cap", value: usd(m.marketUsdCap) },
        { label: "Smallest pledge", value: usd(m.minPledgeUsd) },
      ],
      history: [{ date, title: "Listing scheduled", description: "Governance scheduled the listing on the Avana timelock." }],
    });
  }
  for (const [i, d] of (config.listing.debtReserves as Json[]).entries()) {
    const { spoke, hub } = spokeOf(d.spoke);
    const assetId = await client.readContract({ address: hub, abi, functionName: "getAssetId", args: [debtAsset(d.symbol)] });
    const reserveId = await client.readContract({ address: spoke, abi, functionName: "getReserveId", args: [hub, assetId] });
    if (await client.readContract({ address: registry, abi, functionName: "isApprovedDebtReserve", args: [spoke, reserveId] })) continue;
    entries.push({
      scope: "asset",
      key: `${lower(spoke)}:${reserveId}`,
      ...text(`listing.debtReserves[${i}]`, d.content),
      stats: [],
      history: [{ date, title: "Borrowing scheduled", description: "Governance scheduled the debt reserve's activation for listed markets on the Avana timelock." }],
    });
  }

  if (entries.length === 0) {
    // Nothing new to show: the listing operation (if any, new routes only) takes a salt of its own.
    writeFileSync(join(OUT, "listing-metadata.json"), `${JSON.stringify({ hash: null, file: null, chainId, firstMarketId: Number(firstMarketId), entries: 0 }, null, 2)}\n`);
    process.stdout.write(`listing metadata: no new market or debt reserve in the config (next market ID ${firstMarketId})\n`);
    return;
  }
  const bytes = new TextEncoder().encode(`${JSON.stringify({ version: 1, chainId, entries }, null, 2)}\n`);
  const hash = keccak256(bytes);
  // The app checks the file only after the listing operation executes, when its hash is already the operation's salt:
  // a file it refuses then leaves the new pages without text. The same check runs here, before anything is scheduled.
  try {
    parseMetadata(bytes, hash, chainId);
  } catch (e) {
    if (e instanceof MetadataRejected) throw new Error(`the app would refuse this listing metadata: ${e.message}`);
    throw e;
  }
  mkdirSync(join(OUT, "listing-content"), { recursive: true });
  const file = join("listing-content", `${hash}.json`);
  writeFileSync(join(OUT, file), bytes);
  writeFileSync(
    join(OUT, "listing-metadata.json"),
    `${JSON.stringify({ hash, file, chainId, firstMarketId: Number(firstMarketId), entries: entries.length }, null, 2)}\n`,
  );
  process.stdout.write(`listing metadata ${hash}: ${entries.length} pages, markets from ${firstMarketId}, ${join(OUT, file)}\n`);
}

main().catch((e: unknown) => {
  process.stderr.write(`${(e as Error).message}\n`);
  process.exit(1);
});
