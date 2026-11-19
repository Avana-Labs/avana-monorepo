// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Fee classes (keeper DESIGN.md, Fees): urgent keeps today's rule (the 90th percentile of the last 5 blocks, at least
// minTipUrgent), scheduled pays minTipScheduled, lazy pays minTipLazy only at a low base fee and
// otherwise waits up to lazyMaxWait, then goes at scheduled fees. Max fee is 2 × base + tip and the per-transaction
// ceiling applies to every class; a liquidation still pre-empts a pending poke.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type Address, type PublicClient, serializeTransaction } from "viem";
import { CHAINS } from "@avana/services-common";
import { type FeePolicy, GWEI, bumpFees, classFees, gasLimit, priorityFee } from "../src/chain/gas.ts";
import type { ChainReader } from "../src/chain/reads.ts";
import type { TxSigner } from "../src/chain/signer.ts";
import { type ChainConfig, defaultFeePolicy, feePolicy } from "../src/config.ts";
import { InventoryBook } from "../src/inventory.ts";
import { AboveGasCeiling, NotSent, Submitter } from "../src/runtime/submitter.ts";
import type { BlockContext, JobClass, TxPlan } from "../src/types.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;

const POLICY: FeePolicy = { minTipUrgent: GWEI, minTipScheduled: GWEI / 10n, minTipLazy: GWEI / 100n, lazyBaseFeeMax: 5n * GWEI, lazyMaxWaitSeconds: 3_600n };

const plan = (jobClass: JobClass, n = 1): TxPlan => ({
  job: jobClass === "urgent" ? "liquidation" : "settlePending",
  jobClass,
  subject: `1:${addr(0x100 + n)}`,
  to: addr(0xf1),
  data: "0x1234",
  deadline: jobClass === "urgent" ? 10_000n : null,
  reservations: [],
  targets: [],
  params: { oracle: addr(0x100 + n) },
});

function setup(fee: { rewards: bigint[]; base: bigint }, ceilingWei = 10n ** 30n, fees: FeePolicy = POLICY) {
  const client = {
    getFeeHistory: async () => ({ reward: fee.rewards.map((r) => [r]), baseFeePerGas: [fee.base] }),
    readContract: async () => 10n ** 30n,
    getTransactionCount: async () => 5,
    getBlock: async () => ({ number: 0n }),
    call: async () => ({ data: "0x" }),
    estimateGas: async () => 100_000n,
  } as unknown as PublicClient;
  const signer: TxSigner = { address: addr(0x51), signTransaction: async (tx) => serializeTransaction(tx) };
  const post = vi.fn(async () => ({}));
  const onCeiling = vi.fn();
  const cfg = { chain: CHAINS.mainnet, rpc: { privateSend: ["http://builder"] } } as unknown as ChainConfig;
  const s = new Submitter(cfg, client, signer, new InventoryBook(), post, addr(0x5afe), { ceilingWei, l1Fee: null, onCeiling, fees });
  return { s, post, onCeiling };
}

const ctx = (timestamp: bigint, blockNumber = 10n): BlockContext => ({ config: { chain: CHAINS.mainnet } as ChainConfig, blockNumber, blockTimestamp: timestamp, reader: {} as ChainReader });
const sim = { ok: true, gasEstimate: 100_000n };

beforeEach(() => {
  vi.spyOn(process.stdout, "write").mockImplementation(() => true);
});
afterEach(() => vi.restoreAllMocks());

describe("fee classes", () => {
  it("urgentNeverBelowP90", async () => {
    const rewards = [3n * GWEI, 5n * GWEI, 2n * GWEI, 8n * GWEI, 4n * GWEI];
    const p90 = priorityFee(rewards);
    expect(p90).toBe(8n * GWEI);
    for (const minTipUrgent of [GWEI, 8n * GWEI, 9n * GWEI]) {
      const d = classFees("urgent", rewards, 10n * GWEI, { ...POLICY, minTipUrgent });
      expect(d.send).toBe(true);
      if (!d.send) return;
      expect(d.maxPriorityFeePerGas).toBeGreaterThanOrEqual(p90);
      expect(d.maxPriorityFeePerGas).toBeGreaterThanOrEqual(minTipUrgent);
      expect(d.maxFeePerGas).toBe(20n * GWEI + d.maxPriorityFeePerGas);
    }
    // Quiet blocks: the floor, which is 1 gwei by default on every chain, so the urgent rule is today's rule.
    expect(classFees("urgent", [1n], 0n, POLICY)).toMatchObject({ maxPriorityFeePerGas: GWEI });
    for (const c of Object.values(CHAINS)) expect(defaultFeePolicy(c).minTipUrgent).toBe(GWEI);

    // A liquidation sent through the submitter pays the p90 even under a low scheduled tip.
    const { s } = setup({ rewards, base: 10n * GWEI });
    await s.submit(ctx(900n), plan("urgent"), sim);
    expect(s.pending.get(plan("urgent").subject)!.fees).toEqual({ maxPriorityFeePerGas: 8n * GWEI, maxFeePerGas: 28n * GWEI });
  });

  it("scheduledPaysScheduledTip", async () => {
    // A scheduled transaction is sent at the scheduled tip, not the p90, with max fee 2 × base + tip.
    const { s } = setup({ rewards: [9n * GWEI], base: 10n * GWEI });
    await s.submit(ctx(900n), plan("scheduled"), sim);
    expect(s.pending.get(plan("scheduled").subject)!.fees).toEqual({ maxPriorityFeePerGas: GWEI / 10n, maxFeePerGas: 20n * GWEI + GWEI / 10n });
  });

  it("lazyWaitsForBaseFee", async () => {
    const high = setup({ rewards: [GWEI], base: 6n * GWEI });
    await expect(high.s.submit(ctx(1_000n), plan("lazy"), sim)).rejects.toMatchObject({ reason: "lazyBaseFeeHigh" });
    await expect(high.s.submit(ctx(1_012n), plan("lazy"), sim)).rejects.toBeInstanceOf(NotSent);
    expect(high.post).not.toHaveBeenCalled();
    expect(high.s.pending.size).toBe(0);

    const low = setup({ rewards: [GWEI], base: 5n * GWEI }); // at lazyBaseFeeMax: sent at the lazy tip
    await low.s.submit(ctx(1_000n), plan("lazy"), sim);
    expect(low.s.pending.get(plan("lazy").subject)!.fees).toEqual({ maxPriorityFeePerGas: GWEI / 100n, maxFeePerGas: 10n * GWEI + GWEI / 100n });
  });

  it("lazySendsAtMaxWait", async () => {
    const { s, post } = setup({ rewards: [GWEI], base: 6n * GWEI });
    for (let t = 1_000n; t < 1_000n + 3_600n; t += 600n) await expect(s.submit(ctx(t), plan("lazy"), sim)).rejects.toBeInstanceOf(NotSent);
    await expect(s.submit(ctx(4_599n), plan("lazy"), sim)).rejects.toBeInstanceOf(NotSent);
    expect(post).not.toHaveBeenCalled();
    await s.submit(ctx(4_600n), plan("lazy"), sim); // 3,600 s after it first fell due: scheduled fees
    expect(s.pending.get(plan("lazy").subject)!.fees).toEqual({ maxPriorityFeePerGas: GWEI / 10n, maxFeePerGas: 12n * GWEI + GWEI / 10n });
    // A subject not seen due for longer than lazyMaxWait starts waiting again.
    const other = plan("lazy", 2);
    await expect(s.submit(ctx(5_000n), other, sim)).rejects.toBeInstanceOf(NotSent);
    await expect(s.submit(ctx(5_000n + 3_601n), other, sim)).rejects.toBeInstanceOf(NotSent);
  });

  it("ceilingStillApplies", async () => {
    const base = 10n * GWEI;
    for (const c of ["urgent", "scheduled", "lazy"] as const) {
      const fees = classFees(c, [2n * GWEI], base, { ...POLICY, lazyBaseFeeMax: base });
      if (!fees.send) throw new Error("expected a send");
      const cost = gasLimit(100_000n) * fees.maxFeePerGas;
      const within = setup({ rewards: [2n * GWEI], base }, cost, { ...POLICY, lazyBaseFeeMax: base });
      await within.s.submit(ctx(900n), plan(c), sim);
      expect(within.post).toHaveBeenCalledOnce();
      const above = setup({ rewards: [2n * GWEI], base }, cost - 1n, { ...POLICY, lazyBaseFeeMax: base });
      await expect(above.s.submit(ctx(900n), plan(c), sim)).rejects.toBeInstanceOf(AboveGasCeiling);
      expect(above.onCeiling).toHaveBeenCalledOnce();
      expect(above.post).not.toHaveBeenCalled();
    }
  });

  it("a liquidation still pre-empts a pending scheduled poke, at the urgent fees or the bump, whichever is higher", async () => {
    const { s } = setup({ rewards: [3n * GWEI], base: 10n * GWEI });
    const preempted = vi.fn();
    s.preempted = preempted;
    await s.submit(ctx(900n), plan("scheduled"), sim);
    const pokeFees = s.pending.get(plan("scheduled").subject)!.fees;
    const liquidation = { ...plan("urgent", 9), subject: `1:${addr(0x5)}:${addr(0xbeef)}` };
    await s.submit(ctx(912n, 11n), liquidation, sim);
    const l = s.pending.get(liquidation.subject)!;
    expect(l.nonce).toBe(5);
    const bumped = bumpFees(pokeFees);
    expect(l.fees.maxPriorityFeePerGas).toBe(3n * GWEI > bumped.maxPriorityFeePerGas ? 3n * GWEI : bumped.maxPriorityFeePerGas);
    expect(l.fees.maxFeePerGas).toBe(23n * GWEI > bumped.maxFeePerGas ? 23n * GWEI : bumped.maxFeePerGas);
    expect(preempted).toHaveBeenCalledWith(plan("scheduled"));
  });
});

describe("fee class configuration", () => {
  it("defaults per chain, lower on Base, and reads KEEPER_MIN_TIP_* and KEEPER_LAZY_* per chain", () => {
    const eth = defaultFeePolicy(CHAINS.mainnet);
    const base = defaultFeePolicy(CHAINS.base);
    expect(base.minTipScheduled).toBeLessThan(eth.minTipScheduled);
    expect(base.minTipLazy).toBeLessThan(eth.minTipLazy);
    expect(feePolicy({}, CHAINS.base)).toEqual(base);
    expect(feePolicy({ KEEPER_MIN_TIP_SCHEDULED_BASE: "2000000", KEEPER_LAZY_MAX_WAIT_BASE: "600", KEEPER_LAZY_BASEFEE_MAX_BASE: "7" }, CHAINS.base)).toMatchObject({ minTipScheduled: 2_000_000n, lazyMaxWaitSeconds: 600n, lazyBaseFeeMax: 7n });
  });

  it("refuses a value that is not a positive whole number, and tips that rise from urgent to lazy", () => {
    expect(() => feePolicy({ KEEPER_MIN_TIP_URGENT_MAINNET: "0" }, CHAINS.mainnet)).toThrow(/positive integer number of wei/);
    expect(() => feePolicy({ KEEPER_MIN_TIP_LAZY_MAINNET: "1.5" }, CHAINS.mainnet)).toThrow(/positive integer/);
    expect(() => feePolicy({ KEEPER_LAZY_MAX_WAIT_MAINNET: "-1" }, CHAINS.mainnet)).toThrow(/seconds/);
    expect(() => feePolicy({ KEEPER_MIN_TIP_SCHEDULED_MAINNET: String(2n * GWEI) }, CHAINS.mainnet)).toThrow(/must not exceed KEEPER_MIN_TIP_URGENT_MAINNET/);
    expect(() => feePolicy({ KEEPER_MIN_TIP_LAZY_MAINNET: String(GWEI) }, CHAINS.mainnet)).toThrow(/must not exceed KEEPER_MIN_TIP_SCHEDULED_MAINNET/);
  });
});
