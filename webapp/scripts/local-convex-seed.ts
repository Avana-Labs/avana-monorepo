// Loads fixture data into a local Convex deployment so the web app can run against services/convex
// without a chain or an indexer. It writes the fixture chain's deployment row and its snapshot (three
// Hubs: Stable, Core and a third the manifest does not name, with their Lend and CDP Spokes, Hub
// assets and markets), the same rows the indexer export would produce, plus the token names and symbols the
// listing metadata would give.
//
// Usage, from the repository root, with `npx convex dev` running in services/convex:
//   node webapp/scripts/local-convex-seed.ts
// Refuses to run unless services/convex/.env.local points at a local deployment (127.0.0.1 or localhost).
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import { createRequire } from "node:module"
import path from "node:path"
import { fileURLToPath } from "node:url"
import {
  GHO,
  USDC,
  USDT,
  fakeChainClient,
  fixtureHubsChain,
  fixtureHubsDeployment,
} from "../../services/common/src/views/fixtures.ts"
import { readChainSnapshot } from "../../services/common/src/views/snapshot.ts"

const convexDir = fileURLToPath(new URL("../../services/convex/", import.meta.url))
const envFile = path.join(convexDir, ".env.local")
const env = fs.existsSync(envFile) ? fs.readFileSync(envFile, "utf8") : ""
const url = env.match(/^CONVEX_URL=(.+)$/m)?.[1]?.trim()
if (!url || !/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(url)) {
  throw new Error(`services/convex/.env.local must point at a local deployment (found ${url ?? "none"})`)
}

const FIXTURE_EXPLORER = "https://etherscan.io"
const FIXTURE_ADDRESS = (byte: string) => `0x${byte.repeat(20)}`

const json = (value: unknown) => JSON.stringify(value, (_key, v) => (typeof v === "bigint" ? v.toString() : v))

// The Convex CLI, run by this Node directly: no shell, so the JSON arguments reach it unchanged.
const convexCli = path.join(
  path.dirname(createRequire(path.join(convexDir, "package.json")).resolve("convex/package.json")),
  "bin",
  "main.js",
)

function run(fn: string, args: unknown) {
  execFileSync(process.execPath, [convexCli, "run", fn, json(args)], {
    cwd: convexDir,
    stdio: ["ignore", "inherit", "inherit"],
  })
}

const dep = fixtureHubsDeployment
run("deployments:setDeployment", {
  chainId: dep.chainId,
  lens: dep.lens,
  hubs: dep.hubs.map((hub, tier) => ({ address: hub.address, label: hub.label ?? `Hub ${tier + 1}`, tier })),
  lendSpokes: [...dep.lendSpokes],
  cdpSpokes: [...dep.cdpSpokes],
  firstLossReserves: dep.firstLossReserves.map((r) => ({
    address: r.address,
    asset: r.asset,
    ...(r.hub ? { hub: r.hub } : {}),
  })),
  marketRegistry: dep.marketRegistry,
  timelock: FIXTURE_ADDRESS("71"),
  explorerUrl: FIXTURE_EXPLORER,
  nativeUsdFeed: FIXTURE_ADDRESS("72"),
  release: "v0.0.0-local",
})

// Token names and symbols, which the snapshot import reads from listing metadata; without them a token shows its address.
const tokens = [
  { address: USDC, symbol: "USDC", name: "USD Coin" },
  { address: USDT, symbol: "USDT", name: "Tether USD" },
  { address: GHO, symbol: "GHO", name: "GHO" },
]
run("listing/store:store", {
  chainId: dep.chainId,
  operationId: "local-fixture-tokens",
  contentHash: "0x00",
  entries: tokens.map((t) => ({
    scope: "token",
    key: t.address.toLowerCase(),
    slug: t.symbol.toLowerCase(),
    name: t.name,
    symbol: t.symbol,
    category: "stable",
    description: `${t.name} (fixture token).`,
    stats: [],
    history: [],
    faqs: [],
  })),
})

const snapshot = await readChainSnapshot(fakeChainClient(fixtureHubsChain.later), dep, {
  blockNumber: 1_000n,
  timestamp: Math.floor(Date.now() / 1000),
})
run("ingest/apply:applySnapshot", { snapshot })
console.log(
  `Seeded ${url}: ${snapshot.hubs.length} Hubs, ${snapshot.hubAssets.length} Hub assets, ` +
    `${snapshot.spokeReserves.length} Spoke reserves, ${snapshot.markets.length} markets`,
)
