// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Simulate-then-send: a call is signed only after its simulation succeeds and every guard passes; a code mismatch
// pages M-26 and blocks the send; an observe-only instance logs the call it would have made.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Hex } from "viem";
import { type PipelineDeps, type Simulation, describeCandidate, runJob } from "../src/pipeline.ts";
import type { EffectiveMode, SafetyState } from "../src/safety/guards.ts";
import type { BlockContext, Job, TxPlan } from "../src/types.ts";
import type { ChainReader } from "../src/chain/reads.ts";
import type { ChainConfig } from "../src/config.ts";
import { CHAINS } from "@avana/services-common";

const IMPL = "0x1111111111111111111111111111111111111111";
const OTHER = "0x2222222222222222222222222222222222222222";
const TARGET = "0x3333333333333333333333333333333333333333";
const TX = `0x${"aa".repeat(32)}` as Hex;

function context(implementation: string): BlockContext {
  const reader = { implementationOf: async () => implementation, codeHashOf: async () => `0x${"00".repeat(32)}` };
  return {
    config: { chain: CHAINS.mainnet } as ChainConfig,
    blockNumber: 100n,
    blockTimestamp: 1_700_000_000n,
    reader: reader as unknown as ChainReader,
  };
}

const plan: TxPlan = {
  job: "oraclePoke",
  subject: TARGET,
  to: TARGET,
  data: "0x18178358",
  deadline: null,
  reservations: [],
  targets: [{ kind: "upgradeable", address: TARGET, implementation: IMPL }],
  params: { oracle: TARGET },
};

const job: Job<string, string> = {
  kind: "oraclePoke",
  discover: async () => [TARGET],
  check: async (_ctx, c) => ({ act: true, decision: c }),
  build: async () => plan,
};

function deps(mode: EffectiveMode, sim: Simulation, safety?: SafetyState) {
  const d = {
    safety: safety ?? { halted: false, codeMismatch: null, frozenHelperChains: new Set<number>() },
    mode: () => mode,
    simulate: vi.fn(async () => sim),
    submit: vi.fn(async () => TX),
    page: vi.fn(),
  } satisfies PipelineDeps;
  return d;
}

const ok: Simulation = { ok: true, gasEstimate: 50_000n };
let lines: Record<string, unknown>[];

beforeEach(() => {
  lines = [];
  vi.spyOn(process.stdout, "write").mockImplementation((chunk: string | Uint8Array) => {
    lines.push(JSON.parse(String(chunk)) as Record<string, unknown>);
    return true;
  });
});
afterEach(() => vi.restoreAllMocks());

describe("runJob", () => {
  it("sends once when the simulation succeeds and every guard passes", async () => {
    const d = deps("active", ok);
    await runJob(job, context(IMPL), d);
    expect(d.simulate).toHaveBeenCalledTimes(1);
    expect(d.submit).toHaveBeenCalledTimes(1);
    expect(lines.at(-1)).toMatchObject({ outcome: "sent", txHash: TX, chainId: 1, blockNumber: "100" });
  });

  it("never sends a call whose simulation reverts, and logs the revert", async () => {
    const revert = { selector: "0x12345678" as Hex, name: "StalePrice" };
    const d = deps("active", { ok: false, gasEstimate: 0n, revert });
    await runJob(job, context(IMPL), d);
    expect(d.submit).not.toHaveBeenCalled();
    expect(lines.at(-1)).toMatchObject({ outcome: "simulationFailed", revert });
  });

  it("logs what it would have sent in observe-only mode", async () => {
    const d = deps("observe", ok);
    await runJob(job, context(IMPL), d);
    expect(d.submit).not.toHaveBeenCalled();
    expect(lines.at(-1)).toMatchObject({ outcome: "wouldSend", reason: "observeOnly" });
  });

  it("pages M-26 and refuses to send when a target's implementation differs from the manifest", async () => {
    const d = deps("active", ok);
    await runJob(job, context(OTHER), d);
    expect(d.page).toHaveBeenCalledWith("M-26", expect.objectContaining({ chainId: "1", address: TARGET, expected: IMPL, found: OTHER }));
    expect(d.safety.codeMismatch).toEqual({ address: TARGET, expected: IMPL, found: OTHER });
    expect(d.submit).not.toHaveBeenCalled();
    expect(lines.at(-1)).toMatchObject({ outcome: "skipped", reason: "codeMismatch" });
  });

  it("refuses to send on a chain whose helper is frozen", async () => {
    const d = deps("active", ok, { halted: false, codeMismatch: null, frozenHelperChains: new Set([1]) });
    await runJob(job, context(IMPL), d);
    expect(d.submit).not.toHaveBeenCalled();
    expect(lines.at(-1)).toMatchObject({ outcome: "skipped", reason: "helperFrozen" });
  });

  it("logs a failing candidate and carries on with the next one", async () => {
    const d = deps("active", ok);
    const two: Job<string, string> = {
      ...job,
      discover: async () => ["bad", TARGET],
      check: async (_ctx, c) => {
        if (c === "bad") throw new Error("rpc timeout");
        return { act: true, decision: c };
      },
    };
    await runJob(two, context(IMPL), d);
    expect(lines[0]).toMatchObject({ subject: "bad", outcome: "skipped", reason: "rpc timeout" });
    expect(d.submit).toHaveBeenCalledTimes(1);
  });

  it("logs an object candidate as JSON, not [object Object]", () => {
    expect(describeCandidate({ kind: "market", marketId: 5n })).toBe('{"kind":"market","marketId":"5"}');
    expect(describeCandidate("0xabc")).toBe("0xabc");
  });
});
