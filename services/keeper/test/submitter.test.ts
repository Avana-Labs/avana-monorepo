// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Submission limits and reorgs: a send whose worst-case cost (gas limit × max fee, plus Base's L1 data fee) passes
// the chain's ceiling is not signed, pages and releases its reservation; a replacement above it keeps waiting; a
// transaction seen mined returns to pending with its reservation when a reorg removes its block, until finality.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type Address, type PublicClient, serializeTransaction } from "viem";
import { CHAINS } from "@avana/services-common";
import { GWEI, bumpFees, gasLimit, paysL1DataFee } from "../src/chain/gas.ts";
import type { TxSigner } from "../src/chain/signer.ts";
import type { ChainConfig } from "../src/config.ts";
import type { ChainReader } from "../src/chain/reads.ts";
import { InventoryBook } from "../src/inventory.ts";
import { sendPrivate } from "../src/chain/submit.ts";
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
  jobClass: "urgent",
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

describe("follow-ups", () => {
  it("waits in the block the transaction was sent in, even when its simulation already fails", async () => {
    // A poke sent at block 10 and mined at once (anvil): state read at block 10 cannot show it, and its re-simulation
    // fails because the breaker is already recorded; cancelling there would send at a consumed nonce.
    const { s, post } = setup({ ceilingWei: 10n ** 30n });
    const poke: TxPlan = { ...plan, job: "settlePending", subject: `1:${addr(0x0c)}`, deadline: null, reservations: [] };
    await s.submit(ctx(10n), poke, sim);
    const client = (s as unknown as { client: { call: () => Promise<unknown> } }).client;
    client.call = async () => {
      throw new Error("already poked");
    };
    await s.followUps(ctx(10n), async () => true, () => {});
    expect(post).toHaveBeenCalledOnce();
    expect(s.pending.has(poke.subject)).toBe(true);
  });

  it("logs a refused cancellation and keeps the transaction pending; the next block finds it mined", async () => {
    const { s, state, post, inventory } = setup({ ceilingWei: 10n ** 30n });
    await s.submit(ctx(10n), plan, sim);
    // Past the deadline, no longer due, 2 blocks on: cancel. The node refuses it (the original was mined meanwhile).
    post.mockRejectedValueOnce(new Error("nonce too low"));
    await expect(s.followUps(ctx(12n, 2_000n), async () => false, () => {})).resolves.toBeUndefined();
    expect(lines).toContainEqual(expect.objectContaining({ outcome: "sendRefused", nonce: 5, reason: expect.stringContaining("refused") }));
    expect(s.pending.has(plan.subject)).toBe(true);
    expect(inventory.reserved(1, ASSET)).toBe(500n);

    state.confirmed = 6;
    const done = vi.fn();
    await s.followUps(ctx(13n, 2_012n), async () => false, done);
    expect(done).toHaveBeenCalledOnce();
    expect(s.pending.size).toBe(0);
    expect(inventory.reserved(1, ASSET)).toBe(0n);
  });

  it("logs a refused replacement and keeps the original hash", async () => {
    const { s, post } = setup({ ceilingWei: 10n ** 30n });
    await s.submit(ctx(10n), plan, sim);
    const hash = s.pending.get(plan.subject)!.hash;
    post.mockRejectedValueOnce(new Error("replacement underpriced"));
    await s.followUps(ctx(11n), async () => true, () => {});
    expect(s.pending.get(plan.subject)!.hash).toBe(hash);
    expect(lines).toContainEqual(expect.objectContaining({ outcome: "sendRefused", txHash: hash }));
  });
});

describe("private send", () => {
  it("names each endpoint's refusal, so a refused replacement shows why (nonce too low, underpriced, funds)", async () => {
    const post = vi.fn(async (url: string) => {
      throw new Error(url === "https://a" ? "nonce too low" : "replacement transaction underpriced");
    });
    await expect(sendPrivate(["https://a", "https://b"], "0x01", post)).rejects.toThrow(
      "every private endpoint refused the transaction: https://a: nonce too low; https://b: replacement transaction underpriced",
    );
  });

  it("resolves with the endpoints that accepted when at least one did", async () => {
    const post = vi.fn(async (url: string) => {
      if (url === "https://a") throw new Error("down");
      return "0xhash";
    });
    await expect(sendPrivate(["https://a", "https://b"], "0x01", post)).resolves.toEqual(["https://b"]);
  });
});

describe("liquidation pre-emption", () => {
  const poke = (n: number): TxPlan => ({ ...plan, job: "settlePending", subject: `1:${addr(0x100 + n)}`, deadline: null, reservations: [], params: { marketId: BigInt(n) } });

  it("sends a due liquidation at the lowest nonce a pending poke holds, as a replacement of that poke at a higher fee", async () => {
    const { s, post } = setup({ ceilingWei: 10n ** 30n });
    const preempted = vi.fn();
    s.preempted = preempted;
    for (let i = 0; i < 3; i++) await s.submit(ctx(10n), poke(i), sim);
    expect([...s.pending.values()].map((p) => p.nonce)).toEqual([5, 6, 7]);
    const pokeFees = s.pending.get(poke(0).subject)!.fees;

    await s.submit(ctx(11n), plan, sim);
    const liquidation = s.pending.get(plan.subject)!;
    expect(liquidation.nonce).toBe(5);
    expect(liquidation.fees.maxFeePerGas).toBe(bumpFees(pokeFees).maxFeePerGas);
    expect(liquidation.fees.maxPriorityFeePerGas).toBe(bumpFees(pokeFees).maxPriorityFeePerGas);
    expect(post).toHaveBeenCalledTimes(4);
    // The poke at nonce 5 is dropped and handed back to be sent again; the later pokes keep their nonces.
    expect(s.pending.has(poke(0).subject)).toBe(false);
    expect(s.pending.get(poke(1).subject)!.nonce).toBe(6);
    expect(s.pending.get(poke(2).subject)!.nonce).toBe(7);
    expect(preempted).toHaveBeenCalledWith(poke(0));
    expect(lines).toContainEqual(expect.objectContaining({ job: "settlePending", subject: poke(0).subject, outcome: "preempted", nonce: 5 }));
    // The pre-emption took no new nonce: the next send gets 8.
    await s.submit(ctx(11n), poke(9), sim);
    expect(s.pending.get(poke(9).subject)!.nonce).toBe(8);
  });

  it("never pre-empts a pending liquidation, nor a poke whose nonce is already mined", async () => {
    const { s, state } = setup({ ceilingWei: 10n ** 30n });
    const other: TxPlan = { ...plan, subject: `1:${addr(0x5)}:${addr(0xcafe)}` };
    await s.submit(ctx(10n), other, sim);
    await s.submit(ctx(10n), poke(0), sim);
    state.confirmed = 7;
    await s.submit(ctx(11n), plan, sim);
    expect(s.pending.get(other.subject)!.nonce).toBe(5);
    expect(s.pending.get(poke(0).subject)!.nonce).toBe(6);
    expect(s.pending.get(plan.subject)!.nonce).toBe(7);
    expect(lines.some((l) => l.outcome === "preempted")).toBe(false);
  });

  it("sends at a fresh nonce when the node refuses the pre-emption, and keeps the poke pending", async () => {
    const { s, post } = setup({ ceilingWei: 10n ** 30n });
    await s.submit(ctx(10n), poke(0), sim);
    post.mockRejectedValueOnce(new Error("nonce too low"));
    await s.submit(ctx(11n), plan, sim);
    expect(s.pending.get(poke(0).subject)!.nonce).toBe(5);
    expect(s.pending.get(plan.subject)!.nonce).toBe(6);
    expect(lines).toContainEqual(expect.objectContaining({ job: "liquidation", outcome: "sendRefused", nonce: 5, reason: expect.stringContaining("nonce too low") }));
  });
});
