// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local rehearsal's hostile pass: one config per token behaviour REQ-ARCH-014 keeps out of listing, each added to
// the latest release config (exotic, else day 2) and written to deployments-local/<network>/config-hostile-<case>.json.
// The rehearsal runs the listing steps on each from an anvil snapshot and expects them to refuse it:
//   fot       a pool token that takes a 1 % transfer fee: a FOT/USDC 0.3 % market on uniV3Volatile;
//   rebase    a pool token whose balances rebase: a REBASE/USDC 0.3 % market on uniV3Volatile;
//   nodec     a pool token without decimals(): a NODEC/USDC 0.3 % market on uniV3Volatile;
//   feeswitch a 6-decimals debt asset whose issuer switched a 0.1 % fee on (basisPointsRate() > 0): FSUSD borrowable on
//             uniV3Volatile, lent on the volatile Hub.
//
// Usage, from contracts/:  node script/e2e/hostile-additions.ts --network anvil --case <fot|rebase|nodec|feeswitch>

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { addRoutePools, poolOf, routePair } from "./routes.ts";

type Json = Record<string, any>;
const CONTRACTS = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const arg = (n: string, d?: string) => {
  const i = process.argv.indexOf(n);
  return i === -1 ? d : process.argv[i + 1];
};
const network = arg("--network", "anvil")!;
const kase = arg("--case")!;
const OUT = join(CONTRACTS, "deployments-local", network);
const base = existsSync(join(OUT, "config-exotic.json")) ? "config-exotic.json" : "config-day2.json";
const c = JSON.parse(readFileSync(join(OUT, base), "utf8")) as Json;
const SPOKE = "uniV3Volatile";

const feeds = (sym: string) => ({
  primary: `$world:.feeds.${sym}.primary`,
  alternate: `$world:.feeds.${sym}.alternate`,
  standby: `$world:.feeds.${sym}.standby`,
  second: `$world:.feeds.${sym}.second`,
});

/** A collateral token and a full-range market on its USDC pool, with routes into every asset the Spoke lends. */
function poolToken(sym: string) {
  c.listing.tokens.push({
    symbol: sym,
    isUsdStable: false,
    deviationBps: 100,
    collateralFactorBps: 5000,
    agreementToleranceBps: 300,
    secondToleranceBps: 300,
    tokenCapUsd: "1000000",
    hubs: ["volatile"],
    address: `$world:.tokens.${sym}`,
    feeds: feeds(sym),
  });
  const tpl = (c.listing.markets as Json[]).find((m) => m.name === "uni-WETH-USDC-500")!;
  const pool = `${sym}-USDC-3000`;
  const name = `uni-${sym}-USDC-3000`;
  const assets = (c.listing.debtReserves as Json[]).filter((d) => d.spoke === SPOKE).map((d) => d.symbol as string);
  const p = poolOf(c, pool)!;
  const routes = assets.flatMap((asset) => [p.a, p.b].filter((t) => t !== asset).map((t: string) => routePair(c, name, t, asset, pool)));
  addRoutePools(c, routes);
  c.listing.pools[pool] = `$world:.uniswapPools['${pool}']`;
  c.listing.markets.push({
    ...tpl,
    name,
    pool,
    collateralFactorBps: Math.floor((5000 * tpl.poolRiskFactorBps) / 1e4),
    routes,
    content: {
      slug: name.toLowerCase(),
      name: `${sym}/USDC Uniswap v3`,
      category: "crypto",
      venueLabel: "Uniswap v3",
      description: `Hostile-token probe: ${sym}/USDC.`,
      faqs: [{ question: "Should this list?", answer: "No: REQ-ARCH-014 keeps this token out." }],
    },
  });
}

/** FSUSD lent on the volatile Hub and borrowable on uniV3Volatile, with routes from its listed markets into it. */
function feeSwitchDebt() {
  const sym = "FSUSD";
  // Every debt asset is a listed token, with the issuer probe that reads its fee switch.
  c.listing.tokens.push({
    symbol: sym,
    isUsdStable: true,
    deviationBps: 25,
    collateralFactorBps: 9000,
    agreementToleranceBps: 150,
    secondToleranceBps: 150,
    tokenCapUsd: "1000000",
    hubs: ["volatile"],
    issuerProbe: "UsdtFeeRate",
    address: `$world:.tokens.${sym}`,
    feeds: feeds(sym),
  });
  c.aavePayload.debtAssets.push({
    symbol: sym,
    token: `$world:.tokens.${sym}`,
    decimals: 6,
    priceSource: `$world:.feeds.${sym}.primary`,
    drawCap: 1000000,
    bootstrapSupply: "5000000000000",
    coverageMinimum: 50000,
    offsetMinimum: 25000,
    hubs: ["volatile"],
  });
  c.listing.debtAssets.push({
    symbol: sym,
    fixedPrice: false,
    stressRiseBps: 500,
    floorRoundingAllowance: "1000000",
    debtOraclePokeMinGas: 1000000,
    address: `$world:.tokens.${sym}`,
    feeds: { primary: `$world:.feeds.${sym}.primary` },
  });
  c.listing.debtReserves.push({
    spoke: SPOKE,
    symbol: sym,
    content: {
      slug: "fsusd-uniswap-v3-volatile",
      name: "FSUSD on Uniswap v3 (volatile Hub)",
      symbol: sym,
      category: "stable",
      description: "Hostile-token probe: a debt asset whose issuer switched a transfer fee on.",
      faqs: [{ question: "Should this list?", answer: "No: a debt asset with a transfer fee is refused (REQ-ARCH-014)." }],
    },
  });
  for (const m of c.listing.markets as Json[]) {
    if (m.spoke !== SPOKE) continue;
    const p = poolOf(c, m.pool)!;
    const routes = [p.a, p.b].map((t: string) => routePair(c, m.name, t, sym, m.pool));
    addRoutePools(c, routes);
    m.routes.push(...routes);
  }
}

if (kase === "fot") poolToken("FOT");
else if (kase === "rebase") poolToken("REBASE");
else if (kase === "nodec") poolToken("NODEC");
else if (kase === "feeswitch") feeSwitchDebt();
else throw new Error(`unknown case ${kase}`);

const out = join(OUT, `config-hostile-${kase}.json`);
writeFileSync(out, `${JSON.stringify(c, null, 2)}\n`);
process.stdout.write(`hostile config ${out} (on ${base})\n`);
