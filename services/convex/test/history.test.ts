// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The wallet history check: a page from the indexer is returned only when it is for the chain and wallet asked for,
// its records are strictly newest first and below its `before`, and its cursor points no further than its oldest record.
// Older rows are dated by their block's time, read from the chain once per block and then kept.

import { describe, expect, it, vi } from "vitest";
import { EXPORT_SCHEMA_VERSION, type HistoryPage } from "@avana/services-common/export";
import { PageRejected as HistoryRejected, validateHistoryPage } from "@avana/export";
import { type BlockTime, resolveBlockTimes } from "../convex/lib/exportPage.ts";
import { datedRows } from "../convex/wallet/history.ts";
import type { WalletActivityRow } from "../convex/wallet/activity.ts";

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

describe("block times of older rows", () => {
  const source = (stored: BlockTime[]) => {
    const kept = [...stored];
    return {
      cached: vi.fn(async (numbers: readonly string[]) => kept.filter((b) => numbers.includes(b.number))),
      fetch: vi.fn(async (b: { number: string; hash: string }) => ({ ...b, timestampMs: Number(b.number) * 12_000 })),
      store: vi.fn(async (rows: readonly BlockTime[]) => {
        kept.push(...rows);
      }),
    };
  };

  it("reads a block from the chain once, stores it and uses the stored time afterwards", async () => {
    const s = source([]);
    const first = await resolveBlockTimes([{ number: "100", hash: H(1) }, { number: "100", hash: H(1) }, { number: "90", hash: H(2) }], s);
    expect(first).toEqual(new Map([["100", 1_200_000], ["90", 1_080_000]]));
    expect(s.fetch).toHaveBeenCalledTimes(2);
    expect(s.store).toHaveBeenCalledTimes(1);

    const again = await resolveBlockTimes([{ number: "100", hash: H(1) }], s);
    expect(again.get("100")).toBe(1_200_000);
    expect(s.fetch).toHaveBeenCalledTimes(2);
    expect(s.store).toHaveBeenCalledTimes(1);
  });

  it("reads the block again when the stored hash is another block's", async () => {
    const s = source([{ number: "100", hash: H(9), timestampMs: 1 }]);
    expect((await resolveBlockTimes([{ number: "100", hash: H(1) }], s)).get("100")).toBe(1_200_000);
    expect(s.fetch).toHaveBeenCalledWith({ number: "100", hash: H(1) });
  });

  it("asks nothing for no blocks", async () => {
    const s = source([]);
    expect((await resolveBlockTimes([], s)).size).toBe(0);
    expect(s.cached).not.toHaveBeenCalled();
  });

  it("dates each row by its block and leaves out a row whose block has no time", () => {
    const row = { id: "1:0xa:0", at: new Date(0).toISOString(), kind: "supply", amountLabel: "—", walletLabel: "—", txHashShort: "0xa", source: "seed", chainId: 1 } as unknown as WalletActivityRow;
    const rows = datedRows(
      [
        { row, blockNumber: "100", blockHash: H(1) },
        { row: { ...row, id: "1:0xb:0" }, blockNumber: "99", blockHash: H(2) },
      ],
      new Map([["100", Date.UTC(2026, 9, 3)]]),
    );
    expect(rows).toEqual([{ ...row, at: "2026-10-03T00:00:00.000Z" }]);
  });
});
