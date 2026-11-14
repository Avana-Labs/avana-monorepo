// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The inventory-only path and the second-provider confirmation: a call is funded with no loan when flash funding is
// stopped, a market route draws on the borrowed reserve, or the loan would round to zero; a liquidation the second
// provider does not read below HF 1 at the decision block is not sent (services/README.md, Building the call;
// Submission > Simulation).

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CHAINS } from "@avana/services-common";
import type { ChainReader } from "../src/chain/reads.ts";
import type { ChainConfig } from "../src/config.ts";
import { fundingPlan, routeDrawsOnReserve } from "../src/jobs/liquidationRules.ts";
import { type PipelineDeps, runJob } from "../src/pipeline.ts";
import type { BlockContext, Job, TxPlan } from "../src/types.ts";

describe("fundingPlan", () => {
  it("flash-funds as splitFunding does while flash funding is usable", () => {
    expect(fundingPlan(1_000n, 1_010n, true)).toEqual({ flashAmount: 1_000n, inventoryAmount: 0n, inventoryOnly: false });
    expect(fundingPlan(1_000n, 500n, true)).toEqual({ flashAmount: 495n, inventoryAmount: 505n, inventoryOnly: false });
  });

  it("funds the whole repayment from inventory when the loan would round to zero", () => {
    expect(fundingPlan(1_000n, 1n, true)).toEqual({ flashAmount: 0n, inventoryAmount: 1_000n, inventoryOnly: true });
    expect(fundingPlan(819_000n, 0n, true)).toEqual({ flashAmount: 0n, inventoryAmount: 819_000n, inventoryOnly: true });
  });

  it("funds from inventory whatever the idle liquidity when flash funding is stopped", () => {
    expect(fundingPlan(1_000n, 10n ** 30n, false)).toEqual({ flashAmount: 0n, inventoryAmount: 1_000n, inventoryOnly: true });
  });
});

describe("second-provider confirmation", () => {
  let lines: Record<string, unknown>[];
  beforeEach(() => {
    lines = [];
    vi.spyOn(process.stdout, "write").mockImplementation((s: string | Uint8Array) => {
      lines.push(JSON.parse(String(s)));
      return true;
    });
  });
  afterEach(() => vi.restoreAllMocks());

  const plan: TxPlan = { job: "liquidation", subject: "1:0xs:0xp", to: "0x0000000000000000000000000000000000000001", data: "0x", deadline: 10n, reservations: [], targets: [], params: {} };
  const job: Job<string, string> = { kind: "liquidation", discover: async () => ["a"], check: async (_c, x) => ({ act: true, decision: x }), build: async () => plan };
  const ctx = { config: { chain: CHAINS.mainnet } as ChainConfig, blockNumber: 5n, blockTimestamp: 0n, reader: {} as ChainReader } satisfies BlockContext;
  const deps = (confirmed: boolean) =>
    ({
      safety: { halted: false, codeMismatch: null, frozenHelperChains: new Set<number>() },
      mode: () => "active",
      simulate: vi.fn(async () => ({ ok: true, gasEstimate: 1n })),
      submit: vi.fn(async () => "0x01" as const),
      page: vi.fn(),
      confirm: vi.fn(async () => (confirmed ? null : ("hfNotConfirmed" as const))),
    }) satisfies PipelineDeps;

  it("sends only after the second provider confirms", async () => {
    const yes = deps(true);
    await runJob(job, ctx, yes);
    expect(yes.confirm).toHaveBeenCalledWith(ctx, plan);
    expect(yes.submit).toHaveBeenCalledOnce();
  });

  it("logs the call skipped and sends nothing when it does not", async () => {
    const no = deps(false);
    await runJob(job, ctx, no);
    expect(no.submit).not.toHaveBeenCalled();
    expect(lines).toEqual([expect.objectContaining({ outcome: "skipped", reason: "hfNotConfirmed", subject: plan.subject })]);
  });
});

describe("routeDrawsOnReserve", () => {
  const A_USDC = "0x00000000000000000000000000000000000000a1";
  const A_GHO = "0x00000000000000000000000000000000000000a2";
  const POOL = "0x0000000000000000000000000000000000000c01";
  const WRAPPER = "0x0000000000000000000000000000000000000f01";

  it("flags a route that uses the borrowed reserve's aToken or a wrapper of it", () => {
    expect(routeDrawsOnReserve([{ address: WRAPPER, wraps: [A_USDC] }], A_USDC)).toBe(true);
    expect(routeDrawsOnReserve([{ address: A_USDC.toUpperCase().replace("0X", "0x") as `0x${string}`, wraps: [] }], A_USDC)).toBe(true);
  });

  it("leaves a route on another reserve or on plain pools alone", () => {
    // A GSM route into GHO through the static aToken of USDC draws on the USDC reserve, not on a GHO loan's.
    expect(routeDrawsOnReserve([{ address: WRAPPER, wraps: [A_USDC] }, { address: POOL, wraps: [] }], A_GHO)).toBe(false);
    expect(routeDrawsOnReserve([{ address: POOL, wraps: [] }], A_USDC)).toBe(false);
    expect(routeDrawsOnReserve([{ address: WRAPPER, wraps: [A_USDC] }], null)).toBe(false);
  });
});
