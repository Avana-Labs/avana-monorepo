// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Simulation, signing, private sending and per-block follow-up for one chain. Every send (first, replacement,
// rebuild, cancellation) is simulated first, signed through the KMS under the nonce lock and sent only through the
// chain's private endpoints.

import { type Address, type Hex, type PublicClient, decodeErrorResult, erc20Abi, keccak256, slice } from "viem";
import { flashLiquidatorAbi, lpVaultSwapAbi } from "@avana/protocol/abis";
import type { ChainConfig } from "../config.ts";
import { bumpFees, gasLimit, maxFee, priorityFee } from "../chain/gas.ts";
import { NonceManager } from "../chain/nonce.ts";
import type { TxSigner } from "../chain/signer.ts";
import { type Pending, followUp, sendPrivate } from "../chain/submit.ts";
import { logAttempt, stringifyParams } from "../failureLog.ts";
import type { InventoryBook } from "../inventory.ts";
import type { Simulation } from "../pipeline.ts";
import type { BlockContext, TxPlan } from "../types.ts";

const errorAbi = [...lpVaultSwapAbi, ...flashLiquidatorAbi];

export async function simulate(client: PublicClient, from: Address, plan: Pick<TxPlan, "to" | "data">): Promise<Simulation> {
  try {
    await client.call({ account: from, to: plan.to, data: plan.data, blockTag: "latest" });
    const gasEstimate = await client.estimateGas({ account: from, to: plan.to, data: plan.data, blockTag: "latest" });
    return { ok: true, gasEstimate };
  } catch (err) {
    const data = (err as { data?: Hex; cause?: { data?: Hex } }).data ?? (err as { cause?: { data?: Hex } }).cause?.data;
    if (!data || data.length < 10) return { ok: false, gasEstimate: 0n };
    let name = "unknown";
    try {
      name = decodeErrorResult({ abi: errorAbi, data }).errorName;
    } catch {
      // An error from a contract outside these ABIs keeps its selector only.
    }
    return { ok: false, gasEstimate: 0n, revert: { selector: slice(data, 0, 4), name } };
  }
}

async function fees(client: PublicClient) {
  const history = await client.getFeeHistory({ blockCount: 5, rewardPercentiles: [90], blockTag: "latest" });
  const tip = priorityFee((history.reward ?? []).map((r) => r[0] ?? 0n));
  const base = history.baseFeePerGas[history.baseFeePerGas.length - 1] ?? 0n;
  return { maxPriorityFeePerGas: tip, maxFeePerGas: maxFee(base, tip) };
}

export class Submitter {
  readonly pending = new Map<string, Pending>();
  readonly nonces: NonceManager;

  constructor(
    private readonly cfg: ChainConfig,
    private readonly client: PublicClient,
    private readonly signer: TxSigner,
    private readonly inventory: InventoryBook,
    private readonly post: (url: string, body: unknown) => Promise<unknown>,
    /** The instance's funding Safe, whose inventory the helper pulls from. */
    private readonly fundingSafe: Address,
  ) {
    this.nonces = new NonceManager(() => client.getTransactionCount({ address: signer.address, blockTag: "pending" }));
  }

  private async sign(plan: Pick<TxPlan, "to" | "data">, nonce: number, gas: bigint, f: { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }) {
    return this.signer.signTransaction({ chainId: this.cfg.chain.id, type: "eip1559", to: plan.to, data: plan.data, value: 0n, nonce, gas, ...f });
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
    const reuse = this.reusable.get(plan.subject)?.nonce;
    this.reusable.delete(plan.subject);
    const f = await fees(this.client);
    return this.nonces.withNonce(async (nonce) => {
      const raw = await this.sign(plan, nonce, gasLimit(sim.gasEstimate), f);
      await sendPrivate(this.cfg.rpc.privateSend, raw, this.post);
      const hash = keccakOf(raw);
      this.pending.set(plan.subject, { plan, nonce, hash, sentBlock: ctx.blockNumber, fees: f, replacements: 0 });
      return hash;
    }, reuse);
  }

  /** Runs the follow-up rule for every pending transaction in a new block. `stillDue` re-checks the subject live. */
  async followUps(ctx: BlockContext, stillDue: (plan: TxPlan) => Promise<boolean>, onDone: (plan: TxPlan) => void): Promise<void> {
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
        this.inventory.release(this.cfg.chain.id, subject);
        onDone(p.plan);
        log("included");
      } else if (next.action === "replace") {
        const f = bumpFees(p.fees);
        const raw = await this.nonces.withNonce((n) => this.sign(p.plan, n, gasLimit(sim.gasEstimate), f), p.nonce);
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
