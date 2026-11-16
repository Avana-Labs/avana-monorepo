// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Simulation, signing, private sending and per-block follow-up for one chain. Every send (first, replacement,
// rebuild, cancellation) is simulated first, signed through the KMS under the nonce lock and sent only through the
// chain's private endpoints.

import { type Address, type Hex, type PublicClient, erc20Abi, keccak256 } from "viem";
import type { ChainConfig } from "../config.ts";
import { type FeePolicy, type UnsignedTx, URGENT_ONLY, aboveCeiling, bumpFees, classFees, gasLimit, worstCaseCost } from "../chain/gas.ts";
import { NonceManager } from "../chain/nonce.ts";
import type { TxSigner } from "../chain/signer.ts";
import { type Pending, followUp, sendPrivate } from "../chain/submit.ts";
import { logAttempt, stringifyParams } from "../failureLog.ts";
import { decodeRevert, revertData } from "../jobs/failureReasons.ts";
import type { InventoryBook } from "../inventory.ts";
import type { Simulation } from "../pipeline.ts";
import type { BlockContext, JobClass, JobKind, SkipReason, TxPlan } from "../types.ts";

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

/** The last 5 blocks' 90th-percentile priority fees and the next block's base fee. */
async function feeHistory(client: PublicClient) {
  const history = await client.getFeeHistory({ blockCount: 5, rewardPercentiles: [90], blockTag: "latest" });
  return { rewards: (history.reward ?? []).map((r) => r[0] ?? 0n), base: history.baseFeePerGas[history.baseFeePerGas.length - 1] ?? 0n };
}

/** An included transaction's cost, from its receipt, and the market and Hub its subject is attributed to. */
export interface IncludedSpend {
  readonly plan: TxPlan;
  readonly txHash: Hex;
  readonly blockNumber: bigint;
  /** Unix seconds of the head the transaction was seen included at. */
  readonly at: bigint;
  readonly gasUsed: bigint;
  readonly effectiveGasPrice: bigint;
  /** The L1 data fee the receipt reports (Base); 0 elsewhere. */
  readonly l1Fee: bigint;
  /** gasUsed × effectiveGasPrice + l1Fee. */
  readonly costWei: bigint;
  readonly market: string | null;
  readonly hub: Address | null;
  readonly logs: readonly { readonly address: Address; readonly topics: readonly Hex[]; readonly data: Hex }[];
}

/** Where included spend goes: the spend log and budgets (runtime/budget.ts) and the small-account metric. */
export interface SpendSink {
  /** The market and Hub of a plan's subject (market → CDP Spoke → Hub). */
  attribute(plan: TxPlan): Promise<{ readonly market: string | null; readonly hub: Address | null }>;
  record(spend: IncludedSpend): void;
}

/** The L1 data fee of an OP Stack receipt (`l1Fee`, hex or bigint); 0 when the receipt has none. */
export function l1FeeOf(receipt: unknown): bigint {
  const raw = (receipt as { l1Fee?: unknown }).l1Fee;
  if (typeof raw === "bigint") return raw;
  if (typeof raw === "string" && /^(0x[0-9a-fA-F]+|[0-9]+)$/.test(raw)) return BigInt(raw);
  return 0n;
}

/** A transaction the fee rule holds back: a lazy one waiting for a low base fee, or a class at its daily budget. */
export class NotSent extends Error {
  constructor(readonly reason: Extract<SkipReason, "lazyBaseFeeHigh" | "budgetReached">, readonly detail: string) {
    super(reason);
  }
}

/** The per-chain fee ceiling (services/README.md, Submission > Gas): it only stops a fault from draining the gas wallet. */
export interface GasPolicy {
  /** Worst-case wei of one transaction: gas limit × max fee, plus the L1 data fee on Base. */
  readonly ceilingWei: bigint;
  /** The L1 data fee of an unsigned transaction on Base; null on chains without one. */
  readonly l1Fee: ((tx: UnsignedTx) => Promise<bigint>) | null;
  /** Pages the on-call engineer (M-17) when a send or a replacement would pass the ceiling. */
  onCeiling(detail: Readonly<Record<string, string>>): void;
  /** Tips and the lazy base-fee gate per class; without one, every class pays urgent fees (today's rule). */
  readonly fees?: FeePolicy;
  /** The rolling 24 h class budgets (runtime/budget.ts `SpendBook`); without one, no class is limited. */
  readonly budget?: { allows(jobClass: JobClass, now: bigint): boolean };
  /** Receives each included transaction's spend. */
  readonly spend?: SpendSink;
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

  /** Lazy subjects waiting for a low base fee: when each first fell due, and when it was last seen due. */
  readonly #lazySince = new Map<string, { since: bigint; last: bigint }>();
  /** Every transaction signed at a nonce, with its plan, so the one that was mined is found from its receipt. */
  readonly #signed = new Map<number, { hash: Hex; plan: TxPlan }[]>();

  #sign(nonce: number, hash: Hex, plan: TxPlan): void {
    this.#signed.set(nonce, [...(this.#signed.get(nonce) ?? []), { hash, plan }]);
  }

  /** Seconds a lazy subject has waited since it first fell due; a subject not seen due for `lazyMaxWait` starts again. */
  #lazyWaited(plan: TxPlan, now: bigint, policy: FeePolicy): bigint {
    if (plan.jobClass !== "lazy") return 0n;
    const w = this.#lazySince.get(plan.subject);
    if (!w || now - w.last > policy.lazyMaxWaitSeconds) {
      this.#lazySince.set(plan.subject, { since: now, last: now });
      return 0n;
    }
    w.last = now;
    return now - w.since;
  }

  /**
   * The fees of a first send by the plan's class (chain/gas.ts `classFees`); throws NotSent when the class is at its
   * daily budget (urgent never is) or a lazy plan must keep waiting for a low base fee.
   */
  async #classFees(ctx: BlockContext, plan: TxPlan): Promise<Pending["fees"]> {
    if (this.gas.budget && !this.gas.budget.allows(plan.jobClass, ctx.blockTimestamp)) {
      throw new NotSent("budgetReached", `${plan.jobClass} spent its daily budget in the last 24 h`);
    }
    const policy = this.gas.fees ?? URGENT_ONLY;
    const { rewards, base } = await feeHistory(this.client);
    const d = classFees(plan.jobClass, rewards, base, policy, this.#lazyWaited(plan, ctx.blockTimestamp, policy));
    if (!d.send) throw new NotSent("lazyBaseFeeHigh", `base fee ${d.baseFee} wei above ${policy.lazyBaseFeeMax}; waited ${d.waitedSeconds} of ${policy.lazyMaxWaitSeconds} s`);
    return { maxFeePerGas: d.maxFeePerGas, maxPriorityFeePerGas: d.maxPriorityFeePerGas };
  }

  /**
   * The spend of the transaction mined at `nonce`: the receipt of each transaction signed there (newest first) until
   * one is found, attributed and handed to the spend sink. Null when no receipt is found.
   */
  async #included(ctx: BlockContext, nonce: number): Promise<IncludedSpend | null> {
    const signed = this.#signed.get(nonce) ?? [];
    this.#signed.delete(nonce);
    for (const s of [...signed].reverse()) {
      let receipt;
      try {
        receipt = await this.client.getTransactionReceipt({ hash: s.hash });
      } catch {
        continue;
      }
      const l1Fee = l1FeeOf(receipt);
      const unknown = { market: null, hub: null };
      const who = this.gas.spend ? await this.gas.spend.attribute(s.plan).catch(() => unknown) : unknown;
      const spend: IncludedSpend = {
        plan: s.plan,
        txHash: s.hash,
        blockNumber: receipt.blockNumber,
        at: ctx.blockTimestamp,
        gasUsed: receipt.gasUsed,
        effectiveGasPrice: receipt.effectiveGasPrice,
        l1Fee,
        costWei: receipt.gasUsed * receipt.effectiveGasPrice + l1Fee,
        market: who.market,
        hub: who.hub,
        logs: receipt.logs.map((l) => ({ address: l.address, topics: l.topics as readonly Hex[], data: l.data })),
      };
      this.gas.spend?.record(spend);
      return spend;
    }
    return null;
  }

  /** First send of a plan; a subject whose earlier transaction expired while still due reuses that nonce. */
  async submit(ctx: BlockContext, plan: TxPlan, sim: Simulation): Promise<Hex> {
    const f = await this.#classFees(ctx, plan);
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
      const gas = gasLimit(sim.gasEstimate);
      if (plan.job === "liquidation" && !reused) {
        const hash = await this.preempt(ctx, plan, gas, f);
        if (hash) return hash;
      }
      return await this.nonces.withNonce(async (nonce) => {
        await this.checkCeiling(plan, nonce, gas, f);
        const raw = await this.sign(plan, nonce, gas, f);
        await sendPrivate(this.cfg.rpc.privateSend, raw, this.post);
        const hash = keccakOf(raw);
        this.pending.set(plan.subject, { plan, nonce, hash, sentBlock: ctx.blockNumber, fees: f, replacements: 0 });
        this.#sign(nonce, hash, plan);
        this.#lazySince.delete(plan.subject);
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
   * Pre-emption (services/README.md, Submission > Pre-emption): every transaction of the instance shares one signer,
   * so a due liquidation sent at a fresh nonce waits behind every pending poke. It is sent instead at the lowest nonce
   * a pending non-liquidation transaction holds, not yet mined, as a replacement of that transaction: fees at least the
   * replacement bump over it, and the gas ceiling as for any send. The dropped transaction is handed back through
   * `preempted`, so its job sends it again in a later pass. A pending liquidation is never pre-empted. Returns null
   * when there is nothing to pre-empt, or when the node refuses the replacement; the liquidation then takes a fresh
   * nonce.
   */
  private async preempt(ctx: BlockContext, plan: TxPlan, gas: bigint, fresh: Pending["fees"]): Promise<Hex | null> {
    const mined = await this.client.getTransactionCount({ address: this.signer.address, blockTag: "latest" });
    let victim: [string, Pending] | null = null;
    for (const entry of this.pending) {
      const p = entry[1];
      if (p.plan.job === "liquidation" || p.nonce < mined) continue;
      if (victim === null || p.nonce < victim[1].nonce) victim = entry;
    }
    if (victim === null) return null;
    const [key, p] = victim;
    const bumped = bumpFees(p.fees);
    const f = {
      maxFeePerGas: bumped.maxFeePerGas > fresh.maxFeePerGas ? bumped.maxFeePerGas : fresh.maxFeePerGas,
      maxPriorityFeePerGas: bumped.maxPriorityFeePerGas > fresh.maxPriorityFeePerGas ? bumped.maxPriorityFeePerGas : fresh.maxPriorityFeePerGas,
    };
    await this.checkCeiling(plan, p.nonce, gas, f);
    const raw = await this.nonces.withNonce((n) => this.sign(plan, n, gas, f), p.nonce);
    try {
      await sendPrivate(this.cfg.rpc.privateSend, raw, this.post);
    } catch (err) {
      logAttempt({ at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: ctx.blockNumber.toString(10), job: plan.job, subject: plan.subject, outcome: "sendRefused", reason: `preemption: ${String(err)}`, nonce: p.nonce, params: stringifyParams(plan.params) });
      return null;
    }
    const hash = keccakOf(raw);
    this.pending.delete(key);
    this.inventory.release(this.cfg.chain.id, key);
    this.pending.set(plan.subject, { plan, nonce: p.nonce, hash, sentBlock: ctx.blockNumber, fees: f, replacements: 0 });
    this.#sign(p.nonce, hash, plan);
    logAttempt({ at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: ctx.blockNumber.toString(10), job: p.plan.job, subject: key, outcome: "preempted", reason: `nonce taken by the liquidation of ${plan.subject}`, txHash: p.hash, nonce: p.nonce, params: stringifyParams(p.plan.params) });
    this.preempted(p.plan);
    return hash;
  }

  /** Called with a transaction a liquidation pre-empted, so its job can send it again (an oracle poke forgets its last poke). */
  preempted: (plan: TxPlan) => void = () => {};

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
    // A follow-up send every endpoint refuses (typically "nonce too low": the original was mined after the nonce was
    // read) is logged and left as it was; the next block reads the nonce again and decides. It never stops the keeper.
    const refused = async (send: () => Promise<unknown>, record: { job: JobKind; subject: string; nonce: number; txHash?: Hex; params: Record<string, string> }, what: string) => {
      try {
        await send();
        return false;
      } catch (err) {
        logAttempt({ at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: ctx.blockNumber.toString(10), ...record, outcome: "sendRefused", reason: `${what}: ${String(err)}` });
        return true;
      }
    };
    // A nonce handed back for a rebuild that no pass used within 2 blocks is closed with a self-transfer, so no
    // gap can stall later transactions.
    for (const [subject, r] of this.reusable) {
      if (ctx.blockNumber < r.since + 2n) continue;
      this.reusable.delete(subject);
      if (confirmed > r.nonce) continue;
      const raw = await this.nonces.withNonce((n) => this.sign({ to: this.signer.address, data: "0x" }, n, 21_000n, bumpFees(r.fees)), r.nonce);
      if (await refused(() => sendPrivate(this.cfg.rpc.privateSend, raw, this.post), { job: "liquidation", subject, nonce: r.nonce, params: {} }, "nonce close")) this.reusable.set(subject, r);
    }
    for (const [subject, p] of this.pending) {
      const sim = await simulate(this.client, this.signer.address, p.plan);
      const next = followUp(p, { blockNumber: ctx.blockNumber, timestamp: ctx.blockTimestamp }, confirmed > p.nonce, sim.ok, await stillDue(p.plan));
      const log = (outcome: "included" | "replaced" | "cancelled" | "expired", spend?: IncludedSpend | null) =>
        logAttempt({
          at: new Date().toISOString(), chainId: this.cfg.chain.id, blockNumber: ctx.blockNumber.toString(10), job: p.plan.job, jobClass: p.plan.jobClass, subject, outcome,
          txHash: spend?.txHash ?? p.hash, nonce: p.nonce, params: stringifyParams(p.plan.params),
          ...(spend
            ? { spend: { gasUsed: spend.gasUsed.toString(10), effectiveGasPrice: spend.effectiveGasPrice.toString(10), l1Fee: spend.l1Fee.toString(10), costWei: spend.costWei.toString(10), market: spend.market ?? "", hub: spend.hub ?? "" } }
            : {}),
        });
      const record = { job: p.plan.job, subject, nonce: p.nonce, txHash: p.hash, params: stringifyParams(p.plan.params) };
      if (next.action === "wait") continue;
      if (next.action === "done") {
        this.pending.delete(subject);
        this.mined.set(`${p.plan.subject}@${p.nonce}`, { ...p, minedBlock: ctx.blockNumber });
        this.inventory.release(this.cfg.chain.id, subject);
        onDone(p.plan);
        log("included", await this.#included(ctx, p.nonce));
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
        if (await refused(() => sendPrivate(this.cfg.rpc.privateSend, raw, this.post), record, "replacement")) continue;
        this.pending.set(subject, { ...p, hash: keccakOf(raw), fees: f, replacements: p.replacements + 1 });
        this.#sign(p.nonce, keccakOf(raw), p.plan);
        log("replaced");
      } else {
        // rebuild or cancel: the expired transaction can no longer execute. A rebuild hands the nonce back to the
        // job (the next pass sends a fresh preview at it); a cancel sends a zero-value transfer to the signer itself.
        if (next.action === "cancel") {
          const f = bumpFees(p.fees);
          const raw = await this.nonces.withNonce((n) => this.sign({ to: this.signer.address, data: "0x" }, n, 21_000n, f), p.nonce);
          // A refused cancellation stays pending with its reservation: the next block finds the nonce consumed or cancels again.
          if (await refused(() => sendPrivate(this.cfg.rpc.privateSend, raw, this.post), record, "cancellation")) continue;
          this.pending.delete(subject);
          this.inventory.release(this.cfg.chain.id, subject);
          this.#signed.delete(p.nonce);
          log("cancelled");
        } else {
          this.pending.delete(subject);
          this.inventory.release(this.cfg.chain.id, subject);
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
