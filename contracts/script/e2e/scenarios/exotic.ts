// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Scenarios of the exotic pass (rehearsal 08, script/e2e/exotic-additions.ts), on the markets of the exotic Hub: each
// new debt asset borrowed (PEPE, AAVE and WBTC on uniV3Exotic, WBTC on the volatile Hub's uniV3Volatile), and a 90 %
// meme-coin crash liquidated by the keeper. Left out when the exotic pass did not list its markets.

import type { Address } from "viem";
import { marketRegistryAbi } from "../../../../packages/protocol/src/abis/index.ts";
import type { Scenario, ScenarioContext } from "./context.ts";
import { type Account, Env, type Market, StepError, WAD, fmt, pct, runWith, usd8 } from "./market.ts";

const WALLETS = {
  exoticBorrower: "0x1000000000000000000000000000000000000c08",
  memeBorrower: "0x1000000000000000000000000000000000000c09",
} as const satisfies Record<string, Address>;

const eq = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

/** The approved debt reserve of `asset` on the market's CDP Spoke. */
async function reserveOf(e: Env, m: Market, asset: Address): Promise<bigint> {
  const ids = (await e.read(e.registry, marketRegistryAbi, "getDebtReserveIds", [m.spoke])) as bigint[];
  for (const id of ids) {
    const d = await e.read(e.registry, marketRegistryAbi, "getDebtReserve", [m.spoke, id]);
    if (eq(d.asset, asset) && d.approved) return id;
  }
  throw new StepError(`no approved ${e.sym(asset)} debt reserve on ${m.spokeLabel}`);
}

// ─── 1. Each new debt asset borrowed ───

async function borrowEachAsset(e: Env) {
  const n = e.numbers;
  const w = WALLETS.exoticBorrower;
  n.settle = await e.settle(true);
  const legs: { market: string; assets: string[] }[] = [
    { market: "uni-WBTC-USDC-3000", assets: ["PEPE", "AAVE", "WBTC"] },
    { market: "uni-WETH-USDC-500", assets: ["WBTC"] },
  ];
  const detail: string[] = [];
  for (const leg of legs) {
    const m = e.market(leg.market);
    const p = await e.mintPosition(m, w, 20_000n);
    const a = await e.pledge(m, w, p);
    n[`${m.name}.pledge`] = `collateral ${usd8(await e.collateralUsd8(m, a))} on ${m.spokeLabel}`;
    for (const sym of leg.assets) {
      const asset = e.token(sym);
      const acct: Account = { ...a, debtReserveId: await reserveOf(e, m, asset) };
      const amount = e.amountForUsd(asset, 1_000n);
      const before = await e.balance(asset, w);
      await e.borrow(m, w, acct, amount, WAD);
      const got = (await e.balance(asset, w)) - before;
      const debt = await e.debt(m, acct);
      n[`${m.name}.${sym}`] = `borrowed ${fmt(got, e.dec(asset))} ${sym} ($1,000); debt ${fmt(debt, e.dec(asset))}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
      if (got !== amount || debt < amount) detail.push(`${m.name} ${sym}: received ${got} of ${amount}, debt ${debt}`);
    }
  }
  return { ok: detail.length === 0, detail: detail.length === 0 ? "PEPE, AAVE and WBTC on uniV3Exotic; WBTC on uniV3Volatile" : detail.join("; ") };
}

// ─── 2. A 90 % meme-coin crash, liquidated by the keeper ───

async function memeCrash(e: Env) {
  const m = e.market("uni-PEPE-USDC-10000");
  const w = WALLETS.memeBorrower;
  const keeper = (e.ctx.config.keepers as Address[])[0]!;
  const n = e.numbers;
  n.settle = await e.settle(true);
  const p = await e.mintPosition(m, w, 20_000n);
  const a = await e.pledge(m, w, p);
  const max = await e.maxBorrow(m, w, a);
  const amount = pct(max, 9_700n);
  n.liquidity = await e.ensureLiquidity(m, amount);
  await e.borrow(m, w, a, amount, WAD);
  const d = e.dec(m.debtAsset);
  n.borrow = `collateral ${usd8(await e.collateralUsd8(m, a))}; borrowed ${fmt(amount, d)} ${e.sym(m.debtAsset)} of max ${fmt(max, d)}; HF ${fmt(await e.healthFactor(m, a), 18)}`;
  // PEPE to a tenth of its price on every feed; USDC stays at $1. The pools are not moved.
  const crashed = e.prices.PEPE! / 10n;
  await e.refresh({ PEPE: crashed, USDC: e.prices.USDC! });
  await e.poke(m.lpOracle);
  const hf = await e.healthFactor(m, a);
  n.crash = `PEPE ${usd8(e.prices.PEPE!)} -> ${usd8(crashed)}: collateral ${usd8(await e.collateralUsd8(m, a))}; ${e.describe(await e.priceState(m.lpOracle))}; HF ${fmt(hf, 18)}`;
  if (hf >= WAD) {
    n.restored = await e.settle(true);
    return { ok: false, detail: `HF ${fmt(hf, 18)} not below 1 after the crash` };
  }
  const r = await e.liquidate(m, a, keeper, "liquidation");
  n.restored = await e.settle(true);
  const ok = r.ok && r.debtAfter < r.debtBefore && r.keeperOut > 0n && r.net > 0n;
  return {
    ok,
    detail: ok
      ? `keeper ${keeper} liquidated ${m.name} after PEPE -90 %: debt ${fmt(r.debtBefore, d)} -> ${fmt(r.debtAfter, d)} ${e.sym(m.debtAsset)}`
      : r.ok
        ? "debt not reduced or keeper not paid"
        : `liquidation reverted: ${r.error}`,
  };
}

export function exoticScenarios(ctx: ScenarioContext): Scenario[] {
  // A run without the exotic pass (E2E_STEPS without `exotic`) has none of these markets: no scenario then.
  if (!Object.values(ctx.file("listing-markets.json") ?? {}).some((m: any) => m.spokeLabel === "uniV3Exotic")) return [];
  const s = (name: string, body: (e: Env) => Promise<{ ok: boolean; detail: string }>): Scenario => ({
    name,
    needs: "market",
    run: () => runWith(ctx, body),
  });
  return [
    s("exotic Hub: a borrower takes PEPE, AAVE and WBTC, and WBTC on the volatile Hub", borrowEachAsset),
    s("exotic Hub: PEPE falls 90 % and the keeper liquidates a PEPE/USDC position", memeCrash),
  ];
}
