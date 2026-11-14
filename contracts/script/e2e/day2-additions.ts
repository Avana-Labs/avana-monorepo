// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local rehearsal's day-2 changes: the edits an operator makes to the network config after the first deployment,
// applied to script/deploy/config/<network>.json and written to deployments-local/<network>/config-day2.json. The
// deploy steps then run again with AVANA_CONFIG pointing at that file and act only on what it adds:
//   1. a new Hub, `growth` (tier 3), with its Lend Spoke `lendGrowth` and a Uniswap v3 CDP Spoke `uniV3Growth`
//      (Aave side: Hub, Spokes, assets; Avana side: recordHub, CDP Spoke, First-Loss Reserves, credit line);
//   2. a new lend asset: WETH on the volatile Hub's Lend Spoke only (`lendOnly`, no CDP Spoke, no loss layers);
//   3. a new borrowable asset on an existing CDP Spoke: USDT on `slipVolatile`, with its DebtOracle, and the routes
//      the Spoke's listed market needs into USDT;
//   4. a new collateral token, LINK, and a market on an existing Spoke: Uniswap v3 LINK/USDC 0.3 % on `uniV3Volatile`;
//   5. a market on the new Hub: Uniswap v3 USDC/USDT 0.05 % on `uniV3Growth`, borrowing GHO.
//
// Usage, from contracts/:  node script/e2e/day2-additions.ts --network anvil

import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Json = Record<string, any>;
const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const i = process.argv.indexOf("--network");
const network = i === -1 ? "anvil" : process.argv[i + 1]!;
const c = JSON.parse(readFileSync(join(CONTRACTS, "script/deploy/config", `${network}.json`), "utf8")) as Json;
const marketTemplate = (name: string) => {
  const m = (c.listing.markets as Json[]).find((x) => x.name === name);
  if (!m) throw new Error(`no market ${name} in the config`);
  return m;
};

// 1. New Hub `growth` with a Lend Spoke and a Uniswap v3 CDP Spoke.
c.aaveLocal.hubs.push("growth");
c.aaveLocal.spokes.push({ label: "uniV3Growth", userReservesLimit: 8 }, { label: "lendGrowth", userReservesLimit: 65535 });
c.aave.hubs.push({ hub: "$aave:.hubs.growth.proxy", tier: 3, label: "growth" });
c.aave.irStrategies.growth = "$aave:.hubs.growth.irStrategy";
c.aave.spokes.uniV3Growth = "$aave:.spokes.uniV3Growth.proxy";
c.aave.spokes.lendGrowth = "$aave:.spokes.lendGrowth.proxy";
c.aavePayload.hubs.push({ label: "growth", lendSpoke: "lendGrowth", cdpSpokes: ["uniV3Growth"] });
c.listing.spokes.push({ label: "uniV3Growth", hub: "growth", integrationId: 1, tier: 3, spoke: "$aave:.spokes.uniV3Growth.proxy" });
c.listing.debtReserves.push({
  spoke: "uniV3Growth",
  symbol: "GHO",
  content: {
    slug: "gho-uniswap-v3-growth",
    name: "GHO on Uniswap v3 (growth Hub)",
    symbol: "GHO",
    category: "stable",
    description: "Borrow GHO from Aave V4's growth Hub against Uniswap v3 liquidity positions.",
    faqs: [{ question: "Where does the GHO come from?", answer: "From the growth Hub of Aave V4, through the Uniswap v3 CDP Spoke." }],
  },
});
for (const t of c.listing.tokens as Json[]) if (t.symbol === "USDC" || t.symbol === "USDT") t.hubs.push("growth");

// 2. WETH lent on the volatile Hub only.
c.aavePayload.debtAssets.push({
  symbol: "WETH",
  token: "$world:.tokens.WETH",
  decimals: 18,
  priceSource: "$world:.feeds.WETH.primary",
  drawCap: 0,
  bootstrapSupply: "1000000000000000000000",
  hubs: ["volatile"],
  lendOnly: true,
});

// 3. USDT borrowable on slipVolatile, priced by its own DebtOracle; the Spoke's listed market gets routes into USDT.
c.listing.debtAssets.push({
  symbol: "USDT",
  fixedPrice: false,
  stressRiseBps: 500,
  floorRoundingAllowance: "1000000",
  debtOraclePokeMinGas: 1000000,
  address: "$world:.tokens.USDT",
  feeds: { primary: "$world:.feeds.USDT.primary" },
});
c.listing.debtReserves.push({
  spoke: "slipVolatile",
  symbol: "USDT",
  content: {
    slug: "usdt-slipstream-volatile",
    name: "USDT on Slipstream (volatile Hub)",
    symbol: "USDT",
    category: "stable",
    description: "Borrow USDT from Aave V4's volatile Hub against Slipstream liquidity positions.",
    faqs: [{ question: "Where does the USDT come from?", answer: "From the volatile Hub of Aave V4, through the Slipstream CDP Spoke." }],
  },
});
marketTemplate("slip-WETH-USDC-cl100").routes.push(
  { token: "WETH", asset: "USDT", primary: ["WETH-USDT-500"], backup: ["WETH-USDC-500", "USDC-USDT-100"] },
  { token: "USDC", asset: "USDT", primary: ["USDC-USDT-100"], backup: ["USDC-USDT-500"] },
);

// 4. LINK as a collateral token, and a full-range LINK/USDC 0.3 % market on uniV3Volatile borrowing GHO. Each route
// avoids the market's own pool, and a primary and its backup share no pool (the MarketRegistry refuses either).
const weth = (c.listing.tokens as Json[]).find((t) => t.symbol === "WETH")!;
c.listing.tokens.push({
  ...weth,
  symbol: "LINK",
  collateralFactorBps: 7000,
  tokenCapUsd: "10000000",
  hubs: ["volatile"],
  address: "$world:.tokens.LINK",
  feeds: {
    primary: "$world:.feeds.LINK.primary",
    alternate: "$world:.feeds.LINK.alternate",
    standby: "$world:.feeds.LINK.standby",
    second: "$world:.feeds.LINK.second",
  },
});
for (const p of ["LINK-USDC-3000", "LINK-WETH-3000", "LINK-USDT-3000"]) c.listing.pools[p] = `$world:.uniswapPools['${p}']`;
// The vault token's Aave collateral factor may not exceed min(token collateral factors) x poolRiskFactorBps / 1e4
// (SPEC-CF-001): LINK 7000 and USDC 9000 at 4000 give 2800, below the WETH/USDC template's 3000.
const linkTemplate = marketTemplate("uni-WETH-USDC-500");
const usdc = (c.listing.tokens as Json[]).find((t) => t.symbol === "USDC")!;
c.listing.markets.push({
  ...linkTemplate,
  name: "uni-LINK-USDC-3000",
  pool: "LINK-USDC-3000",
  collateralFactorBps: Math.floor((Math.min(7000, usdc.collateralFactorBps) * linkTemplate.poolRiskFactorBps) / 1e4),
  routes: [
    { token: "LINK", asset: "GHO", primary: ["LINK-WETH-3000", "GHO-WETH-3000"], backup: ["LINK-USDT-3000", "GHO-USDT-100"] },
    { token: "USDC", asset: "GHO", primary: ["GHO-USDC-100"], backup: ["USDC-USDT-500", "GHO-USDT-100"] },
  ],
  content: {
    slug: "uniswap-v3-link-usdc-0-3",
    name: "LINK/USDC Uniswap v3",
    category: "crypto",
    venueLabel: "Uniswap v3",
    description: "Borrow GHO against a full-range LINK/USDC liquidity position in the Uniswap v3 pool with 0.3% fee tier.",
    faqs: [{ question: "What can I borrow?", answer: "GHO from the volatile Hub." }],
  },
});

// 5. A stable market on the new Hub.
const stable = marketTemplate("uni-USDC-USDT-100");
c.listing.markets.push({
  ...stable,
  name: "uni-USDC-USDT-500-growth",
  spoke: "uniV3Growth",
  pool: "USDC-USDT-500",
  routes: [
    { token: "USDC", asset: "GHO", primary: ["GHO-USDC-100"], backup: ["USDC-USDT-100", "GHO-USDT-100"] },
    { token: "USDT", asset: "GHO", primary: ["GHO-USDT-100"], backup: ["USDC-USDT-100", "GHO-USDC-100"] },
  ],
  content: {
    slug: "uniswap-v3-usdc-usdt-0-05-growth",
    name: "USDC/USDT Uniswap v3 (growth Hub)",
    category: "stable",
    venueLabel: "Uniswap v3",
    description: "Borrow GHO from the growth Hub against a USDC/USDT liquidity position in the Uniswap v3 pool with 0.05% fee tier.",
    faqs: [{ question: "What can I borrow?", answer: "GHO from the growth Hub, up to 35% of the position's value." }],
  },
});

const out = join(CONTRACTS, "deployments-local", network, "config-day2.json");
writeFileSync(out, `${JSON.stringify(c, null, 2)}\n`);
process.stdout.write(`day-2 config ${out}\n`);
