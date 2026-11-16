// Dumps the sandbox's market catalog and seed (read only) to a raw JSON file.
// Run from a checkout of avana-sandbox with that checkout's tsx and tsconfig, for example:
//   cd ../avana-sandbox-ref && ./node_modules/.bin/tsx --tsconfig ./tsconfig.json \
//     ../avana-monorepo/webapp/tests/parity/dump-sandbox-seed.ts /tmp/seed-raw.json
// Then shape it: node webapp/tests/parity/shape-sandbox-markets.mjs /tmp/seed-raw.json webapp/parity/sandbox-markets.json <sandbox commit>
import { writeFileSync } from "node:fs"
import { buildBorrowSeed } from "@/app/lib/convex-seed/build-seed"
import { BORROW_DEXES, BORROW_SPOKES, BORROW_POOL_CATALOG, BORROWABLE_ASSETS } from "@/app/lib/borrow-sim"
import { LEND_ASSET_GROUPS, LEND_FEATURED_ASSETS } from "@/app/lib/data/catalog/lend"
import { SANDBOX_NOW } from "@/app/lib/deterministic"
import { PRICE_FIXTURE } from "@/app/lib/prices/price-fixture"
import { poolLpTokenPriceUsd } from "@/app/lib/borrow-sim"
const out = process.argv[2]
const seed = buildBorrowSeed()
type DayRow = { slug: string; day: string }
const lastBy = <T extends DayRow>(rows: T[]) => {
  const m: Record<string, T> = {}
  for (const r of rows) {
    if (!m[r.slug] || m[r.slug].day < r.day) m[r.slug] = r
  }
  return m
}
const raw = {
  sandboxNow: SANDBOX_NOW,
  priceFixture: PRICE_FIXTURE,
  lpPrices: Object.fromEntries(BORROW_POOL_CATALOG.map((p) => [p.id, poolLpTokenPriceUsd(p)])),
  dexes: BORROW_DEXES,
  spokes: BORROW_SPOKES,
  pools: BORROW_POOL_CATALOG,
  borrowables: BORROWABLE_ASSETS,
  lendGroups: LEND_ASSET_GROUPS,
  lendFeatured: LEND_FEATURED_ASSETS,
  seed: {
    borrowMarkets: seed.borrowMarkets,
    lendMarkets: seed.lendMarkets,
    borrowLatest: lastBy(seed.borrowDailyStats),
    lendLatest: lastBy(seed.lendDailyStats),
    spokes: seed.spokes,
    dexes: seed.dexes,
    borrowAssets: seed.borrowAssets,
    borrowPoolBorrowables: seed.borrowPoolBorrowables,
    borrowRiskParameters: seed.borrowRiskParameters,
    lendRiskParameters: seed.lendRiskParameters,
    borrowInterestRateModels: seed.borrowInterestRateModels,
    lendInterestRateModels: seed.lendInterestRateModels,
    poolContractAddresses: seed.poolContractAddresses,
    walletCollateralPositions: seed.walletCollateralPositions,
    walletDebts: seed.walletDebts,
  },
}
writeFileSync(
  out,
  JSON.stringify(raw, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2),
)
process.stdout.write(`wrote ${out}
`)
