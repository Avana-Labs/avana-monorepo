// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Replay and reorg properties of the handlers (README, Reorgs and checkpoints), on one scripted history:
// - replaying every log again (a restart from an older checkpoint) changes no table;
// - the same history delivered through every source that follows a Hub or Spoke gives the tables of one delivery;
// - a reorg, which Ponder handles by reverting every table to the common ancestor and running the new branch, leaves
//   exactly the tables of a fresh run over the canonical chain, with no row of the dropped branch left.

import { describe, expect, it } from "vitest";
import { type LogSpec, Run, addr, blockHash } from "./harness/run.ts";
import { V3 } from "./harness/manifest.ts";

const ADAPTER = V3.aaveAdapter;
const SPOKE = addr(0xb0);
const HUB = addr(0xb1);
const LP_VAULT = V3.lpVault;
const VAULT = addr(0xf0);
const POOL = `0x${"00".repeat(12)}${addr(0xf5).slice(2)}` as const;
const wallet = (i: number) => addr(0xc00 + i);
const proxy = (i: number) => addr(0xd00 + i);
const key = (i: number) => `0x${i.toString(16).padStart(64, "0")}` as const;
const noPremium = { sharesDelta: 0n, offsetRayDelta: 0n, restoredPremiumRay: 0n };

function account(i: number, block: bigint): LogSpec[] {
  return [
    { source: "AaveAdapter", event: "AccountCreated", args: { wallet: wallet(i), marketId: 1n, account: proxy(i) }, address: ADAPTER, block, logIndex: 0 },
    { source: "LPVault", event: "PositionPledged", args: { positionKey: key(i), account: proxy(i), marketId: 1n, from: wallet(i), liquidity: 100n, credit: 100n }, address: LP_VAULT, block, logIndex: 1 },
    { source: "AaveAdapter", event: "Pledged", args: { wallet: wallet(i), marketId: 1n, positionKey: key(i), credit: 100n }, address: ADAPTER, block, logIndex: 2 },
    { source: "VaultTokenListed", event: "Transfer", args: { from: addr(0), to: proxy(i), value: 100n }, address: VAULT, block, logIndex: 7 },
  ];
}

const borrow = (i: number, block: bigint, logIndex: number, shares: bigint, source = "AaveSpoke"): LogSpec => ({
  source, event: "Borrow", args: { reserveId: 2n, caller: ADAPTER, user: proxy(i), drawnShares: shares, drawnAmount: shares }, address: SPOKE, block, logIndex,
});
const repay = (i: number, block: bigint, logIndex: number, shares: bigint, source = "AaveSpoke"): LogSpec => ({
  source, event: "Repay", args: { reserveId: 2n, caller: ADAPTER, user: proxy(i), drawnShares: shares, totalAmountRepaid: shares, premiumDelta: noPremium }, address: SPOKE, block, logIndex,
});
const premium = (i: number, block: bigint, logIndex: number, value: bigint, source = "AaveSpoke"): LogSpec => ({
  source, event: "UpdateUserRiskPremium", args: { user: proxy(i), riskPremium: value }, address: SPOKE, block, logIndex,
});
const config = (block: bigint, risk: number, source = "AaveSpoke"): LogSpec => ({
  source, event: "UpdateReserveConfig", args: { reserveId: 1n, config: { collateralRisk: risk, paused: false, frozen: false, borrowable: false, receiveSharesEnabled: false } }, address: SPOKE, block, logIndex: 5,
});
const addSpoke = (block: bigint, source = "AaveHub"): LogSpec => ({ source, event: "AddSpoke", args: { assetId: 3n, spoke: SPOKE }, address: HUB, block, logIndex: 6 });

/** Blocks 10–14, shared by both branches. */
const common: LogSpec[] = [
  addSpoke(10n),
  { source: "RiskModule", event: "MarketListed", args: { marketId: 1n, pool: POOL, kind: 0, bandLower: -887_270, bandUpper: 887_270, unitDecimals: 18 }, address: V3.riskModule, block: 10n, logIndex: 1 },
  { source: "RiskModule", event: "MarketListed", args: { marketId: 2n, pool: POOL, kind: 1, bandLower: -100, bandUpper: 100, unitDecimals: 18 }, address: V3.riskModule, block: 10n, logIndex: 2 },
  { source: "RiskModule", event: "PoolListed", args: { pool: POOL, spoke: SPOKE, fullRange: 1n, customRange: 2n, listingTick: 0, ltvBps: 9_000 }, address: V3.riskModule, block: 10n, logIndex: 3 },
  { source: "RiskModule", event: "MarketActivated", args: { marketId: 1n, vaultToken: VAULT, reserveId: 1n, lpOracle: addr(0xf8) }, address: V3.riskModule, block: 10n, logIndex: 4 },
  config(10n, 1_000),
  ...account(1, 11n),
  ...account(2, 12n),
  borrow(1, 13n, 3, 5_000n),
  premium(1, 13n, 4, 200n),
  borrow(2, 14n, 3, 2_000n),
  premium(2, 14n, 4, 210n),
  { source: "FirstLossReserveListed", event: "Funded", args: { funder: wallet(2), amount: 40n, shares: 40n, balanceAfter: 40n }, address: addr(0xa4), block: 14n, logIndex: 9 },
];

/** Branch a, blocks 15–18: repayments, a collateral-risk change, a partial withdrawal and a liquidation. */
const branchA: LogSpec[] = [
  repay(1, 15n, 0, 1_000n),
  config(16n, 1_500),
  premium(1, 17n, 0, 260n),
  { source: "LPVault", event: "LiquidityRemoved", args: { positionKey: key(1), recipient: wallet(1), liquidity: 30n, credit: 30n, amount0: 1n, amount1: 1n }, address: LP_VAULT, block: 17n, logIndex: 1 },
  { source: "FirstLossReserveListed", event: "DeficitCovered", args: { spoke: SPOKE, caller: wallet(2), covered: 15n, shares: 15n, balanceAfter: 25n }, address: addr(0xa4), block: 17n, logIndex: 2 },
  { source: "LiquidationModule", event: "Liquidated", args: { account: proxy(2), marketId: 1n, liquidator: addr(0xf7), debtReserveId: 2n, debtRepaid: 50n, seized: 9n, creditUnwound: 9n, amount0: 1n, amount1: 2n }, address: V3.liquidationModule, block: 18n, logIndex: 0 },
  { source: "LPVault", event: "PositionUnwound", args: { positionKey: key(2), recipient: addr(0xf7), liquidity: 9n, credit: 9n, amount0: 1n, amount1: 2n }, address: LP_VAULT, block: 18n, logIndex: 1 },
];

/** Branch b, blocks 15–19: a different repayment, no risk change, and a third account. */
const branchB: LogSpec[] = [
  repay(2, 15n, 0, 2_000n),
  ...account(3, 16n),
  borrow(3, 17n, 3, 700n),
  premium(3, 19n, 0, 180n),
];

/** A run whose contract reads answer a fixed pool fee (the only read these handlers make, `fee()` at listing). */
function newRun() {
  const run = new Run();
  run.client.readContract = async () => 500;
  return run;
}

async function fresh(specs: { logs: readonly LogSpec[]; branch: string }[]) {
  const run = newRun();
  for (const s of specs) await run.deliverAll(s.logs, s.branch);
  return run.store.dump();
}

/** Each Spoke, loss-layer and vault-token log through every source that follows its contract, as Ponder delivers them. */
const throughEverySource = (logs: readonly LogSpec[]) =>
  logs.flatMap((l) =>
    l.source === "AaveSpoke" ? ["AaveSpoke", "AaveSpokeAdded"].map((source) => ({ ...l, source }))
    : l.source === "FirstLossReserveListed" ? ["FirstLossReserveListed", "FirstLossReserve", "DaoDeficitOffset"].map((source) => ({ ...l, source }))
    : l.source === "VaultTokenListed" ? ["VaultTokenListed", "VaultToken"].map((source) => ({ ...l, source }))
    : [l],
  );

describe("replay", () => {
  it("changes nothing when every log is delivered again", async () => {
    const once = await fresh([{ logs: [...common, ...branchA], branch: "a" }]);
    const run = newRun();
    await run.deliverAll([...common, ...branchA]);
    await run.deliverAll([...common, ...branchA]); // restart from the start blocks over a kept schema
    expect(run.store.dump()).toEqual(once);
  });

  it("gives the tables of one delivery when every source delivers each Hub and Spoke log", async () => {
    const once = await fresh([{ logs: [...common, ...branchA], branch: "a" }]);
    const all = await fresh([{ logs: throughEverySource([...common, ...branchA]), branch: "a" }]);
    expect(all).toEqual(once);
  });
});

describe("reorg", () => {
  it("leaves the tables of a fresh run over the canonical branch", async () => {
    const run = newRun();
    await run.deliverAll(common);
    const ancestor = run.store.snapshot();
    await run.deliverAll(branchA, "a");
    await run.progress(18n, "a");
    // Ponder reverts every table to the common ancestor (block 14), then runs the new branch.
    run.store.restore(ancestor);
    await run.deliverAll(branchB, "b");
    await run.progress(19n, "b");

    const canonical = newRun();
    await canonical.deliverAll(common);
    await canonical.deliverAll(branchB, "b");
    await canonical.progress(19n, "b");
    expect(run.store.dump()).toEqual(canonical.store.dump());

    const dropped = new Set([15n, 16n, 17n, 18n].map((n) => blockHash(n, "a")));
    for (const [table, rows] of Object.entries(run.store.dump())) {
      for (const r of rows) for (const v of Object.values(r)) expect(dropped.has(v as `0x${string}`), `${table} keeps a dropped block hash`).toBe(false);
    }
  });

  it("is order-independent across the two branches' shared prefix", async () => {
    // Running branch b alone after the prefix equals running a, reverting and running b: no state leaks from a.
    const a = await fresh([{ logs: common, branch: "a" }, { logs: branchB, branch: "b" }]);
    const run = newRun();
    await run.deliverAll(common);
    const ancestor = run.store.snapshot();
    await run.deliverAll(throughEverySource(branchA), "a");
    run.store.restore(ancestor);
    await run.deliverAll(throughEverySource(branchB), "b");
    expect(run.store.dump()).toEqual(a);
  });
});
