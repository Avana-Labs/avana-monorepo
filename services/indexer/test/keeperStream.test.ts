// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The keeper stream's request parsing, served range and block-boundary closing (EXPORT.md, "Keeper stream"), and its
// record kinds against the indexed contracts' ABIs.

import { describe, expect, it } from "vitest";
import type { Abi } from "viem";
import { KEEPER_STREAM_KINDS, KEEPER_STREAM_MAX_RECORDS } from "@avana/services-common";
import { abis } from "../src/config/abis.ts";
import { closePage, cursorCanonical, parseStreamRequest, streamableThrough } from "../src/lib/keeperStream.ts";

const H = `0x${"ab".repeat(32)}` as const;

describe("keeper stream request", () => {
  it("reads chainId, a cursor with its hash and a limit", () => {
    expect(parseStreamRequest({ chainId: "1", after: "100", afterHash: H.toUpperCase().replace("0X", "0x"), limit: "50" })).toEqual({
      chainId: 1,
      after: { block: 100n, hash: H },
      limit: 50,
    });
    expect(parseStreamRequest({ chainId: "8453" })).toEqual({ chainId: 8453, after: null, limit: KEEPER_STREAM_MAX_RECORDS });
  });

  it("refuses a cursor without its hash, a bad hash and a limit out of range", () => {
    expect(parseStreamRequest({ chainId: "1", after: "100" })).toHaveProperty("error");
    expect(parseStreamRequest({ chainId: "1", afterHash: H })).toHaveProperty("error");
    expect(parseStreamRequest({ chainId: "1", after: "100", afterHash: "0x1234" })).toHaveProperty("error");
    expect(parseStreamRequest({ chainId: "1", limit: "0" })).toHaveProperty("error");
    expect(parseStreamRequest({ chainId: "1", limit: String(KEEPER_STREAM_MAX_RECORDS + 1) })).toHaveProperty("error");
    expect(parseStreamRequest({ chainId: "x" })).toHaveProperty("error");
  });
});

describe("keeper stream range", () => {
  it("serves up to the block before the Progress row, at the head (no finality cap)", () => {
    expect(streamableThrough(500n)).toBe(499n);
    expect(streamableThrough(null)).toBe(-1n);
  });

  it("accepts a cursor only while its hash is canonical, whatever the case", () => {
    expect(cursorCanonical({ block: 5n, hash: H }, H.toUpperCase().replace("0X", "0x"))).toBe(true);
    expect(cursorCanonical({ block: 5n, hash: H }, `0x${"cd".repeat(32)}`)).toBe(false);
  });
});

describe("keeper stream page closing", () => {
  const rows = (blocks: number[]) => blocks.map((b) => ({ blockNumber: BigInt(b) }));

  it("serves everything up to the indexed block when the page is not full", () => {
    expect(closePage(rows([10, 11, 11]), 20n, 5)).toEqual({ rows: rows([10, 11, 11]), toBlock: 20n, wholeBlock: null });
  });

  it("drops the last block of a full page, which may be cut", () => {
    expect(closePage(rows([10, 11, 12, 12]), 20n, 4)).toEqual({ rows: rows([10, 11]), toBlock: 11n, wholeBlock: null });
  });

  it("asks for a whole block when one block fills the page", () => {
    expect(closePage(rows([12, 12, 12]), 20n, 3)).toEqual({ rows: [], toBlock: 12n, wholeBlock: 12n });
  });
});

describe("keeper stream kinds", () => {
  // Each kind is `<Contract>.<Event>`; the contract's ABI must hold the event, or no handler could write the row.
  const abiOf: Record<string, Abi> = {
    AaveAdapter: abis.AaveAdapter,
    ProxyManager: abis.ProxyManager,
    LPVaultSwap: abis.LPVaultSwap,
    AaveSpoke: abis.AaveSpoke,
    LPOracle: abis.LPOracle,
    DebtOracle: abis.DebtOracle,
    Collateralization: abis.Collateralization,
    MarketRegistry: abis.MarketRegistry,
  };

  it("name an event of an indexed contract", () => {
    const missing = KEEPER_STREAM_KINDS.filter((k) => {
      const [contract, event] = k.split(".") as [string, string];
      const abi = abiOf[contract];
      return !abi || !abi.some((i) => i.type === "event" && i.name === event);
    });
    expect(missing).toEqual([]);
  });

  it("have no duplicates", () => {
    expect(new Set(KEEPER_STREAM_KINDS).size).toBe(KEEPER_STREAM_KINDS.length);
  });
});
