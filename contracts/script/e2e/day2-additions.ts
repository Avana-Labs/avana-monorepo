// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local rehearsal's day-2 changes: the edits an operator makes to the network config after the first deployment,
// applied to the run's base config (deployments-local/<network>/config-base.json, else script/deploy/config/<network>.json)
// and written to deployments-local/<network>/config-day2.json. The
// deploy steps then run again with AVANA_CONFIG pointing at that file and act only on what it adds:
//   1. a new Hub, `growth` (tier 3), with its Lend Spoke `lendGrowth` and a Uniswap v3 CDP Spoke `uniV3Growth`
//      (Aave side: Hub, Spokes, assets; Avana side: recordHub, CDP Spoke, First-Loss Reserves);
//   2. a new lend asset: WETH on the volatile Hub's Lend Spoke only (`lendOnly`, no CDP Spoke, no loss layers);
//   3. a new borrowable asset on an existing CDP Spoke: USDT on `slipVolatile`;
//   4. a new collateral token, LINK, and a pool on an existing Spoke: Uniswap v3 LINK/USDC 0.3 % on `uniV3Volatile`;
//   5. a pool on the new Hub: Uniswap v3 USDC/USDT 0.05 % on `uniV3Growth`, borrowing GHO.
// Each pool lists as a Full range and a Custom range market. A token or debt asset entry is its symbol and address:
// 09_ListMarkets takes its price, collateral factor and bonus from the CDP Spoke's price Spoke, the world's stand-in.
//
// Usage, from contracts/:  node script/e2e/day2-additions.ts --network anvil

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

type Json = Record<string, any>;
const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const i = process.argv.indexOf("--network");
const network = i === -1 ? "anvil" : process.argv[i + 1]!;
// The run's base config when e2e-local.sh wrote one (the anvil config with the run's generated drill signer).
const base = join(CONTRACTS, "deployments-local", network, "config-base.json");
const c = JSON.parse(readFileSync(existsSync(base) ? base : join(CONTRACTS, "script/deploy/config", `${network}.json`), "utf8")) as Json;
const PRICE_SPOKE = "$world:.aaveV4PriceSpoke";
/** The world's supply cap of a market, as the anvil config's markets set it. */
const MARKET_USD_CAP = "5000000";

// 1. New Hub `growth` with a Lend Spoke and a Uniswap v3 CDP Spoke.
c.aaveLocal.hubs.push("growth");
c.aaveLocal.spokes.push({ label: "uniV3Growth", userReservesLimit: 8 }, { label: "lendGrowth", userReservesLimit: 65535 });
c.aave.hubs.push({ hub: "$aave:.hubs.growth.proxy", tier: 3, label: "growth" });
c.aave.irStrategies.growth = "$aave:.hubs.growth.irStrategy";
c.aave.spokes.uniV3Growth = "$aave:.spokes.uniV3Growth.proxy";
c.aave.spokes.lendGrowth = "$aave:.spokes.lendGrowth.proxy";
c.aavePayload.hubs.push({ label: "growth", lendSpoke: "lendGrowth", cdpSpokes: ["uniV3Growth"] });
c.listing.spokes.push({ label: "uniV3Growth", hub: "growth", integrationId: 1, tier: 3, spoke: "$aave:.spokes.uniV3Growth.proxy", priceSpoke: PRICE_SPOKE });
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

// 3. USDT borrowable on slipVolatile.
c.listing.debtAssets.push({ symbol: "USDT", address: "$world:.tokens.USDT" });
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
// 4. LINK as a collateral token (the price Spoke's LINK reserve prices it and sets its collateral factor), and the
// LINK/USDC 0.3 % pool on uniV3Volatile borrowing GHO.
c.listing.tokens.push({ symbol: "LINK", address: "$world:.tokens.LINK" });
c.listing.pools["LINK-USDC-3000"] = "$world:.uniswapPools['LINK-USDC-3000']";
c.listing.markets.push({
  name: "uni-LINK-USDC-3000",
  integrationId: 1,
  spoke: "uniV3Volatile",
  pool: "LINK-USDC-3000",
  marketUsdCap: MARKET_USD_CAP,
  content: {
    slug: "uniswap-v3-link-usdc-0-3",
    name: "LINK/USDC Uniswap v3",
    category: "crypto",
    venueLabel: "Uniswap v3",
    description: "Borrow GHO against a LINK/USDC liquidity position in the Uniswap v3 pool with 0.3% fee tier.",
    faqs: [{ question: "What can I borrow?", answer: "GHO from the volatile Hub." }],
  },
});

// 5. A stable pool on the new Hub.
c.listing.pools["USDC-USDT-500"] = "$world:.uniswapPools['USDC-USDT-500']";
c.listing.markets.push({
  name: "uni-USDC-USDT-500-growth",
  integrationId: 1,
  spoke: "uniV3Growth",
  pool: "USDC-USDT-500",
  marketUsdCap: MARKET_USD_CAP,
  content: {
    slug: "uniswap-v3-usdc-usdt-0-05-growth",
    name: "USDC/USDT Uniswap v3 (growth Hub)",
    category: "stable",
    venueLabel: "Uniswap v3",
    description: "Borrow GHO from the growth Hub against a USDC/USDT liquidity position in the Uniswap v3 pool with 0.05% fee tier.",
    faqs: [{ question: "What can I borrow?", answer: "GHO from the growth Hub, against the position's value." }],
  },
});

const out = join(CONTRACTS, "deployments-local", network, "config-day2.json");
writeFileSync(out, `${JSON.stringify(c, null, 2)}\n`);
process.stdout.write(`day-2 config ${out}\n`);
