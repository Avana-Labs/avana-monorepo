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
const RESERVE: Address = getAddress("0x00000000000000000000000000000000000000b2");

describe("factory events", () => {
  it("are events of the contract the source watches", () => {
    const watched = [
      [factoryEvents.marketActivated, abis.RiskModule],
      [factoryEvents.debtReserveSet, abis.RiskModule],
      [factoryEvents.addSpoke, abis.AaveHub],
    ] as const;
    for (const [event, abi] of watched) {
      const selectors = (abi as Abi).filter((i) => i.type === "event").map((i) => toEventSelector(i));
      expect(selectors).toContain(toEventSelector(event));
    }
  });

  it("decode the vault token from MarketActivated and the First-Loss Reserve from DebtReserveSet", () => {
    const decode = (event: (typeof factoryEvents)["marketActivated" | "debtReserveSet"], args: Record<string, unknown>) => {
      const nonIndexed = event.inputs.filter((i) => !i.indexed);
      const topics = encodeEventTopics({ abi: [event], eventName: event.name, args } as never);
      const data = encodeAbiParameters(nonIndexed, nonIndexed.map((i) => args[i.name!] ?? zeroOf(i)));
      return decodeEventLog({ abi: abis.RiskModule, topics: topics as [`0x${string}`, ...`0x${string}`[]], data }).args;
    };
    expect(decode(factoryEvents.marketActivated, { marketId: 7n, vaultToken: VAULT_TOKEN })).toMatchObject({ marketId: 7n, vaultToken: VAULT_TOKEN });
    expect(decode(factoryEvents.debtReserveSet, { spoke: VAULT_TOKEN, reserveId: 2n, firstLossReserve: RESERVE })).toMatchObject({ reserveId: 2n, firstLossReserve: RESERVE });
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
    expect(checked).toBeGreaterThan(20);
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
