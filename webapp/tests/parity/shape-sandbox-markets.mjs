// Shapes the raw dump of dump-sandbox-seed.ts into webapp/parity/sandbox-markets.json.
import fs from "node:fs"
import process from "node:process"

const omit = (obj, keys) => Object.fromEntries(Object.entries(obj).filter(([k]) => !keys.includes(k)))
const [rawPath, outPath, sandboxCommit] = process.argv.slice(2)
const r = JSON.parse(fs.readFileSync(rawPath, "utf8"))
const s = r.seed
const num = (v) => {
  const m = String(v)
    .replace(/[$,%x]/g, "")
    .trim()
    .match(/^(-?[\d.]+)\s*([KMB])?$/i)
  if (!m) return null
  const k = { K: 1e3, M: 1e6, B: 1e9 }[(m[2] || "").toUpperCase()] || 1
  return +(+m[1] * k).toFixed(6)
}
const params = (rows, slug) => {
  const row = rows.find((x) => x.slug === slug)
  if (!row) return null
  const o = {}
  for (const p of row.parameters) {
    const range = String(p.value).split(" - ")
    o[p.id] = {
      label: p.label,
      display: p.value,
      value: range.length === 2 ? [num(range[0]), num(range[1])] : (num(p.value) ?? p.value),
    }
  }
  return o
}
const irm = (rows, slug) => {
  const x = rows.find((y) => y.slug === slug)
  if (!x) return null
  return omit(x, ["slug", "updatedAt", "source"])
}
const latest = (m, slug) => {
  const x = m[slug]
  if (!x) return null
  return omit(x, ["slug", "kind"])
}
const visual = (v) => v && { symbol: v.symbol, iconUrl: v.iconUrl ?? null }

const HUB_BY_SPOKE = {
  "uni-v3-stable": "stable",
  "curve-stable": "stable",
  "bal-stable": "stable",
  "aero-basic-stable": "stable",
  "curve-correlated": "correlated",
  "bal-correlated": "correlated",
  "bal-boosted": "correlated",
}
const NATIVE = new Set(["uni-v3-stable", "uni-v3-bluechip", "uni-v3-gov", "aero-slipstream-bluechip"])
const STOCKS = new Set(["uni-robinhood-stocks", "aero-concentrated-stocks"])
const onchainFor = (spoke) => {
  const dex = r.spokes.find((x) => x.id === spoke).dex
  const integration = dex === "aerodrome" ? "slipstream" : "uniswapV3"
  return {
    chain: integration === "slipstream" ? "base" : "ethereum",
    integration,
    hub: HUB_BY_SPOKE[spoke] ?? "volatile",
    support: NATIVE.has(spoke) ? "native" : STOCKS.has(spoke) ? "emulated-stock-tokens" : "emulated-venue",
  }
}

const poolCat = Object.fromEntries(r.pools.map((p) => [p.id, p]))
const spokes = r.spokes.map((sp) => {
  const seedRow = s.spokes.find((x) => x.id === sp.id)
  return {
    id: sp.id,
    slug: seedRow?.slug ?? null,
    venue: sp.dex,
    label: sp.label,
    description: sp.description,
    eMode: sp.eMode,
    isSmartSpoke: seedRow?.isSmartSpoke ?? null,
    maxLtvPct: sp.maxLtv,
    riskPremiumBps: sp.riskPremiumBps,
    aprApproxPct: sp.aprApprox,
    liquidityUsd: sp.liquidityUsd,
    liquidationUsdApprox: sp.liquidationUsdApprox,
    borrowableSymbols: sp.borrowableTokens.map((t) => t.symbol),
    lpMarketSlugs: s.borrowMarkets.filter((m) => m.kind === "pool" && m.spokeId === sp.id).map((m) => m.slug),
    debtReserveSlugs: s.borrowAssets.filter((a) => a.spokeId === sp.id).map((a) => a.id),
    proposedOnchain: onchainFor(sp.id),
  }
})

const lpMarkets = s.borrowMarkets
  .filter((m) => m.kind === "pool")
  .map((m) => {
    const c = poolCat[m.slug] ?? {}
    return {
      slug: m.slug,
      name: m.name,
      symbol: m.symbol,
      spoke: m.spokeId,
      venueLabel: m.venueLabel,
      feeTier: m.feeTier,
      description: m.description,
      category: m.category ?? null,
      constituents: c.constituents ?? null,
      legs: (m.visuals ?? []).map(visual),
      lpTokenPriceUsd: r.lpPrices[m.slug] ?? null,
      seedPriceUsd: m.priceUsd ?? null,
      maxLtvPct: m.maxLtvPct,
      catalogRiskPremiumBps: c.riskPremiumBps ?? null,
      catalogAprRangePct: c.aprMin != null ? [c.aprMin, c.aprMax] : null,
      reserveFactorPct: m.reserveFactorPct,
      rewardsApyPct: m.rewardsApyPct,
      catalogTvlUsd: c.tvlUsd ?? null,
      catalogAvailableUsd: c.availableUsd ?? null,
      riskParameters: params(s.borrowRiskParameters, m.slug),
      latestDay: latest(s.borrowLatest, m.slug),
      borrowables: s.borrowPoolBorrowables
        .filter((e) => e.poolSlug === m.slug)
        .map((e) => ({ debtReserve: e.assetSlug, symbol: e.symbol, borrowAprPct: e.borrowAprPct })),
      proposedOnchain: onchainFor(m.spokeId),
    }
  })

const debtReserves = s.borrowAssets.map((a) => ({
  slug: a.id,
  spoke: a.spokeId,
  baseAsset: a.baseAssetId,
  symbol: a.symbol,
  name: a.name,
  category: a.category,
  subtitle: a.subtitle,
  contextLabel: a.contextLabel,
  icon: visual(a.displayVisual),
  baseBorrowAprPct: a.baseBorrowAprPct,
  totalCapacityUsd: a.totalCapacityUsd,
  utilizationPct: a.utilizationPct,
  totalBorrowedUsd: a.totalBorrowedUsd,
  availableUsd: a.availableUsd,
  reserveFactorPct: a.reserveFactorPct ?? null,
  lpMarketSlugs: a.marketIds,
  interestRateModel: irm(s.borrowInterestRateModels, a.id),
  riskParameters: params(s.borrowRiskParameters, a.id),
  latestDay: latest(s.borrowLatest, a.id),
}))

const GROUPS = ["stablecoins", "eth", "btc", "governance", "stocks"]
const lendRows = Object.fromEntries(
  r.lendGroups.flatMap((g, i) => g.rows.map((row) => [row.symbol.toLowerCase(), { ...row, groupIndex: i }])),
)
const lendAssets = s.lendMarkets.map((m) => {
  const row = lendRows[m.slug] ?? {}
  return {
    slug: m.slug,
    symbol: m.symbol,
    name: m.name,
    category: m.category,
    group: GROUPS[row.groupIndex] ?? null,
    issuerLabel: row.hub ?? null,
    icon: row.logoSrc ?? m.iconUrl ?? null,
    priceUsd: m.priceUsd ?? null,
    reserveFactorPct: m.reserveFactorPct,
    rewardsApyPct: m.rewardsApyPct,
    catalogDisplay: {
      apy: row.apy ?? null,
      totalDeposits: [row.totalDepositsPrimary ?? null, row.totalDepositsSecondary ?? null],
      available: [row.availableLiquidityPrimary ?? null, row.availableLiquiditySecondary ?? null],
    },
    interestRateModel: irm(s.lendInterestRateModels, m.slug),
    riskParameters: params(s.lendRiskParameters, m.slug),
    latestDay: latest(s.lendLatest, m.slug),
  }
})

const sum = (a, f) => Math.round(a.reduce((t, x) => t + (f(x) ?? 0), 0))
const count = (a, f) => a.reduce((m, x) => ((m[f(x)] = (m[f(x)] || 0) + 1), m), {})
const out = {
  version: 1,
  source: {
    repo: "avana-sandbox",
    commit: sandboxCommit,
    generator:
      "app/lib/convex-seed/build-seed.ts buildBorrowSeed() with default options, plus app/lib/borrow-sim.ts, app/lib/data/catalog/lend and app/lib/prices/price-fixture.ts",
    asOf: new Date(r.sandboxNow).toISOString().slice(0, 10),
    chainIdInSandbox: 1,
    note: "Values a fresh seed writes to the sandbox Convex (fixed SANDBOX_NOW clock). The live sandbox deployment drifts from them through user activity (shared liquidity ledger, daily rollups) and live token prices. latestDay is the seed's last daily row per market.",
  },
  summary: {
    venues: r.dexes.length,
    spokes: spokes.length,
    lpMarkets: lpMarkets.length,
    debtReserves: debtReserves.length,
    lendAssets: lendAssets.length,
    lpMarketsBySupport: count(lpMarkets, (x) => x.proposedOnchain.support),
    lpMarketsByProposedChain: count(lpMarkets, (x) => x.proposedOnchain.chain),
    debtReserveSymbols: [...new Set(debtReserves.map((x) => x.symbol))],
    totalsLatestDay: {
      borrowPoolTvlUsd: sum(lpMarkets, (x) => x.latestDay?.tvlUsd),
      borrowPoolBorrowedUsd: sum(lpMarkets, (x) => x.latestDay?.borrowedUsd),
      debtReserveBorrowedUsd: sum(debtReserves, (x) => x.latestDay?.borrowedUsd),
      lendSuppliedUsd: sum(lendAssets, (x) => x.latestDay?.suppliedUsd),
      lendBorrowedUsd: sum(lendAssets, (x) => x.latestDay?.borrowedUsd),
    },
  },
  proposedHubs: [
    { label: "stable", spokes: spokes.filter((x) => x.proposedOnchain.hub === "stable").map((x) => x.id) },
    { label: "correlated", spokes: spokes.filter((x) => x.proposedOnchain.hub === "correlated").map((x) => x.id) },
    { label: "volatile", spokes: spokes.filter((x) => x.proposedOnchain.hub === "volatile").map((x) => x.id) },
  ],
  proposedMappingNotes: [
    "Every proposedOnchain field is a proposal for the stack session and Josue, not a decision. The sandbox has no Hubs and runs every market on one chain (chainId 1, shown as Testnet); Hub, chain and integration per Spoke are inferred from the Spoke's pairs and venue.",
    "support=native: the venue has an Avana integration (Uniswap v3 or Slipstream). support=emulated-venue: Avana has no integration for the venue (Uniswap v2, Curve, Balancer, Aerodrome basic pools); a concentrated-liquidity position would stand in under the sandbox's names and labels. support=emulated-stock-tokens: also needs local test tokens for the tokenized stocks.",
    "The anvil deploy config lists GHO and USDC as debt assets. The sandbox's other borrowable symbols (see summary.debtReserveSymbols) need debt reserves on the Hubs.",
    "Lend assets ETH and BTC are native-asset labels in the sandbox; on chain they would be wrapped tokens or local test tokens with those symbols.",
  ],
  tokensUsd: Object.fromEntries(
    Object.entries(r.priceFixture).filter(([k]) => !(k.endsWith("C") && k.slice(0, -1) in r.priceFixture)),
  ),
  venues: r.dexes.map((d) => ({ id: d.id, label: d.label, tvlUsd: d.tvlUsd })),
  spokes,
  lpMarkets,
  debtReserves,
  lendAssets,
}
fs.writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n")
process.stdout.write(`${JSON.stringify(out.summary, null, 1)}\n`)
