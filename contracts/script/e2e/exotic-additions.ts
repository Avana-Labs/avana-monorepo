// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local rehearsal's exotic pass (rehearsal 08): pools and borrowable assets far from the stable and WETH markets,
// added to the day-2 config (deployments-local/<network>/config-day2.json) and written to config-exotic.json. The
// deploy steps then run again with AVANA_CONFIG pointing at that file and act only on what it adds:
//   1. a new Hub, `exotic` (tier 3), with its Lend Spoke `lendExotic`, a Uniswap v3 CDP Spoke `uniV3Exotic` and a
//      Slipstream CDP Spoke `slipExotic`;
//   2. three debt assets new to Aave: PEPE (a meme coin, 18 decimals, $0.00001), AAVE (a governance token) and WBTC
//      (8 decimals, $95,000), each with its DebtOracle. The exotic Hub lends USDC, PEPE, AAVE and WBTC; borrowing is
//      mixed per Spoke: uniV3Exotic all four, slipExotic USDC and WBTC, and WBTC also on the volatile Hub's
//      uniV3Volatile (its listed markets get routes into WBTC);
//   3. seven collateral tokens (PEPE, AAVE, UNI, WBTC, THIN, AERO, cbBTC) and ten markets: Uniswap v3 PEPE/WETH 1 %,
//      PEPE/USDC 1 %, AAVE/WETH, UNI/WETH, AAVE/UNI 0.3 %, WBTC/PEPE 1 % (the widest decimals and price gap),
//      WBTC/USDC 0.3 %, THIN/USDC 1 % (a $20k pool), and Slipstream AERO/USDC (tick spacing 200) and cbBTC/USDC (100).
// Each market's collateral factor is min(token collateral factors) x its pool risk factor (SPEC-CF-001); its slippage
// allowance is the largest the fee bound allows at its minimum liquidation bonus (LIQ-I1); its routes, from each pool
// token into each asset its Spoke lends, are found by search (routes.ts).
//
// Usage, from contracts/:  node script/e2e/exotic-additions.ts --network anvil

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type Route, addRoutePools, poolOf, routePair } from "./routes.ts";

type Json = Record<string, any>;
const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const i = process.argv.indexOf("--network");
const network = i === -1 ? "anvil" : process.argv[i + 1]!;
const OUT = join(CONTRACTS, "deployments-local", network);
const c = JSON.parse(readFileSync(join(OUT, "config-day2.json"), "utf8")) as Json;

const HUB = "exotic";
const UNI = "uniV3Exotic";
const SLIP = "slipExotic";
const LEND = "lendExotic";
/** The CDP Spokes' liquidation bonus factor, set by the Aave deployment payload (06_AaveDeploymentPayload). */
const LIQUIDATION_BONUS_FACTOR = 5000;

const feeds = (sym: string) => ({
  primary: `$world:.feeds.${sym}.primary`,
  alternate: `$world:.feeds.${sym}.alternate`,
  standby: `$world:.feeds.${sym}.standby`,
  second: `$world:.feeds.${sym}.second`,
});
const tokenOf = (sym: string) => (c.listing.tokens as Json[]).find((t) => t.symbol === sym);
const marketTemplate = (name: string) => {
  const m = (c.listing.markets as Json[]).find((x) => x.name === name);
  if (!m) throw new Error(`no market ${name} in the day-2 config`);
  return m;
};

// 1. The exotic Hub, its Lend Spoke and its two CDP Spokes.
c.aaveLocal.hubs.push(HUB);
c.aaveLocal.spokes.push({ label: UNI, userReservesLimit: 8 }, { label: SLIP, userReservesLimit: 8 }, { label: LEND, userReservesLimit: 65535 });
c.aave.hubs.push({ hub: `$aave:.hubs.${HUB}.proxy`, tier: 3, label: HUB });
c.aave.irStrategies[HUB] = `$aave:.hubs.${HUB}.irStrategy`;
for (const s of [UNI, SLIP, LEND]) c.aave.spokes[s] = `$aave:.spokes.${s}.proxy`;
c.aavePayload.hubs.push({ label: HUB, lendSpoke: LEND, cdpSpokes: [UNI, SLIP] });
c.listing.spokes.push(
  { label: UNI, hub: HUB, integrationId: 1, tier: 3, spoke: `$aave:.spokes.${UNI}.proxy` },
  { label: SLIP, hub: HUB, integrationId: 2, tier: 3, spoke: `$aave:.spokes.${SLIP}.proxy` },
);

// 2. The new debt assets. Draw caps, loss-layer minimums and the (Hub, asset) credit line and speed limit are in whole
// tokens, so each is sized to the token's price: PEPE's are in the billions. A DebtOracle's floor rounding allowance is
// at most $1 of the asset (ParameterStore ROUNDING_ALLOWANCE_USD_MAX).
type DebtAsset = {
  symbol: string;
  decimals: number;
  hubs: string[];
  drawCap: number;
  bootstrapSupply: string;
  coverageMinimum: number;
  offsetMinimum: number;
  stressRiseBps: number;
  floorRoundingAllowance: string;
  creditLineWhole?: number;
  debtMinWhole?: number;
  debtMaxWhole?: number;
};
const DEBT_ASSETS: DebtAsset[] = [
  {
    // $1M of PEPE per CDP Spoke, $10M supplied, $100k / $75k loss layers.
    symbol: "PEPE",
    decimals: 18,
    hubs: [HUB],
    drawCap: 100_000_000_000,
    bootstrapSupply: "1000000000000000000000000000000",
    coverageMinimum: 10_000_000_000,
    offsetMinimum: 7_500_000_000,
    stressRiseBps: 3000,
    floorRoundingAllowance: "50000000000000000000000",
    creditLineWhole: 200_000_000_000,
    // 2.5-7.5e10 PEPE ($250k-$750k): the speed limit's bounds are uint96 base units.
    debtMinWhole: 25_000_000_000,
    debtMaxWhole: 75_000_000_000,
  },
  {
    symbol: "AAVE",
    decimals: 18,
    hubs: [HUB],
    drawCap: 20_000,
    bootstrapSupply: "40000000000000000000000",
    coverageMinimum: 400,
    offsetMinimum: 300,
    stressRiseBps: 1500,
    floorRoundingAllowance: "2000000000000000",
  },
  {
    symbol: "WBTC",
    decimals: 8,
    hubs: [HUB, "volatile"],
    drawCap: 50,
    bootstrapSupply: "10000000000",
    coverageMinimum: 2,
    offsetMinimum: 1,
    stressRiseBps: 1000,
    floorRoundingAllowance: "500",
  },
];
for (const d of DEBT_ASSETS) {
  c.aavePayload.debtAssets.push({
    symbol: d.symbol,
    token: `$world:.tokens.${d.symbol}`,
    decimals: d.decimals,
    priceSource: `$world:.feeds.${d.symbol}.primary`,
    drawCap: d.drawCap,
    bootstrapSupply: d.bootstrapSupply,
    coverageMinimum: d.coverageMinimum,
    offsetMinimum: d.offsetMinimum,
    hubs: d.hubs,
  });
  c.listing.debtAssets.push({
    symbol: d.symbol,
    fixedPrice: false,
    stressRiseBps: d.stressRiseBps,
    floorRoundingAllowance: d.floorRoundingAllowance,
    debtOraclePokeMinGas: 1000000,
    ...(d.creditLineWhole ? { creditLineWhole: d.creditLineWhole } : {}),
    ...(d.debtMinWhole ? { debtMinWhole: d.debtMinWhole, debtMaxWhole: d.debtMaxWhole } : {}),
    address: `$world:.tokens.${d.symbol}`,
    feeds: { primary: `$world:.feeds.${d.symbol}.primary` },
  });
}

// What each CDP Spoke lends (the first is the market's default debt asset in listing-markets.json and the scenarios).
const LENDS: Record<string, string[]> = { [UNI]: ["USDC", "PEPE", "AAVE", "WBTC"], [SLIP]: ["USDC", "WBTC"], uniV3Volatile: ["WBTC"] };
const venue = (spoke: string) => (spoke === SLIP ? "Slipstream" : "Uniswap v3");
const hubOf = (spoke: string) => (c.listing.spokes as Json[]).find((s) => s.label === spoke)!.hub as string;
for (const [spoke, assets] of Object.entries(LENDS)) {
  for (const sym of assets) {
    const slug = `${sym.toLowerCase()}-${venue(spoke).toLowerCase().replace(/ /g, "-")}-${hubOf(spoke)}`;
    c.listing.debtReserves.push({
      spoke,
      symbol: sym,
      content: {
        slug,
        name: `${sym} on ${venue(spoke)} (${hubOf(spoke)} Hub)`,
        symbol: sym,
        category: sym === "USDC" ? "stable" : "crypto",
        description: `Borrow ${sym} from Aave V4's ${hubOf(spoke)} Hub against ${venue(spoke)} liquidity positions.`,
        faqs: [{ question: `Where does the ${sym} come from?`, answer: `From the ${hubOf(spoke)} Hub of Aave V4, through the ${venue(spoke)} CDP Spoke.` }],
      },
    });
  }
}

// 3. The collateral tokens. A token's collateral factor caps every market it is in; the exotic Hub is added to the
// Hubs USDC and WETH may be pledged on.
const TOKENS: { symbol: string; deviationBps: number; collateralFactorBps: number; toleranceBps: number; tokenCapUsd: string }[] = [
  { symbol: "PEPE", deviationBps: 200, collateralFactorBps: 4000, toleranceBps: 400, tokenCapUsd: "2000000" },
  { symbol: "AAVE", deviationBps: 100, collateralFactorBps: 6500, toleranceBps: 300, tokenCapUsd: "5000000" },
  { symbol: "UNI", deviationBps: 100, collateralFactorBps: 6000, toleranceBps: 300, tokenCapUsd: "5000000" },
  { symbol: "WBTC", deviationBps: 50, collateralFactorBps: 7500, toleranceBps: 200, tokenCapUsd: "10000000" },
  { symbol: "THIN", deviationBps: 200, collateralFactorBps: 2500, toleranceBps: 400, tokenCapUsd: "50000" },
  { symbol: "AERO", deviationBps: 100, collateralFactorBps: 5000, toleranceBps: 300, tokenCapUsd: "5000000" },
  { symbol: "cbBTC", deviationBps: 50, collateralFactorBps: 7500, toleranceBps: 200, tokenCapUsd: "10000000" },
];
for (const t of TOKENS) {
  c.listing.tokens.push({
    symbol: t.symbol,
    isUsdStable: false,
    deviationBps: t.deviationBps,
    collateralFactorBps: t.collateralFactorBps,
    agreementToleranceBps: t.toleranceBps,
    secondToleranceBps: t.toleranceBps,
    tokenCapUsd: t.tokenCapUsd,
    hubs: [HUB],
    address: `$world:.tokens.${t.symbol}`,
    feeds: feeds(t.symbol),
  });
}
for (const sym of ["USDC", "WETH"]) tokenOf(sym)!.hubs.push(HUB);

/** The largest slippage allowance s with s x minLB <= (1e4 - f)(minLB - 1e4), minLB the smallest bonus (LIQ-I1). */
function slippageFor(maxLiquidationBonus: number): number {
  const f = c.parameters.globals.avanaFeeShareBps as number;
  const minLb = 10_000 + Math.floor(((maxLiquidationBonus - 10_000) * LIQUIDATION_BONUS_FACTOR) / 10_000);
  return Math.floor(((10_000 - f) * (minLb - 10_000)) / minLb);
}

/** Routes from each of the pool's tokens into each asset the Spoke lends, two pool-disjoint paths each. */
function routesFor(name: string, pool: string, spoke: string): Route[] {
  const p = poolOf(c, pool);
  if (!p) throw new Error(`${name}: no world pool ${pool}`);
  const own = (c.world.uniswapPools as Json[]).some((x) => x.name === pool) ? pool : "";
  const assets = (c.listing.debtReserves as Json[]).filter((d) => d.spoke === spoke).map((d) => d.symbol as string);
  return assets.flatMap((asset) => [p.a, p.b].filter((t: string) => t !== asset).map((t: string) => routePair(c, name, t, asset, own)));
}

type MarketSpec = {
  pool: string;
  spoke: string;
  poolRiskFactorBps: number;
  maxLiquidationBonus: number;
  consistencyToleranceBps: number;
  marketUsdCap: string;
  topUpSliceUsd: string;
  kind: string;
};
const MARKETS: MarketSpec[] = [
  { pool: "PEPE-WETH-10000", spoke: UNI, poolRiskFactorBps: 3000, maxLiquidationBonus: 11500, consistencyToleranceBps: 300, marketUsdCap: "25000", topUpSliceUsd: "10000", kind: "a meme coin" },
  { pool: "PEPE-USDC-10000", spoke: UNI, poolRiskFactorBps: 4000, maxLiquidationBonus: 11500, consistencyToleranceBps: 300, marketUsdCap: "1000000", topUpSliceUsd: "250000", kind: "a meme coin" },
  { pool: "AAVE-WETH-3000", spoke: UNI, poolRiskFactorBps: 4000, maxLiquidationBonus: 10800, consistencyToleranceBps: 100, marketUsdCap: "1000000", topUpSliceUsd: "250000", kind: "a governance token" },
  { pool: "UNI-WETH-3000", spoke: UNI, poolRiskFactorBps: 4000, maxLiquidationBonus: 10800, consistencyToleranceBps: 100, marketUsdCap: "1000000", topUpSliceUsd: "250000", kind: "a governance token" },
  { pool: "AAVE-UNI-3000", spoke: UNI, poolRiskFactorBps: 4000, maxLiquidationBonus: 10800, consistencyToleranceBps: 100, marketUsdCap: "500000", topUpSliceUsd: "100000", kind: "two governance tokens" },
  { pool: "WBTC-PEPE-10000", spoke: UNI, poolRiskFactorBps: 3000, maxLiquidationBonus: 11500, consistencyToleranceBps: 300, marketUsdCap: "500000", topUpSliceUsd: "100000", kind: "8- and 18-decimal tokens nine orders of magnitude apart in price" },
  { pool: "WBTC-USDC-3000", spoke: UNI, poolRiskFactorBps: 4000, maxLiquidationBonus: 10800, consistencyToleranceBps: 100, marketUsdCap: "2000000", topUpSliceUsd: "500000", kind: "an 8-decimal token" },
  { pool: "THIN-USDC-10000", spoke: UNI, poolRiskFactorBps: 2000, maxLiquidationBonus: 11500, consistencyToleranceBps: 300, marketUsdCap: "10000", topUpSliceUsd: "5000", kind: "a thin pool" },
  { pool: "AERO-USDC-cl200-g0", spoke: SLIP, poolRiskFactorBps: 4000, maxLiquidationBonus: 10800, consistencyToleranceBps: 100, marketUsdCap: "1000000", topUpSliceUsd: "250000", kind: "a governance token" },
  { pool: "cbBTC-USDC-cl100-g1", spoke: SLIP, poolRiskFactorBps: 4000, maxLiquidationBonus: 10800, consistencyToleranceBps: 100, marketUsdCap: "2000000", topUpSliceUsd: "500000", kind: "an 8-decimal token" },
];
const uniTemplate = marketTemplate("uni-WETH-USDC-500");
const slipTemplate = marketTemplate("slip-WETH-USDC-cl100");
for (const s of MARKETS) {
  const p = poolOf(c, s.pool)!;
  const slip = s.spoke === SLIP;
  const name = `${slip ? "slip" : "uni"}-${s.pool}`;
  const cf = Math.floor((Math.min(tokenOf(p.a)!.collateralFactorBps, tokenOf(p.b)!.collateralFactorBps) * s.poolRiskFactorBps) / 1e4);
  const fee = slip ? `tick spacing ${p.tickSpacing}` : `${(p.fee / 10_000).toString()}% fee tier`;
  const routes = routesFor(name, s.pool, s.spoke);
  addRoutePools(c, routes);
  c.listing.pools[s.pool] = slip ? `$world:.slipstreamPools['${s.pool}']` : `$world:.uniswapPools['${s.pool}']`;
  const lends = LENDS[s.spoke]!.join(", ");
  c.listing.markets.push({
    ...(slip ? slipTemplate : uniTemplate),
    name,
    spoke: s.spoke,
    pool: s.pool,
    generation: slip ? p.generation : 0,
    tickLower: 0,
    tickUpper: 0,
    collateralFactorBps: cf,
    maxLiquidationBonus: s.maxLiquidationBonus,
    consistencyToleranceBps: s.consistencyToleranceBps,
    poolRiskFactorBps: s.poolRiskFactorBps,
    slippageAllowanceBps: slippageFor(s.maxLiquidationBonus),
    slippageAllowanceMinBps: 50,
    marketUsdCap: s.marketUsdCap,
    topUpSliceUsd: s.topUpSliceUsd,
    routes,
    content: {
      slug: `${venue(s.spoke).toLowerCase().replace(/ /g, "-")}-${p.a.toLowerCase()}-${p.b.toLowerCase()}-${slip ? `cl${p.tickSpacing}` : String(p.fee)}-exotic`,
      name: `${p.a}/${p.b} ${venue(s.spoke)} (exotic Hub)`,
      category: "crypto",
      venueLabel: venue(s.spoke),
      description: `Borrow ${lends} from the exotic Hub against a full-range ${p.a}/${p.b} liquidity position in the ${venue(s.spoke)} pool with ${fee}: ${s.kind}.`,
      faqs: [{ question: "What can I borrow?", answer: `${lends} from the exotic Hub, up to ${cf / 100}% of the position's value.` }],
    },
  });
}

// WBTC on uniV3Volatile: every market listed there needs routes into it (REQ-MREG-032).
for (const m of c.listing.markets as Json[]) {
  if (m.spoke !== "uniV3Volatile") continue;
  const own = (c.world.uniswapPools as Json[]).some((x) => x.name === m.pool) ? m.pool : "";
  const p = poolOf(c, m.pool)!;
  const routes = [p.a, p.b].filter((t: string) => t !== "WBTC").map((t: string) => routePair(c, m.name, t, "WBTC", own));
  addRoutePools(c, routes);
  for (const r of routes) if (!m.routes.some((x: Route) => x.token === r.token && x.asset === r.asset)) m.routes.push(r);
}

const out = join(OUT, "config-exotic.json");
writeFileSync(out, `${JSON.stringify(c, null, 2)}\n`);
process.stdout.write(`exotic config ${out}: ${MARKETS.length} markets, ${DEBT_ASSETS.length} new debt assets\n`);
