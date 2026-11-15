// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The wallet history check: a page from the indexer is returned only when it is for the chain and wallet asked for,
// its records are strictly newest first and below its `before`, and its cursor points no further than its oldest record.

import { describe, expect, it } from "vitest";
import { EXPORT_SCHEMA_VERSION, type HistoryPage } from "@avana/services-common/export";
import { PageRejected as HistoryRejected, validateHistoryPage } from "@avana/export";

const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as const;
const WALLET = "0x00000000000000000000000000000000000000c0";

function record(block: number, logIndex: number) {
  return { key: `1:${H(block)}:${logIndex}`, kind: "AaveAdapter.Borrowed", blockNumber: String(block), blockHash: H(block + 1000), txHash: H(block), logIndex, address: "0x2222222222222222222222222222222222222222" as const, args: {} };
}

function page(over: Partial<HistoryPage> = {}): HistoryPage {
  return {
    schemaVersion: EXPORT_SCHEMA_VERSION,
    chainId: 1,
    wallet: WALLET,
    proxies: ["0x00000000000000000000000000000000000000c1"],
    before: "200",
    records: [record(150, 4), record(150, 1), record(120, 9)],
    next: { before: "120" },
    ...over,
  };
}

describe("wallet history checks", () => {
  it("accepts a newest-first page below its bound", () => {
    expect(() => validateHistoryPage(page(), 1, WALLET.toUpperCase().replace("0X", "0x"), 200n)).not.toThrow();
    expect(() => validateHistoryPage(page({ next: null }), 1, WALLET, null)).not.toThrow();
  });

  it("rejects another chain, another wallet or an unknown version", () => {
    expect(() => validateHistoryPage(page(), 8453, WALLET, null)).toThrow(HistoryRejected);
    expect(() => validateHistoryPage(page(), 1, "0x00000000000000000000000000000000000000c9", null)).toThrow(HistoryRejected);
    expect(() => validateHistoryPage(page({ schemaVersion: EXPORT_SCHEMA_VERSION + 1 }), 1, WALLET, null)).toThrow(HistoryRejected);
  });

  it("rejects records out of order, at or above the bound, or with a malformed key", () => {
    expect(() => validateHistoryPage(page({ records: [record(120, 9), record(150, 1)] }), 1, WALLET, null)).toThrow(/out of order/);
    expect(() => validateHistoryPage(page({ records: [record(150, 1), record(150, 1)] }), 1, WALLET, null)).toThrow(/out of order/);
    expect(() => validateHistoryPage(page({ records: [record(200, 0)] }), 1, WALLET, null)).toThrow(/not below/);
    expect(() => validateHistoryPage(page({ records: [{ ...record(150, 1), key: "2:x:1" }] }), 1, WALLET, null)).toThrow(/malformed/);
  });

  it("rejects a page above the requested block or a cursor outside the page", () => {
    expect(() => validateHistoryPage(page(), 1, WALLET, 150n)).toThrow(/above the requested/);
    expect(() => validateHistoryPage(page({ next: { before: "100" } }), 1, WALLET, null)).toThrow(/cursor/);
    expect(() => validateHistoryPage(page({ next: { before: "300" } }), 1, WALLET, null)).toThrow(/cursor/);
  });
});
