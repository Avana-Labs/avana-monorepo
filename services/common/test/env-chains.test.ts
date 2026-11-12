// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Environment reads, chain lookup and the keys shared by the indexer, the export and Convex.

import { describe, expect, it } from "vitest";
import { CHAINS, blocksFor, chainById, chainsOf } from "../src/chains.ts";
import { intEnv, listEnv, optionalEnv, requireEnv, rpcEnvName } from "../src/env.ts";
import { accountKey, compareProvenance, logKey, type Provenance } from "../src/provenance.ts";

describe("environment", () => {
  it("names RPC variables by chain and role", () => {
    expect(rpcEnvName(CHAINS.mainnet, "PRIMARY")).toBe("RPC_MAINNET");
    expect(rpcEnvName(CHAINS.baseSepolia, "PRIVATE")).toBe("RPC_BASE_SEPOLIA_PRIVATE");
  });

  it("treats a blank required value as missing", () => {
    expect(() => requireEnv({ X: "   " }, "X")).toThrow(/missing environment variable X/);
    expect(requireEnv({ X: " v " }, "X")).toBe("v");
    expect(optionalEnv({ X: "" }, "X")).toBeUndefined();
  });

  it("splits lists and drops empty entries", () => {
    expect(listEnv({ L: " a, ,b,," }, "L")).toEqual(["a", "b"]);
    expect(listEnv({}, "L")).toEqual([]);
  });

  it("accepts only non-negative integers for integer variables", () => {
    expect(intEnv({ N: "42" }, "N")).toBe(42);
    expect(() => intEnv({ N: "-1" }, "N")).toThrow();
    expect(() => intEnv({ N: "1.5" }, "N")).toThrow();
  });
});

describe("chains", () => {
  it("splits production and testnet", () => {
    expect(chainsOf("production").map((c) => c.id)).toEqual([1, 8453]);
    expect(chainsOf("testnet").map((c) => c.id)).toEqual([11155111, 84532]);
  });

  it("refuses an unsupported chain ID", () => {
    expect(chainById(8453).key).toBe("base");
    expect(() => chainById(10)).toThrow(/unsupported chain 10/);
  });

  it("rounds block counts up: 60 s is 5 Ethereum blocks and 30 Base blocks, 13 s is 2 Ethereum blocks", () => {
    expect(blocksFor(CHAINS.mainnet, 60)).toBe(5);
    expect(blocksFor(CHAINS.base, 60)).toBe(30);
    expect(blocksFor(CHAINS.mainnet, 13)).toBe(2);
  });
});

describe("keys and ordering", () => {
  const p = (blockNumber: bigint, logIndex: number): Provenance => ({
    chainId: 1,
    blockNumber,
    blockHash: "0x01",
    blockTimestamp: 0n,
    txHash: "0xABCD",
    logIndex,
  });

  it("keys logs and accounts case-insensitively", () => {
    expect(logKey(p(1n, 3))).toBe("1:0xabcd:3");
    expect(accountKey(8453, "0xAA", "0xBb")).toBe("8453:0xaa:0xbb");
  });

  it("orders logs by block, then log index", () => {
    const sorted = [p(2n, 0), p(1n, 5), p(1n, 2)].sort(compareProvenance);
    expect(sorted.map((x) => [x.blockNumber, x.logIndex])).toEqual([[1n, 2], [1n, 5], [2n, 0]]);
  });
});
