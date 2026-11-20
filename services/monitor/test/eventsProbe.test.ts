// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The events probe on scripted logs: each event to its signal and level, events counted only from the contract they
// belong to, the block range carried across rounds and shared with the confirming read, and the M-10 seized share.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { FIXTURE_U, FIXTURE_USDC, fixtureMarkets } from "@avana/services-common/fixtures";
import { accessManagerAbi, liquidationModuleAbi } from "@avana/protocol/abis";
import { type Abi, type Address, type Hex, encodeAbiParameters, encodeEventTopics, parseAbi } from "viem";
import { eventsProbe } from "../src/probes/events.ts";
import type { RawLog } from "../src/probe.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider } from "./fakeChain.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const MANAGER = A(0x71), RISK = A(0x73), MODULE = A(0x74), ADAPTER = A(0x76), LPVAULT = A(0x77), REPAY = A(0x78);

const manifest = {
  ...EMPTY_MANIFEST,
  avana: {
    accessManager: { address: MANAGER },
    integrations: [{ integrationId: 1, kind: "uniswap-v3", lpVault: { address: LPVAULT }, riskModule: { address: RISK }, liquidationModule: { address: MODULE }, aaveAdapter: { address: ADAPTER }, flashloanRepay: { address: REPAY } }],
    flashLiquidators: [],
  },
  aave: { hubs: [], lendSpokes: [], borrowSpokes: [{ address: FIXTURE_U }] },
} as unknown as ServiceManifest;

const tokenAbi = parseAbi(["event Blacklisted(address indexed _account)", "event AddedBlackList(address _user)", "event Upgraded(address indexed implementation)"]);
let index = 0;

function log(abi: Abi, eventName: string, args: Record<string, unknown>, address: Address, block: bigint): RawLog {
  const ev = abi.find((e) => e.type === "event" && e.name === eventName) as Extract<Abi[number], { type: "event" }>;
  const topics = encodeEventTopics({ abi: [ev], eventName, args: Object.fromEntries(ev.inputs.filter((i) => i.indexed).map((i) => [i.name!, args[i.name!]])) } as never) as Hex[];
  const plain = ev.inputs.filter((i) => !i.indexed);
  const data = encodeAbiParameters(plain, plain.map((i) => args[i.name!]));
  return { address, topics, data, blockNumber: block, transactionHash: `0x${(++index).toString(16).padStart(64, "0")}`, logIndex: 0 };
}


describe("eventsProbe", () => {
  it("maps each event to its signal and level, from its own contract only", async () => {
    const p = fakeProvider();
    p.logs.push(
      log(tokenAbi, "Upgraded", { implementation: A(5) }, A(0x99), 10n), // not a watched contract
      log(tokenAbi, "Upgraded", { implementation: A(5) }, FIXTURE_U, 10n),
      log(accessManagerAbi as Abi, "OperationScheduled", { operationId: `0x${"11".repeat(32)}`, nonce: 1, schedule: 2_000, caller: A(9), target: RISK, data: "0x1234" }, MANAGER, 10n),
      log(accessManagerAbi as Abi, "RoleGranted", { roleId: 101n, account: A(9), delay: 0, since: 1_000, newMember: true }, MANAGER, 10n),
      log(accessManagerAbi as Abi, "RoleGranted", { roleId: 101n, account: A(9), delay: 0, since: 1_000, newMember: true }, A(0x98), 10n), // another contract's
      log(tokenAbi, "Blacklisted", { _account: ADAPTER }, FIXTURE_USDC, 10n),
      log(tokenAbi, "AddedBlackList", { _user: RISK }, FIXTURE_USDC, 10n),
      log(tokenAbi, "Blacklisted", { _account: A(0x1234) }, FIXTURE_USDC, 10n),
    );
    const probe = eventsProbe();
    const ctx = await contextOf(p, { number: 10n, timestamp: 1_000 }, manifest);
    const fs = probe.evaluate(await probe.read(ctx), ctx.block);
    expect(fs.map((f) => `${f.signal}:${f.level}:${f.detail.event}`)).toEqual([
      "M-20:warn:Upgraded",
      "M-22:warn:OperationScheduled",
      "M-22:page:RoleGranted",
      "M-25:page:Blacklisted",
      "M-25:warn:AddedBlackList",
    ]);
    expect(fs.every((f) => f.kind === "event")).toBe(true);
  });

  it("starts at the head, continues after the last range, and lets the confirming read see the same range", async () => {
    const p = fakeProvider();
    const probe = eventsProbe();
    const at = async (n: bigint) => {
      const ctx = await contextOf(p, { number: n, timestamp: Number(n) }, manifest);
      return { ctx, input: await probe.read(ctx) };
    };
    const first = await at(100n);
    expect([first.input.from, first.input.to]).toEqual([100n, 100n]);
    probe.evaluate(first.input, first.ctx.block);
    const second = await at(105n);
    expect([second.input.from, second.input.to]).toEqual([101n, 105n]);
    probe.evaluate(second.input, second.ctx.block);
    expect([(await at(105n)).input.from]).toEqual([101n]); // the confirming read of the same block
    const late = await at(5_000n);
    expect([late.input.from, late.input.to]).toEqual([106n, 2_105n]);
  });

  it("counts the seized share per market over the hour", async () => {
    const p = fakeProvider();
    const probe = eventsProbe();
    const market = BigInt(fixtureMarkets[0]!.marketId);
    const supplied = BigInt(fixtureMarkets[0]!.suppliedUnits);
    const liquidated = (block: bigint, seized: bigint) =>
      log(liquidationModuleAbi as Abi, "Liquidated", { account: A(2), marketId: market, liquidator: A(1), debtReserveId: 1n, debtRepaid: 1n, seized, creditUnwound: 1n, amount0: 1n, amount1: 1n }, MODULE, block);
    const round = async (n: bigint, t: number) => {
      const ctx = await contextOf(p, { number: n, timestamp: t }, manifest);
      return Object.fromEntries(probe.evaluate(await probe.read(ctx), ctx.block).filter((f) => f.kind === "condition").map((f) => [f.subject, f.level]));
    };
    p.logs.push(liquidated(1n, (supplied * 15n) / 85n));
    expect(await round(1n, 1_000)).toEqual({ [`market:${market}:seized`]: "warn" });
    p.logs.push(liquidated(2n, (supplied * 10n) / 85n));
    expect(await round(2n, 1_100)).toEqual({ [`market:${market}:seized`]: "page" });
    expect(await round(3n, 4_700)).toEqual({ [`market:${market}:seized`]: "ok" });
    expect(await round(4n, 4_800)).toEqual({});
  });
});
