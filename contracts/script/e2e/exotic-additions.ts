// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local rehearsal's exotic pass (rehearsal 08): pools and borrowable assets far from the stable and WETH markets,
// added to the day-2 config (deployments-local/<network>/config-day2.json) and written to config-exotic.json. The
// deploy steps then run again with AVANA_CONFIG pointing at that file and act only on what it adds:
//   1. a new Hub, `exotic` (tier 3), with its Lend Spoke `lendExotic`, a Uniswap v3 CDP Spoke `uniV3Exotic` and a
//      Slipstream CDP Spoke `slipExotic`;
//   2. three debt assets new to Aave: PEPE (a meme coin, 18 decimals, $0.00001), AAVE (a governance token) and WBTC
//      (8 decimals, $95,000), each priced on its Hub by its own Chainlink feed (the Aave side's price source). The exotic
//      Hub lends USDC, PEPE, AAVE and WBTC; borrowing is mixed per Spoke: uniV3Exotic all four, slipExotic USDC and
//      WBTC, and WBTC also on the volatile Hub's uniV3Volatile;
//   3. seven collateral tokens (PEPE, AAVE, UNI, WBTC, THIN, AERO, cbBTC) and seven pools: Uniswap v3 PEPE/USDC 1 %,
//      AAVE/UNI 0.3 %, WBTC/PEPE 1 % (the widest decimals and price gap), WBTC/USDC 0.3 %, THIN/USDC 1 % (a $20k pool),
//      and Slipstream AERO/USDC (tick spacing 200) and cbBTC/USDC (100), each listed as a Full range and a Custom range
//      market.
// A market's LTV and bonus are its price Spoke's (09_ListMarkets: the lower collateral factor and the higher max bonus
// of its two tokens' reserves on the world's price Spoke stand-in, whose reserveDefault every token here takes); a
// token or debt asset entry is its symbol and address. Only the supply cap (marketUsdCap) is set per market.
// The pass is one release of all seven pools: one listing operation of fourteen markets.
//
// Usage, from contracts/:  node script/e2e/exotic-additions.ts --network anvil

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Json = Record<string, any>;
const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const arg = (n: string, d: string) => {
  const i = process.argv.indexOf(n);
  return i === -1 ? d : process.argv[i + 1]!;
};
const network = arg("--network", "anvil");
const OUT = join(CONTRACTS, "deployments-local", network);
const c = JSON.parse(readFileSync(join(OUT, "config-day2.json"), "utf8")) as Json;

const HUB = "exotic";
const UNI = "uniV3Exotic";
const SLIP = "slipExotic";
const LEND = "lendExotic";
const PRICE_SPOKE = "$world:.aaveV4PriceSpoke";

// 1. The exotic Hub, its Lend Spoke and its two CDP Spokes.
c.aaveLocal.hubs.push(HUB);
c.aaveLocal.spokes.push({ label: UNI, userReservesLimit: 8 }, { label: SLIP, userReservesLimit: 8 }, { label: LEND, userReservesLimit: 65535 });
c.aave.hubs.push({ hub: `$aave:.hubs.${HUB}.proxy`, tier: 3, label: HUB });
c.aave.irStrategies[HUB] = `$aave:.hubs.${HUB}.irStrategy`;
for (const s of [UNI, SLIP, LEND]) c.aave.spokes[s] = `$aave:.spokes.${s}.proxy`;
c.aavePayload.hubs.push({ label: HUB, lendSpoke: LEND, cdpSpokes: [UNI, SLIP] });
c.listing.spokes.push(
  { label: UNI, hub: HUB, integrationId: 1, tier: 3, spoke: `$aave:.spokes.${UNI}.proxy`, priceSpoke: PRICE_SPOKE },
  { label: SLIP, hub: HUB, integrationId: 2, tier: 3, spoke: `$aave:.spokes.${SLIP}.proxy`, priceSpoke: PRICE_SPOKE },
);

// 2. The new debt assets. Draw caps and loss-layer minimums are in whole tokens, so each is sized to the token's
// price: PEPE's are in the billions.
type DebtAsset = {
  symbol: string;
  decimals: number;
  hubs: string[];
  drawCap: number;
  bootstrapSupply: string;
  coverageMinimum: number;
  offsetMinimum: number;
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
  },
  {
    symbol: "AAVE",
    decimals: 18,
    hubs: [HUB],
    drawCap: 20_000,
    bootstrapSupply: "40000000000000000000000",
    coverageMinimum: 400,
    offsetMinimum: 300,
  },
  {
    symbol: "WBTC",
    decimals: 8,
    hubs: [HUB, "volatile"],
    drawCap: 50,
    bootstrapSupply: "10000000000",
    coverageMinimum: 2,
    offsetMinimum: 1,
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
  c.listing.debtAssets.push({ symbol: d.symbol, address: `$world:.tokens.${d.symbol}` });
}

// What each CDP Spoke lends.
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

// 3. The collateral tokens, each a reserve of the price Spoke stand-in, and the pools.
const TOKENS = ["PEPE", "AAVE", "UNI", "WBTC", "THIN", "AERO", "cbBTC"];
for (const sym of TOKENS) c.listing.tokens.push({ symbol: sym, address: `$world:.tokens.${sym}` });

type PoolSpec = { pool: string; spoke: string; marketUsdCap: string; kind: string };
const POOLS: PoolSpec[] = [
  { pool: "PEPE-USDC-10000", spoke: UNI, marketUsdCap: "1000000", kind: "a meme coin" },
  { pool: "AAVE-UNI-3000", spoke: UNI, marketUsdCap: "500000", kind: "two governance tokens" },
  { pool: "WBTC-PEPE-10000", spoke: UNI, marketUsdCap: "500000", kind: "8- and 18-decimal tokens nine orders of magnitude apart in price" },
  { pool: "WBTC-USDC-3000", spoke: UNI, marketUsdCap: "2000000", kind: "an 8-decimal token" },
  { pool: "THIN-USDC-10000", spoke: UNI, marketUsdCap: "10000", kind: "a thin pool" },
  { pool: "AERO-USDC-cl200-g0", spoke: SLIP, marketUsdCap: "1000000", kind: "a governance token" },
  { pool: "cbBTC-USDC-cl100-g1", spoke: SLIP, marketUsdCap: "2000000", kind: "an 8-decimal token" },
];
const worldPool = (name: string) =>
  (c.world.uniswapPools as Json[]).find((p) => p.name === name) ?? (c.world.slipstreamPools as Json[]).find((p) => p.name === name);
for (const s of POOLS) {
  const p = worldPool(s.pool);
  if (!p) throw new Error(`no world pool ${s.pool}`);
  const slip = s.spoke === SLIP;
  const name = `${slip ? "slip" : "uni"}-${s.pool}`;
  const fee = slip ? `tick spacing ${p.tickSpacing}` : `${(p.fee / 10_000).toString()}% fee tier`;
  c.listing.pools[s.pool] = slip ? `$world:.slipstreamPools['${s.pool}']` : `$world:.uniswapPools['${s.pool}']`;
  const lends = LENDS[s.spoke]!.join(", ");
  c.listing.markets.push({
    name,
    integrationId: slip ? 2 : 1,
    spoke: s.spoke,
    pool: s.pool,
    marketUsdCap: s.marketUsdCap,
    content: {
      slug: `${venue(s.spoke).toLowerCase().replace(/ /g, "-")}-${p.a.toLowerCase()}-${p.b.toLowerCase()}-${slip ? `cl${p.tickSpacing}` : String(p.fee)}-exotic`,
      name: `${p.a}/${p.b} ${venue(s.spoke)} (exotic Hub)`,
      category: "crypto",
      venueLabel: venue(s.spoke),
      description: `Borrow ${lends} from the exotic Hub against a ${p.a}/${p.b} liquidity position in the ${venue(s.spoke)} pool with ${fee}: ${s.kind}.`,
      faqs: [{ question: "What can I borrow?", answer: `${lends} from the exotic Hub, against the position's value.` }],
    },
  });
}

const out = join(OUT, "config-exotic.json");
writeFileSync(out, `${JSON.stringify(c, null, 2)}\n`);
process.stdout.write(`exotic config ${out} : ${POOLS.length} pools (${2 * POOLS.length} markets), ${DEBT_ASSETS.length} new debt assets\n`);
