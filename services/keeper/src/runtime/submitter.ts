// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Simulation, signing, private sending and per-block follow-up for one chain. Every send (first, replacement,
// rebuild, cancellation) is simulated first, signed through the KMS under the nonce lock and sent only through the
// chain's private endpoints.

import { type Address, type Hex, type PublicClient, erc20Abi, keccak256 } from "viem";
import type { ChainConfig } from "../config.ts";
import { type UnsignedTx, aboveCeiling, bumpFees, gasLimit, maxFee, priorityFee, worstCaseCost } from "../chain/gas.ts";
import { NonceManager } from "../chain/nonce.ts";
import type { TxSigner } from "../chain/signer.ts";
import { type Pending, followUp, sendPrivate } from "../chain/submit.ts";
import { logAttempt, stringifyParams } from "../failureLog.ts";
import { decodeRevert, revertData } from "../jobs/failureReasons.ts";
import type { InventoryBook } from "../inventory.ts";
import type { Simulation } from "../pipeline.ts";
import type { BlockContext, TxPlan } from "../types.ts";

export async function simulate(client: PublicClient, from: Address, plan: Pick<TxPlan, "to" | "data">): Promise<Simulation> {
  try {
    await client.call({ account: from, to: plan.to, data: plan.data, blockTag: "latest" });
    const gasEstimate = await client.estimateGas({ account: from, to: plan.to, data: plan.data, blockTag: "latest" });
    return { ok: true, gasEstimate };
  } catch (err) {
    // An error from a contract outside the liquidation ABIs keeps its selector only ("unknown").
    const revert = decodeRevert(revertData(err));
    return revert ? { ok: false, gasEstimate: 0n, revert } : { ok: false, gasEstimate: 0n };
  }
}

async function fees(client: PublicClient) {
  const history = await client.getFeeHistory({ blockCount: 5, rewardPercentiles: [90], blockTag: "latest" });
  const tip = priorityFee((history.reward ?? []).map((r) => r[0] ?? 0n));
  const base = history.baseFeePerGas[history.baseFeePerGas.length - 1] ?? 0n;
  return { maxPriorityFeePerGas: tip, maxFeePerGas: maxFee(base, tip) };
}

/** The per-chain fee ceiling (services/README.md, Submission > Gas): it only stops a fault from draining the gas wallet. */
export interface GasPolicy {
  /** Worst-case wei of one transaction: gas limit × max fee, plus the L1 data fee on Base. */
  readonly ceilingWei: bigint;
  /** The L1 data fee of an unsigned transaction on Base; null on chains without one. */
  readonly l1Fee: ((tx: UnsignedTx) => Promise<bigint>) | null;
  /** Pages the on-call engineer (M-17) when a send or a replacement would pass the ceiling. */
  onCeiling(detail: Readonly<Record<string, string>>): void;
}

export class AboveGasCeiling extends Error {
  constructor(readonly cost: bigint, readonly ceiling: bigint) {
    super(`aboveGasCeiling: worst-case cost ${cost} wei passes the ceiling ${ceiling} wei`);
  }
}

/** A transaction seen mined, kept until its block is finalized so a reorg that removes it returns it to pending. */
export interface Mined extends Pending {
  readonly minedBlock: bigint;
}

export class Submitter {
  readonly pending = new Map<string, Pending>();
  /** Keyed `subject@nonce`; pruned once the block it was seen mined in is finalized. */
  readonly mined = new Map<string, Mined>();
  readonly nonces: NonceManager;

  constructor(
    private readonly cfg: ChainConfig,
    private readonly client: PublicClient,
    private readonly signer: TxSigner,
    private readonly inventory: InventoryBook,
    private readonly post: (url: string, body: unknown) => Promise<unknown>,
    /** The instance's funding Safe, whose inventory the helper pulls from. */
    private readonly fundingSafe: Address,
    private readonly gas: GasPolicy,
  ) {
    this.nonces = new NonceManager(() => client.getTransactionCount({ address: signer.address, blockTag: "pending" }));
  }

  private async sign(plan: Pick<TxPlan, "to" | "data">, nonce: number, gas: bigint, f: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }) {
    return this.signer.signTransaction({ chainId: this.cfg.chain.id, type: "eip1559", to: plan.to, data: plan.data, value: 0n, nonce, gas, ...f });
  }

  /** Throws AboveGasCeiling (after paging) when the transaction's worst-case cost passes the chain's ceiling. */
  private async checkCeiling(plan: Pick<TxPlan, "to" | "data" | "subject">, nonce: number, gas: bigint, f: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }) {
    const l1 = this.gas.l1Fee ? await this.gas.l1Fee({ chainId: this.cfg.chain.id, to: plan.to, data: plan.data, nonce, gas, ...f }) : 0n;
    const cost = worstCaseCost(gas, f.maxFeePerGas, l1);
    if (!aboveCeiling(cost, this.gas.ceilingWei)) return;
    this.gas.onCeiling({ subject: plan.subject, cost: cost.toString(10), ceiling: this.gas.ceilingWei.toString(10), l1DataFee: l1.toString(10), nonce: String(nonce) });
    throw new AboveGasCeiling(cost, this.gas.ceilingWei);
  }

  /** First send of a plan; a subject whose earlier transaction expired while still due reuses that nonce. */
  async submit(ctx: BlockContext, plan: TxPlan, sim: Simulation): Promise<Hex> {
    const balances = new Map<string, bigint>();
    for (const r of plan.reservations) {
      const balance = await this.client.readContract({ address: r.asset, abi: erc20Abi, functionName: "balanceOf", args: [this.fundingSafe], blockNumber: ctx.blockNumber });
      balances.set(r.asset.toLowerCase(), balance);
    }
    const balanceOf = (asset: Address) => balances.get(asset.toLowerCase()) ?? 0n;
    if (!this.inventory.reserve(this.cfg.chain.id, plan.subject, plan.reservations, balanceOf)) throw new Error("insufficientInventory");
    const reused = this.reusable.get(plan.subject);
    this.reusable.delete(plan.subject);
    try {
      const f = await fees(this.client);
      const gas = gasLimit(sim.gasEstimate);
      return await this.nonces.withNonce(async (nonce) => {
        await this.checkCeiling(plan, nonce, gas, f);
        const raw = await this.sign(plan, nonce, gas, f);
        await sendPrivate(this.cfg.rpc.privateSend, raw, this.post);
        const hash = keccakOf(raw);
        this.pending.set(plan.subject, { plan, nonce, hash, sentBlock: ctx.blockNumber, fees: f, replacements: 0 });
        return hash;
      }, reused?.nonce);
    } catch (err) {
      // Nothing was sent: the reservation goes back, and a handed-back nonce stays available to the subject.
      this.inventory.release(this.cfg.chain.id, plan.subject);
      if (reused) this.reusable.set(plan.subject, reused);
      if (err instanceof AboveGasCeiling) {
        logAttempt({ at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: ctx.blockNumber.toString(10), job: plan.job, subject: plan.subject, outcome: "aboveGasCeiling", reason: err.message, params: stringifyParams(plan.params) });
      }
      throw err;
    }
  }

  /**
   * After a reorg: every transaction seen mined whose nonce the new head no longer counts as consumed was removed with
   * its block. It returns to pending with its reservation, and `restore` sets the account's in-flight flag again; the
   * follow-up in this block then replaces it, rebuilds it past its deadline, or cancels it (services/README.md, Operations > Reorgs).
   */
  async onReorg(head: bigint, restore: (plan: TxPlan, hash: Hex) => void): Promise<number> {
    if (this.mined.size === 0) return 0;
    const confirmed = await this.client.getTransactionCount({ address: this.signer.address, blockNumber: head });
    let returned = 0;
    for (const [key, m] of this.mined) {
      if (m.nonce < confirmed) continue;
      this.mined.delete(key);
      const { minedBlock: _, ...p } = m;
      // A newer transaction of the same subject may be pending; the returned one then keeps its own key.
      const subject = this.pending.has(p.plan.subject) ? key : p.plan.subject;
      this.pending.set(subject, p);
      this.inventory.restore(this.cfg.chain.id, subject, p.plan.reservations);
      restore(p.plan, p.hash);
      logAttempt({ at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: head.toString(10), job: p.plan.job, subject, outcome: "reorged", txHash: p.hash, nonce: p.nonce, params: stringifyParams(p.plan.params) });
      returned++;
    }
    return returned;
  }

  /** Runs the follow-up rule for every pending transaction in a new block. `stillDue` re-checks the subject live. */
  async followUps(ctx: BlockContext, stillDue: (plan: TxPlan) => Promise<boolean>, onDone: (plan: TxPlan) => void): Promise<void> {
    if (this.mined.size > 0) {
      const finalized = (await this.client.getBlock({ blockTag: "finalized" })).number;
      for (const [key, m] of this.mined) if (m.minedBlock <= finalized) this.mined.delete(key);
    }
    const confirmed = await this.client.getTransactionCount({ address: this.signer.address, blockNumber: ctx.blockNumber });
    // A nonce handed back for a rebuild that no pass used within 2 blocks is closed with a self-transfer, so no
    // gap can stall later transactions.
    for (const [subject, r] of this.reusable) {
      if (ctx.blockNumber < r.since + 2n) continue;
      this.reusable.delete(subject);
      if (confirmed > r.nonce) continue;
      const raw = await this.nonces.withNonce((n) => this.sign({ to: this.signer.address, data: "0x" }, n, 21_000n, bumpFees(r.fees)), r.nonce);
      await sendPrivate(this.cfg.rpc.privateSend, raw, this.post);
    }
    for (const [subject, p] of this.pending) {
      const sim = await simulate(this.client, this.signer.address, p.plan);
      const next = followUp(p, { blockNumber: ctx.blockNumber, timestamp: ctx.blockTimestamp }, confirmed > p.nonce, sim.ok, await stillDue(p.plan));
      const log = (outcome: "included" | "replaced" | "cancelled" | "expired") =>
        logAttempt({ at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: ctx.blockNumber.toString(10), job: p.plan.job, subject, outcome, txHash: p.hash, nonce: p.nonce, params: stringifyParams(p.plan.params) });
      if (next.action === "wait") continue;
      if (next.action === "done") {
        this.pending.delete(subject);
        this.mined.set(`${p.plan.subject}@${p.nonce}`, { ...p, minedBlock: ctx.blockNumber });
        this.inventory.release(this.cfg.chain.id, subject);
        onDone(p.plan);
        log("included");
      } else if (next.action === "replace") {
        const f = bumpFees(p.fees);
        const gas = gasLimit(sim.gasEstimate);
        // A replacement above the ceiling is not sent: the transaction keeps waiting at its fees until its deadline.
        try {
          await this.checkCeiling({ ...p.plan, subject }, p.nonce, gas, f);
        } catch (err) {
          if (!(err instanceof AboveGasCeiling)) throw err;
          logAttempt({ at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: ctx.blockNumber.toString(10), job: p.plan.job, subject, outcome: "aboveGasCeiling", reason: err.message, txHash: p.hash, nonce: p.nonce, params: stringifyParams(p.plan.params) });
          continue;
        }
        const raw = await this.nonces.withNonce((n) => this.sign(p.plan, n, gas, f), p.nonce);
        await sendPrivate(this.cfg.rpc.privateSend, raw, this.post);
        this.pending.set(subject, { ...p, hash: keccakOf(raw), fees: f, replacements: p.replacements + 1 });
        log("replaced");
      } else {
        // rebuild or cancel: the expired transaction can no longer execute. A rebuild hands the nonce back to the
        // job (the next pass sends a fresh preview at it); a cancel sends a zero-value transfer to the signer itself.
        this.pending.delete(subject);
        this.inventory.release(this.cfg.chain.id, subject);
        if (next.action === "cancel") {
          const f = bumpFees(p.fees);
          const raw = await this.nonces.withNonce((n) => this.sign({ to: this.signer.address, data: "0x" }, n, 21_000n, f), p.nonce);
          await sendPrivate(this.cfg.rpc.privateSend, raw, this.post);
          log("cancelled");
        } else {
          this.reusable.set(subject, { nonce: p.nonce, since: ctx.blockNumber, fees: p.fees });
          log("expired");
        }
        onDone(p.plan);
      }
    }
  }

  /** Nonces of expired transactions whose subject is still due; the next submit for that subject reuses it. */
  readonly reusable = new Map<string, { nonce: number; since: bigint; fees: Pending["fees"] }>();
}

/** The transaction hash: keccak256 of the signed envelope. */
const keccakOf = (raw: Hex): Hex => keccak256(raw);
