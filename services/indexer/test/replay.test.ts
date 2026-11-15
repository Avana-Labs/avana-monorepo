// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Replay and reorg properties of the handlers (README, Reorgs and checkpoints), on one scripted history:
// - replaying every log again (a restart from an older checkpoint) changes no table;
// - the same history delivered through every source that follows a Hub or Spoke gives the tables of one delivery;
// - a reorg, which Ponder handles by reverting every table to the common ancestor and running the new branch, leaves
//   exactly the tables of a fresh run over the canonical chain, with no row of the dropped branch left.

import { describe, expect, it } from "vitest";
import { type LogSpec, Run, addr, blockHash } from "./harness/run.ts";

const ADAPTER = addr(0xa0);
const MANAGER = addr(0xa1);
const REGISTRY = addr(0xa2);
const SPOKE = addr(0xb0);
const HUB = addr(0xb1);
const C = addr(0xa3);
const LP_VAULT = addr(0xe0);
const wallet = (i: number) => addr(0xc00 + i);
const proxy = (i: number) => addr(0xd00 + i);
const key = (i: number) => `0x${i.toString(16).padStart(64, "0")}` as const;
const noPremium = { sharesDelta: 0n, offsetRayDelta: 0n, restoredPremiumRay: 0n };

function account(i: number, block: bigint): LogSpec[] {
  const args = { wallet: wallet(i), spoke: SPOKE, marketId: 1n, proxy: proxy(i) };
  return [
    { source: "AaveAdapter", event: "UserProxyCreated", args, address: ADAPTER, block, logIndex: 0 },
    { source: "ProxyManager", event: "ProxyDeployed", args, address: MANAGER, block, logIndex: 1 },
    { source: "LPVault", event: "PositionReceived", args: { positionKey: key(i), marketId: 1n, depositor: wallet(i), units: 100n }, address: LP_VAULT, block, logIndex: 2 },
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
  { source: "MarketRegistry", event: "MarketRegistered", args: { marketId: 1n, integrationId: 1, pool: addr(0xf5), poolId: key(0), tokens: [addr(0xf6), addr(0xf7)], vaultToken: addr(0xf0), lpOracle: addr(0xf8), spoke: SPOKE }, address: REGISTRY, block: 10n, logIndex: 1 },
  { source: "MarketRegistry", event: "MarketActivated", args: { marketId: 1n, chainId: 1n, spoke: SPOKE, reserveId: 1n, hub: HUB, hubAssetId: 3n }, address: REGISTRY, block: 10n, logIndex: 2 },
  { source: "AvanaTimelock", event: "CallScheduled", args: { id: key(9), index: 0n, target: REGISTRY, value: 0n, data: "0x1234", predecessor: key(0), delay: 3_600n }, address: addr(0xa5), block: 10n, logIndex: 3 },
  config(10n, 1_000),
  ...account(1, 11n),
  ...account(2, 12n),
  borrow(1, 13n, 3, 5_000n),
  premium(1, 13n, 4, 200n),
  borrow(2, 14n, 3, 2_000n),
  premium(2, 14n, 4, 210n),
  { source: "MarketRegistry", event: "BreakerLatched", args: { scope: 0, key: key(1), reasons: 4 }, address: REGISTRY, block: 14n, logIndex: 7 },
  { source: "Collateralization", event: "CollateralPledged", args: { recordId: 1n, positionKey: key(1), depositor: wallet(1), integrationId: 1, proxy: proxy(1), vaultToken: addr(0xf0), credited: 100n, usdCharge: 1n, sliceUsd: 1n }, address: C, block: 14n, logIndex: 8 },
  { source: "PayoutEscrow", event: "RemainderEscrowed", args: { token: addr(0xf3), account: wallet(2), amount: 40n }, address: addr(0xa4), block: 14n, logIndex: 9 },
];

/** Branch a, blocks 15–18: repayments, a collateral-risk change and a seizure. */
const branchA: LogSpec[] = [
  repay(1, 15n, 0, 1_000n),
  config(16n, 1_500),
  premium(1, 17n, 0, 260n),
  { source: "Collateralization", event: "RecordReduced", args: { recordId: 1n, units: 30n, release: 0n }, address: C, block: 17n, logIndex: 1 },
  { source: "PayoutEscrow", event: "RemainderClaimed", args: { token: addr(0xf3), account: wallet(2), recipient: wallet(2), amount: 15n }, address: addr(0xa4), block: 17n, logIndex: 2 },
  { source: "Collateralization", event: "SeizureReconciled", args: { proxy: proxy(2), vaultToken: addr(0xf0), units: 9n, amounts: [1n, 2n] }, address: C, block: 18n, logIndex: 0 },
];

/** Branch b, blocks 15–19: a different repayment, no risk change, a third account and a breaker reset. */
const branchB: LogSpec[] = [
  repay(2, 15n, 0, 2_000n),
  ...account(3, 16n),
  borrow(3, 17n, 3, 700n),
  { source: "MarketRegistry", event: "BreakerReset", args: { scope: 0, key: key(1), caller: REGISTRY }, address: REGISTRY, block: 18n, logIndex: 0 },
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

/** Each Spoke log through every Spoke source and each Hub log through every Hub source, as Ponder delivers them. */
const throughEverySource = (logs: readonly LogSpec[]) =>
  logs.flatMap((l) =>
    l.source === "AaveSpoke" ? ["AaveSpoke", "AaveSpokeAdded", "AaveSpokeApproved"].map((source) => ({ ...l, source }))
    : l.source === "AaveHub" ? ["AaveHub", "AaveHubRecorded"].map((source) => ({ ...l, source }))
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
