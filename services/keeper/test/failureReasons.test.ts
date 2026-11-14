// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The failure-reason table (services/README.md, Submission > Failure reasons): each revert reason maps to its action,
// a retry is widened only for the reasons a larger bound cures and never past MAX_TOP_UP_BPS of the debt repaid, and a
// revert inside a build reaches the job's handler through the pipeline.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { encodeErrorResult } from "viem";
import { flashLiquidatorAbi, lpVaultSwapAbi } from "@avana/protocol/abis";
import { CHAINS } from "@avana/services-common";
import type { ChainConfig } from "../src/config.ts";
import type { ChainReader } from "../src/chain/reads.ts";
import { RevertError, decodeRevert, failureAction, hintFor, revertData, topUpCap, widen } from "../src/jobs/failureReasons.ts";
import { type PipelineDeps, runJob } from "../src/pipeline.ts";
import type { BlockContext, Job } from "../src/types.ts";

describe("failure-reason table", () => {
  it("maps each reason of the README to its action", () => {
    expect(failureAction("NotLiquidatable").kind).toBe("clearAccount");
    expect(failureAction("StalePrice").kind).toBe("waitForPrice");
    expect(failureAction("DebtPriceStale").kind).toBe("waitForPrice");
    for (const r of ["PayoutTooLow", "MinOutNotMet", "LockHeld"]) expect(failureAction(r).kind).toBe("retryNextBlock");
    expect(failureAction("RecoveryBelowFloor")).toEqual({ kind: "retryWithShortfall", signal: "M-10", level: "warn" });
    expect(failureAction("TopUpExceeded").kind).toBe("retryWithTopUp");
    expect(failureAction("InsufficientProceeds")).toEqual({ kind: "fault", signal: "M-10", level: "page" });
    expect(failureAction("NoRouteAvailable")).toEqual({ kind: "retryAndPage", signal: "M-10", level: "page" });
    expect(failureAction("AddressIsFrozen")).toEqual({ kind: "stopHelper", signal: "M-24", level: "page" });
    expect(failureAction("SomethingElse").kind).toBe("unknown");
  });

  it("leaves a hint only for the reasons a larger bound cures", () => {
    expect(hintFor({ selector: "0x00000000", name: "RecoveryBelowFloor" })).toEqual({ shortfall: true });
    expect(hintFor({ selector: "0x00000000", name: "TopUpExceeded", args: ["750", "500"] })).toEqual({ topUp: 750n });
    expect(hintFor({ selector: "0x00000000", name: "PayoutTooLow", args: ["1", "2"] })).toBeNull();
    expect(hintFor({ selector: "0x00000000", name: "NoRouteAvailable" })).toBeNull();
  });
});

describe("widening a retry", () => {
  // 1,950 USDC repaid (6 decimals) at MAX_TOP_UP_BPS = 100: the Safe may put in at most 19.5 USDC beyond the inventory amount.
  const cap = topUpCap(1_950_000_000n, 100n);

  it("caps every allowance at MAX_TOP_UP_BPS of the debt repaid", () => {
    expect(cap).toBe(19_500_000n);
  });

  it("raises maxShortfall and the top-up bound to the cap after RecoveryBelowFloor, once", () => {
    const first = widen({ maxShortfall: 0n, maxTopUp: 1_000_000n }, { shortfall: true }, cap);
    expect(first).toEqual({ maxShortfall: cap, maxTopUp: cap });
    expect(widen(first!, { shortfall: true }, cap)).toBeNull();
    expect(widen({ maxShortfall: 0n, maxTopUp: 0n }, { shortfall: true }, 0n)).toBeNull();
  });

  it("raises the top-up bound to the measured top-up after TopUpExceeded, within the cap", () => {
    expect(widen({ maxShortfall: 0n, maxTopUp: 5_000_000n }, { topUp: 7_500_000n }, cap)).toEqual({ maxShortfall: 0n, maxTopUp: 7_500_000n });
    expect(widen({ maxShortfall: 0n, maxTopUp: 5_000_000n }, { topUp: cap + 1n }, cap)).toBeNull();
    expect(widen({ maxShortfall: 0n, maxTopUp: 8_000_000n }, { topUp: 7_500_000n }, cap)).toBeNull();
  });
});

describe("revert decoding", () => {
  it("decodes LPVaultSwap and helper errors with their arguments", () => {
    const floor = encodeErrorResult({ abi: lpVaultSwapAbi, errorName: "RecoveryBelowFloor" });
    expect(decodeRevert(floor)).toMatchObject({ name: "RecoveryBelowFloor", args: [] });
    const topUp = encodeErrorResult({ abi: flashLiquidatorAbi, errorName: "TopUpExceeded", args: [750n, 500n] });
    expect(decodeRevert(topUp)).toMatchObject({ name: "TopUpExceeded", args: ["750", "500"] });
  });

  it("keeps only the selector of an error outside the ABIs", () => {
    expect(decodeRevert("0xdeadbeef")).toEqual({ selector: "0xdeadbeef", name: "unknown" });
    expect(decodeRevert("0x")).toBeUndefined();
  });

  it("finds the revert data nested in viem's error causes", () => {
    const data = encodeErrorResult({ abi: lpVaultSwapAbi, errorName: "NoRouteAvailable" });
    expect(revertData({ message: "call failed", cause: { cause: { data } } })).toBe(data);
    expect(revertData({ cause: { data: { data } } })).toBe(data);
    expect(revertData(new Error("timeout"))).toBeUndefined();
  });
});

describe("a revert inside a build", () => {
  let lines: Record<string, unknown>[];
  beforeEach(() => {
    lines = [];
    vi.spyOn(process.stdout, "write").mockImplementation((s: string | Uint8Array) => {
      lines.push(JSON.parse(String(s)));
      return true;
    });
  });
  afterEach(() => vi.restoreAllMocks());

  it("is logged as a failed simulation and handed to the job's failure handler", async () => {
    const revert = { selector: "0x12345678" as const, name: "TopUpExceeded", args: ["750", "500"] };
    const onFailure = vi.fn();
    const job: Job<string, string> = {
      kind: "liquidation",
      discover: async () => ["acct"],
      check: async (_c, x) => ({ act: true, decision: x }),
      build: async () => {
        throw new RevertError(revert, "1:0xspoke:0xproxy");
      },
      onFailure,
    };
    const ctx = { config: { chain: CHAINS.mainnet } as ChainConfig, blockNumber: 7n, blockTimestamp: 0n, reader: {} as ChainReader } satisfies BlockContext;
    const deps: PipelineDeps = {
      safety: { halted: false, codeMismatch: null, frozenHelperChains: new Set() },
      mode: () => "active",
      simulate: vi.fn(),
      submit: vi.fn(),
      page: vi.fn(),
    };
    await runJob(job, ctx, deps);
    expect(onFailure).toHaveBeenCalledWith(ctx, "1:0xspoke:0xproxy", revert);
    expect(deps.submit).not.toHaveBeenCalled();
    expect(lines).toEqual([expect.objectContaining({ type: "keeper.attempt", outcome: "simulationFailed", subject: "1:0xspoke:0xproxy", revert })]);
  });
});
