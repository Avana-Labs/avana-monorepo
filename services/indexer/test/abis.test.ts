// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The indexer's ABIs against what it subscribes to: factory events decode the child address, and every event named
// in a logOnly list exists in its contract's ABI (Ponder would otherwise refuse to start).

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { type Abi, type Address, decodeEventLog, encodeAbiParameters, encodeEventTopics, getAddress, toEventSelector } from "viem";
import { abis, factoryEvents } from "../src/config/abis.ts";

const VAULT_TOKEN: Address = getAddress("0x00000000000000000000000000000000000000a1");
const SPOKE: Address = getAddress("0x00000000000000000000000000000000000000b2");

describe("factory events", () => {
  it("are events of the contract the source watches", () => {
    const watched = [
      [factoryEvents.vaultTokenDeployed, abis.VaultTokenFactory],
      [factoryEvents.marketRegistered, abis.MarketRegistry],
      [factoryEvents.debtReserveApproved, abis.MarketRegistry],
      [factoryEvents.coverageSpokeSet, abis.MarketRegistry],
    ] as const;
    for (const [event, abi] of watched) {
      const selectors = (abi as Abi).filter((i) => i.type === "event").map((i) => toEventSelector(i));
      expect(selectors).toContain(toEventSelector(event));
    }
  });

  it("decode the vault token address from a VaultTokenDeployed log", () => {
    const event = factoryEvents.vaultTokenDeployed;
    const nonIndexed = event.inputs.filter((i) => !i.indexed);
    const topics = encodeEventTopics({ abi: [event], eventName: "VaultTokenDeployed", args: { vaultToken: VAULT_TOKEN, marketId: 7n, spoke: SPOKE } });
    const values = nonIndexed.map((i) => zeroOf(i));
    const data = encodeAbiParameters(nonIndexed, values);
    const log = decodeEventLog({ abi: abis.VaultTokenFactory, topics: topics as [`0x${string}`, ...`0x${string}`[]], data });
    expect(log.eventName).toBe("VaultTokenDeployed");
    expect(log.args).toMatchObject({ vaultToken: VAULT_TOKEN, marketId: 7n, spoke: SPOKE });
  });

  it("decode the price source from a DebtReserveApproved log", () => {
    const priceSource: Address = getAddress("0x00000000000000000000000000000000000000c3");
    const event = factoryEvents.debtReserveApproved;
    const topics = encodeEventTopics({ abi: [event], eventName: "DebtReserveApproved", args: { spoke: SPOKE, reserveId: 2n } });
    const nonIndexed = event.inputs.filter((i) => !i.indexed);
    const data = encodeAbiParameters(nonIndexed, nonIndexed.map((i) => (i.name === "priceSource" ? priceSource : zeroOf(i))));
    const log = decodeEventLog({ abi: abis.MarketRegistry, topics: topics as [`0x${string}`, ...`0x${string}`[]], data });
    expect(log.args).toMatchObject({ spoke: SPOKE, reserveId: 2n, priceSource });
  });
});

describe("logOnly subscriptions", () => {
  it("name only events present in the contract's ABI", () => {
    const dir = join(import.meta.dirname, "../src/handlers");
    const byContract = abis as unknown as Record<string, Abi>;
    const missing: string[] = [];
    let checked = 0;
    for (const file of readdirSync(dir)) {
      const src = readFileSync(join(dir, file), "utf8");
      for (const [, contract, list] of src.matchAll(/logOnly\("(\w+)",\s*\[([^\]]*)\]/g)) {
        const abi = byContract[contract!];
        expect(abi, `${file}: unknown contract ${contract}`).toBeDefined();
        for (const [, name] of list!.matchAll(/"(\w+)"/g)) {
          checked++;
          if (!abi!.some((i) => i.type === "event" && i.name === name)) missing.push(`${file}: ${contract}.${name}`);
        }
      }
    }
    expect(checked).toBeGreaterThan(50);
    expect(missing).toEqual([]);
  });
});

/** A zero value of any ABI parameter type, enough to encode a log whose other fields the test does not read. */
function zeroOf(p: { type: string; components?: readonly { type: string }[] }): unknown {
  if (p.type.endsWith("[]")) return [];
  if (p.type === "tuple") return (p.components ?? []).map((c) => zeroOf(c));
  if (p.type === "address") return "0x0000000000000000000000000000000000000000";
  if (p.type === "bool") return false;
  if (p.type === "string") return "";
  if (p.type === "bytes") return "0x";
  if (p.type.startsWith("bytes")) return `0x${"00".repeat(Number(p.type.slice(5)))}`;
  return 0n;
}
