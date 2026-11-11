// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The one pipeline every job runs in each block: discover → live check → build → code check → simulate →
// guards → private send. Observe-only and halted instances run every step except the send and log the call
// they would have made, so a fork replay can show each logged call would have succeeded (TEST-140).
// A failure on one candidate is logged and never stops the pass over the others.

import type { Hex } from "viem";
import { type AttemptRecord, logAttempt, stringifyParams } from "./failureLog.ts";
import { type EffectiveMode, type SafetyState, blockingReason, checkTargets } from "./safety/guards.ts";
import type { BlockContext, Job, TxPlan } from "./types.ts";

export interface Simulation {
  readonly ok: boolean;
  readonly gasEstimate: bigint;
  readonly revert?: { readonly selector: Hex; readonly name: string };
}

export interface PipelineDeps {
  readonly safety: SafetyState;
  mode(chainId: number): EffectiveMode;
  /** eth_call and estimateGas against `latest` on the primary provider, from the instance's signer. */
  simulate(ctx: BlockContext, plan: TxPlan): Promise<Simulation>;
  /** Signs through the KMS, allocates the nonce under the lock, sends privately, registers the pending transaction. */
  submit(ctx: BlockContext, plan: TxPlan, sim: Simulation): Promise<Hex>;
  /** Pages the on-call engineer (M-26 for a code mismatch). */
  page(signal: string, detail: Readonly<Record<string, string>>): void;
}

function record(ctx: BlockContext, plan: Pick<TxPlan, "job" | "subject" | "params">, rest: Omit<AttemptRecord, "at" | "chainId" | "blockNumber" | "job" | "subject" | "params">): AttemptRecord {
  return {
    at: new Date().toISOString(),
    chainId: ctx.config.chain.id,
    blockNumber: ctx.blockNumber.toString(10),
    job: plan.job,
    subject: plan.subject,
    params: stringifyParams(plan.params),
    ...rest,
  };
}

export async function runJob<C, D>(job: Job<C, D>, ctx: BlockContext, deps: PipelineDeps): Promise<void> {
  const candidates = await job.discover(ctx);
  for (const candidate of candidates) {
    const pass = () => runOne(job, ctx, deps, candidate);
    try {
      await (job.exclusive ? job.exclusive(candidate, pass) : pass());
    } catch (err) {
      logAttempt(record(ctx, { job: job.kind, subject: String(candidate), params: {} }, { outcome: "skipped", reason: err instanceof Error ? err.message : String(err) }));
    }
  }
}

async function runOne<C, D>(job: Job<C, D>, ctx: BlockContext, deps: PipelineDeps, candidate: C): Promise<void> {
  const check = await job.check(ctx, candidate);
  if (!check.act) {
    if (job.kind === "liquidation" && check.reason !== "healthy") {
      logAttempt(record(ctx, { job: job.kind, subject: String(candidate), params: {} }, { outcome: "skipped", reason: check.reason }));
    }
    return;
  }
  const plan = await job.build(ctx, check.decision);

  const mismatch = await checkTargets(ctx, plan.targets);
  if (mismatch) {
    deps.safety.codeMismatch = mismatch;
    deps.page("M-26", { chainId: String(ctx.config.chain.id), ...mismatch });
  }

  const sim = await deps.simulate(ctx, plan);
  if (!sim.ok) {
    logAttempt(record(ctx, plan, { outcome: "simulationFailed", ...(sim.revert ? { revert: sim.revert } : {}) }));
    return;
  }

  const blocked = blockingReason(deps.mode(ctx.config.chain.id), deps.safety, ctx.config.chain.id);
  if (blocked) {
    logAttempt(record(ctx, plan, { outcome: blocked === "observeOnly" ? "wouldSend" : "skipped", reason: blocked }));
    return;
  }

  const txHash = await deps.submit(ctx, plan, sim);
  logAttempt(record(ctx, plan, { outcome: "sent", txHash }));
}
