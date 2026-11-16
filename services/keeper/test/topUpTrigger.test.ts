// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The gas vault top-up (jobs/gasTopUp.ts, EMG-115): the keeper calls the vault's topUpAll() only when the vault lists
// its signer, the signer is below its minBalance and the vault would send it something now; the call is urgent, goes
// through the pipeline's code check and simulation, and is never sent when the simulation fails. With minBalance at
// 3 days of daily spend, the top-up is due in every block in which M-17 would warn.

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { type Address, type Hex, decodeFunctionData } from "viem";
import { avanaGasVaultAbi } from "@avana/protocol/abis";
import { CHAINS } from "@avana/services-common";
import type { ChainReader } from "../src/chain/reads.ts";
import type { ChainConfig } from "../src/config.ts";
import { gasTopUpJob } from "../src/jobs/gasTopUp.ts";
import { m17GasLevel } from "../src/monitoring/funding.ts";
import { type PipelineDeps, type Simulation, runJob } from "../src/pipeline.ts";
import type { BlockContext } from "../src/types.ts";

const SIGNER = "0x00000000000000000000000000000000000000a1" as Address;
const VAULT = "0x00000000000000000000000000000000000000b2" as Address;
const CODE = `0x${"cd".repeat(32)}` as Hex;
const TX = `0x${"aa".repeat(32)}` as Hex;
const ETHER = 10n ** 18n;

interface Quote {
  listed: boolean;
  minBalance: bigint;
  balance: bigint;
  amount: bigint;
  requested: bigint;
  paused: boolean;
}

const due: Quote = { listed: true, minBalance: 3n * ETHER, balance: ETHER, amount: 9n * ETHER, requested: 9n * ETHER, paused: false };

function context(quote: Quote, withVault = true, codeHash: Hex = CODE): BlockContext {
  const manifest = { avana: { gasVault: withVault ? { address: VAULT, codeHash } : null } };
  const reader = {
    gasVaultQuote: vi.fn(async (vault: Address, signer: Address) => {
      expect([vault, signer]).toEqual([VAULT, SIGNER]);
      return quote;
    }),
    codeHashOf: async () => CODE,
    implementationOf: async () => VAULT,
  };
  return {
    config: { chain: CHAINS.mainnet, manifest } as unknown as ChainConfig,
    blockNumber: 100n,
    blockTimestamp: 1_700_000_000n,
    reader: reader as unknown as ChainReader,
  };
}

function deps(sim: Simulation) {
  return {
    safety: { halted: false, codeMismatch: null, frozenHelperChains: new Set<number>() },
    mode: () => "active" as const,
    simulate: vi.fn(async () => sim),
    submit: vi.fn(async () => TX),
    page: vi.fn(),
  } satisfies PipelineDeps;
}

beforeEach(() => {
  vi.spyOn(process.stdout, "write").mockImplementation(() => true);
});
afterEach(() => vi.restoreAllMocks());

describe("gas vault top-up", () => {
  const job = gasTopUpJob(SIGNER);

  it("has nothing to do before the vault is deployed", async () => {
    expect(await job.discover(context(due, false))).toEqual([]);
  });

  it("acts only when the signer is listed, below its minimum and the vault would send something", async () => {
    const ctx = (q: Partial<Quote>) => context({ ...due, ...q });
    const vault = { address: VAULT, codeHash: CODE };
    expect(await job.check(ctx({ listed: false }), vault)).toMatchObject({ act: false, reason: "notDue" });
    expect(await job.check(ctx({ balance: 3n * ETHER }), vault)).toMatchObject({ act: false, reason: "notDue" });
    expect(await job.check(ctx({ paused: true, amount: 0n }), vault)).toMatchObject({ act: false, reason: "conditionFalse", detail: "gas vault paused" });
    expect(await job.check(ctx({ amount: 0n }), vault)).toMatchObject({ act: false, reason: "conditionFalse" });
    expect(await job.check(ctx({}), vault)).toMatchObject({ act: true });
  });

  it("builds an urgent topUpAll() to the vault, checked against the vault's code hash", async () => {
    const ctx = context(due);
    const check = await job.check(ctx, { address: VAULT, codeHash: CODE });
    if (!check.act) throw new Error("not due");
    const plan = await job.build(ctx, check.decision);
    expect(plan).toMatchObject({ job: "gasTopUp", jobClass: "urgent", to: VAULT, deadline: null, reservations: [] });
    expect(plan.subject).toBe(`${CHAINS.mainnet.id}:${VAULT}`);
    expect(decodeFunctionData({ abi: avanaGasVaultAbi, data: plan.data }).functionName).toBe("topUpAll");
    expect(plan.targets).toEqual([{ kind: "immutable", address: VAULT, codeHash: CODE }]);
    expect(plan.params).toMatchObject({ signer: SIGNER, amount: 9n * ETHER });
  });

  it("sends after a successful simulation, never after a failed one", async () => {
    const sent = deps({ ok: true, gasEstimate: 240_000n });
    await runJob(job, context(due), sent);
    expect(sent.simulate).toHaveBeenCalledTimes(1);
    expect(sent.submit).toHaveBeenCalledTimes(1);

    const failed = deps({ ok: false, gasEstimate: 0n });
    await runJob(job, context(due), failed);
    expect(failed.submit).not.toHaveBeenCalled();

    const idle = deps({ ok: true, gasEstimate: 240_000n });
    await runJob(job, context({ ...due, balance: 5n * ETHER }), idle);
    expect(idle.simulate).not.toHaveBeenCalled();
  });

  it("stops on a vault whose code is not the manifest's", async () => {
    const d = deps({ ok: true, gasEstimate: 240_000n });
    const ctx = context(due, true, `0x${"ef".repeat(32)}` as Hex);
    await runJob(job, ctx, d);
    expect(d.page).toHaveBeenCalledWith("M-26", expect.objectContaining({ address: VAULT }));
    expect(d.safety.codeMismatch).not.toBeNull();
  });

  it("with minBalance = 3 days of spend, the top-up is due whenever M-17 warns or pages", async () => {
    const daily = ETHER / 10n;
    const minBalance = 3n * daily;
    const vault = { address: VAULT, codeHash: CODE };
    // A signer spending its daily amount block after block from 1 ETH down to nothing.
    for (let balance = ETHER; balance >= 0n; balance -= daily / 4n) {
      const level = m17GasLevel(balance, daily);
      const check = await job.check(context({ ...due, minBalance, balance }), vault);
      if (level !== "ok") expect(check.act, `balance ${balance}`).toBe(true);
    }
  });
});
