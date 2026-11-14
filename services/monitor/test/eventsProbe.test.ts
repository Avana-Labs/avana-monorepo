// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The events probe on scripted logs: each event to its signal and level, events counted only from the contract they
// belong to, the block range carried across rounds and shared with the confirming read, and the M-10 hour counts.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { FIXTURE_U, FIXTURE_USDC, fixtureMarkets } from "@avana/services-common/fixtures";
import { avanaTimelockAbi, collateralizationAbi, lpVaultSwapAbi, marketRegistryAbi, riskModuleAbi } from "@avana/protocol/abis";
import { type Abi, type Address, type Hex, encodeAbiParameters, encodeEventTopics, encodeFunctionData, parseAbi } from "viem";
import { eventsProbe } from "../src/probes/events.ts";
import type { RawLog } from "../src/probe.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider } from "./fakeChain.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const TIMELOCK = A(0x71), REGISTRY = A(0x72), RISK = A(0x73), COLL = A(0x74), SWAP = A(0x75), ADAPTER = A(0x76), LPVAULT = A(0x77), ESCROW = A(0x78);

const manifest = {
  ...EMPTY_MANIFEST,
  avana: { ...EMPTY_MANIFEST.avana, timelock: { address: TIMELOCK }, marketRegistry: { address: REGISTRY }, riskModule: { address: RISK }, collateralization: { address: COLL }, lpVaultSwap: { address: SWAP }, aaveAdapter: { address: ADAPTER }, payoutEscrow: { address: ESCROW }, lpVaults: [{ address: LPVAULT, integrationId: 1 }] },
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

const scheduled = (data: Hex, block: bigint) => log(avanaTimelockAbi as Abi, "CallScheduled", { id: `0x${"11".repeat(32)}`, index: 0n, target: REGISTRY, value: 0n, data, predecessor: `0x${"00".repeat(32)}`, delay: 172_800n }, TIMELOCK, block);
const registryCall = (sig: string, args: unknown[]) => encodeFunctionData({ abi: parseAbi([`function ${sig}`] as unknown as readonly ["function f()"]), args } as never);

describe("eventsProbe", () => {
  it("maps each event to its signal and level, from its own contract only", async () => {
    const p = fakeProvider();
    p.logs.push(
      scheduled(registryCall("unfreezeAddress(address)", [A(9)]), 10n),
      scheduled(registryCall("setStressFloor(uint256)", [1n]), 10n),
      log(avanaTimelockAbi as Abi, "RoleGranted", { role: `0x${"22".repeat(32)}`, account: A(9), sender: A(8) }, TIMELOCK, 10n),
      log(marketRegistryAbi as Abi, "RoleGranted", { role: `0x${"22".repeat(32)}`, account: A(9), sender: A(8) }, A(0x99), 10n), // not a watched contract
      log(riskModuleAbi as Abi, "ConfigDriftDetected", { spoke: FIXTURE_U, reason: 2 }, RISK, 10n),
      log(tokenAbi, "Upgraded", { implementation: A(5) }, FIXTURE_U, 10n),
      log(collateralizationAbi as Abi, "CounterSaturated", { counterKind: 1, hub: A(1), key: A(2), valueBefore: 5n, subtracted: 9n }, COLL, 10n),
      log(marketRegistryAbi as Abi, "AddressFrozen", { account: A(9), caller: A(8) }, REGISTRY, 10n),
      log(marketRegistryAbi as Abi, "StandbyRouteActivated", { token: FIXTURE_USDC, slot: 1, caller: A(8) }, REGISTRY, 10n),
      log(tokenAbi, "Blacklisted", { _account: SWAP }, FIXTURE_USDC, 10n),
      log(tokenAbi, "AddedBlackList", { _user: ESCROW }, FIXTURE_USDC, 10n),
      log(tokenAbi, "Blacklisted", { _account: A(0x1234) }, FIXTURE_USDC, 10n),
    );
    const probe = eventsProbe();
    const ctx = await contextOf(p, { number: 10n, timestamp: 1_000 }, manifest);
    const fs = probe.evaluate(await probe.read(ctx), ctx.block);
    expect(fs.map((f) => `${f.signal}:${f.level}:${f.detail.event}${f.detail.call ? `:${f.detail.call}` : ""}`)).toEqual([
      "M-22:page:CallScheduled:unfreezeAddress",
      "M-22:warn:CallScheduled",
      "M-22:page:RoleGranted",
      "M-20:page:ConfigDriftDetected",
      "M-20:warn:Upgraded",
      "M-21:page:CounterSaturated",
      "M-24:warn:AddressFrozen",
      "M-24:warn:StandbyRouteActivated",
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

  it("counts route failures and the seized share per market over the hour", async () => {
    const p = fakeProvider();
    const probe = eventsProbe();
    const market = BigInt(fixtureMarkets[0]!.marketId);
    const supplied = BigInt(fixtureMarkets[0]!.suppliedUnits);
    const failed = (block: bigint) => log(lpVaultSwapAbi as Abi, "RouteFailed", { marketId: market, token: FIXTURE_USDC, route: A(3), errorSelector: "0x12345678" }, SWAP, block);
    const settled = (block: bigint, unitsSeized: bigint) => {
      const ev = (lpVaultSwapAbi as Abi).find((e) => e.type === "event" && e.name === "LiquidationSettled") as Extract<Abi[number], { type: "event" }>;
      const tuple = ev.inputs.find((i) => !i.indexed)!;
      const value = Object.fromEntries((tuple as unknown as { components: readonly { name: string; type: string }[] }).components.map((c) => [c.name, c.name === "unitsSeized" ? unitsSeized : c.type.endsWith("[]") ? [] : c.type === "address" ? A(0) : c.type === "bool" ? false : 0]));
      return log(lpVaultSwapAbi as Abi, "LiquidationSettled", { caller: A(1), proxy: A(2), marketId: market, [tuple.name!]: value }, SWAP, block);
    };
    const round = async (n: bigint, t: number) => {
      const ctx = await contextOf(p, { number: n, timestamp: t }, manifest);
      return Object.fromEntries(probe.evaluate(await probe.read(ctx), ctx.block).filter((f) => f.kind === "condition").map((f) => [f.subject, f.level]));
    };
    p.logs.push(failed(1n));
    expect(await round(1n, 1_000)).toEqual({ [`market:${market}:routeFailed`]: "warn" });
    p.logs.push(failed(2n), failed(2n), settled(2n, (supplied * 15n) / 85n));
    expect(await round(2n, 1_100)).toEqual({ [`market:${market}:routeFailed`]: "page", [`market:${market}:seized`]: "warn" });
    expect(await round(3n, 4_700)).toEqual({ [`market:${market}:routeFailed`]: "ok", [`market:${market}:seized`]: "ok" });
    expect(await round(4n, 4_800)).toEqual({});
  });
});
