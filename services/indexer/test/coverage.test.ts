// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Every event of every contract the indexer follows has a handler, so a new event in a release's ABIs fails here
// instead of being silently dropped; the few left out are listed below with the reason. Hub and Spoke events must
// be registered on every source that follows the contract (src/config/aaveSources.ts).

import { describe, expect, it } from "vitest";
import type { Abi } from "viem";
import { clPoolAbi, uniswapV4PoolManagerAbi } from "@avana/services-common/views";
import { abis } from "../src/config/abis.ts";
import { AAVE_HUB_SOURCES, AAVE_SPOKE_SOURCES } from "../src/config/aaveSources.ts";
import { registered } from "./harness/run.ts";

/** Events deliberately not handled, by `<Source>.<Event>`. */
const NOT_INDEXED: Readonly<Record<string, string>> = {
  "VaultToken.Approval": "vault-token allowances are internal to the AaveAdapter and its proxies; no consumer reads them",
  "UniswapV4PoolManager.Initialize": "a pool is initialized before any market can list it; the market row carries its tokens",
};

const SOURCES: Readonly<Record<string, Abi>> = {
  ...Object.fromEntries(Object.entries(abis).filter(([name]) => name !== "AaveSpoke" && name !== "AaveHub")),
  ...Object.fromEntries(AAVE_SPOKE_SOURCES.map((s) => [s, abis.AaveSpoke])),
  ...Object.fromEntries(AAVE_HUB_SOURCES.map((s) => [s, abis.AaveHub])),
  DaoDeficitOffset: abis.AvanaFirstLossReserve,
  AmmPool: clPoolAbi,
  UniswapV4PoolManager: uniswapV4PoolManagerAbi,
} as Record<string, Abi>;

describe("event coverage", () => {
  it("has a handler for every event of every source, or a stated reason", () => {
    const missing: string[] = [];
    for (const [source, abi] of Object.entries(SOURCES)) {
      for (const item of abi) {
        if (item.type !== "event") continue;
        if (registered.has(`${source}:${item.name}`)) continue;
        if (NOT_INDEXED[`${source}.${item.name}`]) continue;
        missing.push(`${source}.${item.name}`);
      }
    }
    expect(missing).toEqual([]);
  });

  it("registers no handler for an event the source's ABI does not have", () => {
    const extra = [...registered.keys()].filter((name) => {
      const [source, event] = name.split(":") as [string, string];
      if (event === "block") return false;
      const abi = SOURCES[source];
      return !abi || !abi.some((i) => i.type === "event" && i.name === event);
    });
    expect(extra).toEqual([]);
  });

  it("lists no reason for an event that is handled or does not exist", () => {
    for (const name of Object.keys(NOT_INDEXED)) {
      const [source, event] = name.split(".") as [string, string];
      expect(registered.has(`${source}:${event}`), name).toBe(false);
      expect(SOURCES[source]!.some((i) => i.type === "event" && i.name === event), name).toBe(true);
    }
  });
});
