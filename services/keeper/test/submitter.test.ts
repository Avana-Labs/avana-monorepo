// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Submission limits and reorgs: a send whose worst-case cost (gas limit × max fee, plus Base's L1 data fee) passes
// the chain's ceiling is not signed, pages and releases its reservation; a replacement above it keeps waiting; a
// transaction seen mined returns to pending with its reservation when a reorg removes its block, until finality.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type Address, type PublicClient, serializeTransaction } from "viem";
import { CHAINS } from "@avana/services-common";
import { GWEI, gasLimit, paysL1DataFee } from "../src/chain/gas.ts";
import type { TxSigner } from "../src/chain/signer.ts";
import type { ChainConfig } from "../src/config.ts";
import type { ChainReader } from "../src/chain/reads.ts";
import { InventoryBook } from "../src/inventory.ts";
import { AboveGasCeiling, type GasPolicy, Submitter } from "../src/runtime/submitter.ts";
import type { BlockContext, TxPlan } from "../src/types.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const SIGNER = addr(0x51);
const ASSET = addr(0xa5);
const SAFE = addr(0x5afe);

// Fee history: p90 tip 2 gwei, base fee 10 gwei → max fee 22 gwei. Estimate 100,000 → limit 155,000.
const MAX_FEE = 22n * GWEI;
const LIMIT = gasLimit(100_000n);
const L2_COST = LIMIT * MAX_FEE;

const plan: TxPlan = {
  job: "liquidation",
  subject: `1:${addr(0x5)}:${addr(0xbeef)}`,
  to: addr(0xf1),
  data: "0x1234",
  deadline: 1_000n,
  reservations: [{ asset: ASSET, amount: 500n }],
  targets: [],
  params: { debtToCover: 500n },
};

function setup(gas: Partial<GasPolicy> & { ceilingWei: bigint }, chain = CHAINS.mainnet) {
  const state = { pendingCount: 5, confirmed: 5, finalized: 0n };
  const client = {
    getFeeHistory: async () => ({ reward: [[2n * GWEI]], baseFeePerGas: [10n * GWEI] }),
    readContract: async () => 10n ** 30n,
    getTransactionCount: async (q: { blockTag?: string }) => (q.blockTag === "pending" ? state.pendingCount : state.confirmed),
    getBlock: async () => ({ number: state.finalized }),
    call: async () => ({ data: "0x" }),
    estimateGas: async () => 100_000n,
  } as unknown as PublicClient;
  const signer: TxSigner = { address: SIGNER, signTransaction: async (tx) => serializeTransaction(tx) };
  const post = vi.fn(async () => ({}));
  const inventory = new InventoryBook();
  const onCeiling = vi.fn();
  const cfg = { chain, rpc: { privateSend: ["http://builder"] } } as unknown as ChainConfig;
  const s = new Submitter(cfg, client, signer, inventory, post, SAFE, { l1Fee: null, onCeiling, ...gas });
  return { s, state, post, inventory, onCeiling };
}

const ctx = (blockNumber: bigint, timestamp = 900n): BlockContext => ({
  config: { chain: CHAINS.mainnet } as ChainConfig,
  blockNumber,
  blockTimestamp: timestamp,
  reader: {} as ChainReader,
});
const sim = { ok: true, gasEstimate: 100_000n };

let lines: Record<string, unknown>[];
beforeEach(() => {
  lines = [];
  vi.spyOn(process.stdout, "write").mockImplementation((x: string | Uint8Array) => {
    lines.push(JSON.parse(String(x)));
    return true;
  });
});
afterEach(() => vi.restoreAllMocks());

describe("gas ceiling", () => {
  it("sends a call whose worst-case cost is within the ceiling", async () => {
    const { s, post, inventory } = setup({ ceilingWei: L2_COST });
    await s.submit(ctx(10n), plan, sim);
    expect(post).toHaveBeenCalledOnce();
    expect(inventory.reserved(1, ASSET)).toBe(500n);
  });

  it("refuses a call above it: nothing signed or sent, a page, the reservation released", async () => {
    const { s, post, inventory, onCeiling } = setup({ ceilingWei: L2_COST - 1n });
    await expect(s.submit(ctx(10n), plan, sim)).rejects.toBeInstanceOf(AboveGasCeiling);
    expect(post).not.toHaveBeenCalled();
    expect(onCeiling).toHaveBeenCalledWith(expect.objectContaining({ cost: L2_COST.toString(), ceiling: (L2_COST - 1n).toString(), l1DataFee: "0" }));
    expect(inventory.reserved(1, ASSET)).toBe(0n);
    expect(lines).toContainEqual(expect.objectContaining({ outcome: "aboveGasCeiling", subject: plan.subject }));
    // The nonce was not used: the next send takes the same one.
    expect(s.pending.size).toBe(0);
  });

  it("adds Base's L1 data fee to the cost", async () => {
    expect(paysL1DataFee(CHAINS.base)).toBe(true);
    expect(paysL1DataFee(CHAINS.baseSepolia)).toBe(true);
    expect(paysL1DataFee(CHAINS.mainnet)).toBe(false);
    const l1Fee = vi.fn(async () => 7_000n);
    const within = setup({ ceilingWei: L2_COST + 7_000n, l1Fee }, CHAINS.base);
    await within.s.submit(ctx(10n), plan, sim);
    expect(l1Fee).toHaveBeenCalledWith(expect.objectContaining({ to: plan.to, data: plan.data, nonce: 5, gas: LIMIT, maxFeePerGas: MAX_FEE }));
    const above = setup({ ceilingWei: L2_COST + 6_999n, l1Fee }, CHAINS.base);
    await expect(above.s.submit(ctx(10n), plan, sim)).rejects.toBeInstanceOf(AboveGasCeiling);
  });

  it("keeps a pending transaction waiting when its replacement would pass the ceiling", async () => {
    // The first send costs L2_COST; a replacement raises the max fee by 15 %, above a ceiling set at L2_COST.
    const { s, post, onCeiling } = setup({ ceilingWei: L2_COST });
    await s.submit(ctx(10n), plan, sim);
    const hash = s.pending.get(plan.subject)!.hash;
    await s.followUps(ctx(11n), async () => true, () => {});
    expect(post).toHaveBeenCalledOnce();
    expect(onCeiling).toHaveBeenCalledOnce();
    expect(s.pending.get(plan.subject)!.hash).toBe(hash);
    expect(lines).toContainEqual(expect.objectContaining({ outcome: "aboveGasCeiling", txHash: hash }));
  });
});

describe("reorgs", () => {
  it("returns a transaction mined in a removed block to pending, with its reservation and flag", async () => {
    const { s, state, inventory } = setup({ ceilingWei: 10n ** 30n });
    await s.submit(ctx(10n), plan, sim);
    const hash = s.pending.get(plan.subject)!.hash;

    state.confirmed = 6; // nonce 5 consumed at block 11
    const done = vi.fn();
    await s.followUps(ctx(11n), async () => true, done);
    expect(done).toHaveBeenCalledOnce();
    expect(s.pending.size).toBe(0);
    expect(s.mined.size).toBe(1);
    expect(inventory.reserved(1, ASSET)).toBe(0n);

    state.confirmed = 5; // the reorg removed it
    const restored = vi.fn();
    expect(await s.onReorg(11n, restored)).toBe(1);
    expect(restored).toHaveBeenCalledWith(plan, hash);
    expect(s.pending.get(plan.subject)).toMatchObject({ nonce: 5, hash });
    expect(s.mined.size).toBe(0);
    expect(inventory.reserved(1, ASSET)).toBe(500n);
    expect(lines).toContainEqual(expect.objectContaining({ outcome: "reorged", txHash: hash, nonce: 5 }));
  });

  it("leaves a transaction alone when the reorg kept it, and forgets it once finalized", async () => {
    const { s, state } = setup({ ceilingWei: 10n ** 30n });
    await s.submit(ctx(10n), plan, sim);
    state.confirmed = 6;
    await s.followUps(ctx(11n), async () => true, () => {});
    expect(await s.onReorg(12n, vi.fn())).toBe(0);
    expect(s.mined.size).toBe(1);
    state.finalized = 11n;
    await s.followUps(ctx(12n), async () => true, () => {});
    expect(s.mined.size).toBe(0);
  });
});
