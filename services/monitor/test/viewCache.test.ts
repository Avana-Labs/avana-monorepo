// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Contract facts kept between rounds (src/viewCache.ts): a successful read of a fixed fact is served from memory in
// later rounds and the rest of the batch is still read; a failed fact and every other read go to the provider again.

import { describe, expect, it } from "vitest";
import type { CallResult, ContractCall, ViewClient } from "@avana/services-common/views";
import { FactCache } from "../src/viewCache.ts";

const call = (address: string, functionName: string, args: readonly unknown[] = []): ContractCall => ({ address: address as `0x${string}`, abi: [], functionName, args });

/** A provider answering with a counter, failing the reads `fail` names. */
function provider(fail: Set<string> = new Set()) {
  const asked: string[] = [];
  let n = 0;
  const client: ViewClient = {
    multicall: async (calls) => {
      asked.push(...calls.map((c) => c.functionName));
      return calls.map((c): CallResult => (fail.has(c.functionName) ? { status: "failure", error: "reverted" } : { status: "success", result: ++n }));
    },
  };
  return { client, asked };
}

describe("FactCache", () => {
  it("reads a fact once and every other read every round, keeping the batch order", async () => {
    const { client, asked } = provider();
    const facts = new FactCache();
    const batch = [call("0xA", "getHubAsset", [1n]), call("0xH", "getAssetUnderlyingAndDecimals", [1n]), call("0xO", "decimals")];
    const first = await facts.wrap(client).multicall(batch);
    const second = await facts.wrap(client).multicall(batch);
    expect(asked).toEqual(["getHubAsset", "getAssetUnderlyingAndDecimals", "decimals", "getHubAsset"]);
    expect(second.map((r) => (r.status === "success" ? r.result : null))).toEqual([4, (first[1] as { result: unknown }).result, (first[2] as { result: unknown }).result]);
    expect(facts.size).toBe(2);
  });

  it("keys a fact by contract and arguments", async () => {
    const { client, asked } = provider();
    const facts = new FactCache();
    await facts.wrap(client).multicall([call("0xH", "getAssetUnderlyingAndDecimals", [1n])]);
    await facts.wrap(client).multicall([call("0xH", "getAssetUnderlyingAndDecimals", [2n]), call("0xh", "getAssetUnderlyingAndDecimals", [1n])]);
    expect(asked).toEqual(["getAssetUnderlyingAndDecimals", "getAssetUnderlyingAndDecimals"]);
  });

  it("never keeps a failed fact", async () => {
    const { client, asked } = provider(new Set(["ORACLE"]));
    const facts = new FactCache();
    await facts.wrap(client).multicall([call("0xS", "ORACLE")]);
    await facts.wrap(client).multicall([call("0xS", "ORACLE")]);
    expect(asked).toEqual(["ORACLE", "ORACLE"]);
    expect(facts.size).toBe(0);
  });

  it("sends nothing when every read is a kept fact", async () => {
    const { client, asked } = provider();
    const facts = new FactCache();
    await facts.wrap(client).multicall([call("0xO", "decimals")]);
    await facts.wrap(client).multicall([call("0xO", "decimals")]);
    expect(asked).toEqual(["decimals"]);
  });
});
