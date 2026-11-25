// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The local rehearsal's hostile pass: one config per pool-token behaviour REQ-ARCH-014 keeps out of listing, each added
// to the latest release config (exotic, else day 2) and written to deployments-local/<network>/config-hostile-<case>.json.
// The rehearsal runs the listing steps on each from an anvil snapshot and expects them to refuse it:
//   fot       a pool token that takes a 1 % transfer fee: the FOT/USDC 0.3 % pool on uniV3Volatile;
//   rebase    a pool token whose balances rebase: the REBASE/USDC 0.3 % pool on uniV3Volatile;
//   nodec     a pool token without decimals(): the NODEC/USDC 0.3 % pool on uniV3Volatile.
// Avana lists a pool only when each of its tokens has exactly one reserve on the CDP Spoke's price Spoke (09_ListMarkets,
// the RiskModule's listing check): Aave lists only standard ERC-20s, and the world's price Spoke stand-in leaves these
// stand-ins out as Aave would, so 09-listing-markets refuses each pool.
//
// Usage, from contracts/:  node script/e2e/hostile-additions.ts --network anvil --case <fot|rebase|nodec>

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

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

/** A collateral token (its symbol and address) and its USDC 0.3 % pool on uniV3Volatile. */
function poolToken(sym: string) {
  c.listing.tokens.push({ symbol: sym, address: `$world:.tokens.${sym}` });
  const pool = `${sym}-USDC-3000`;
  const name = `uni-${sym}-USDC-3000`;
  c.listing.pools[pool] = `$world:.uniswapPools['${pool}']`;
  c.listing.markets.push({
    name,
    integrationId: 1,
    spoke: SPOKE,
    pool,
    marketUsdCap: "1000000",
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

if (kase === "fot") poolToken("FOT");
else if (kase === "rebase") poolToken("REBASE");
else if (kase === "nodec") poolToken("NODEC");
else throw new Error(`unknown case ${kase}`);

const out = join(OUT, `config-hostile-${kase}.json`);
writeFileSync(out, `${JSON.stringify(c, null, 2)}\n`);
process.stdout.write(`hostile config ${out} (on ${base})\n`);
