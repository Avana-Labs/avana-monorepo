// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The wallet history (EXPORT.md, "Older history"): request parsing, the addresses a log names (the log_party rows) and
// closing a newest-first page at a block boundary.

import { describe, expect, it } from "vitest";
import { HISTORY_MAX_RECORDS } from "@avana/services-common";
import { closeHistoryPage, parseHistoryRequest, partiesOf } from "../src/lib/history.ts";

const W = "0x00000000000000000000000000000000000000Aa";

describe("history request", () => {
  it("reads chainId, a lower-cased wallet, an optional before and a limit", () => {
    expect(parseHistoryRequest({ chainId: "1", wallet: W, before: "100", limit: "50" })).toEqual({ chainId: 1, wallet: W.toLowerCase(), before: 100n, limit: 50 });
    expect(parseHistoryRequest({ chainId: "8453", wallet: W })).toEqual({ chainId: 8453, wallet: W.toLowerCase(), before: null, limit: HISTORY_MAX_RECORDS });
  });

  it("refuses a malformed wallet, block or limit", () => {
    expect(parseHistoryRequest({ chainId: "1", wallet: "0x1234" })).toHaveProperty("error");
    expect(parseHistoryRequest({ chainId: "1" })).toHaveProperty("error");
    expect(parseHistoryRequest({ chainId: "1", wallet: W, before: "-1" })).toHaveProperty("error");
    expect(parseHistoryRequest({ chainId: "1", wallet: W, limit: "0" })).toHaveProperty("error");
    expect(parseHistoryRequest({ chainId: "1", wallet: W, limit: String(HISTORY_MAX_RECORDS + 1) })).toHaveProperty("error");
  });
});

describe("parties of a log", () => {
  it("finds every distinct address in the normalised arguments, nested ones included, and nothing else", () => {
    const proxy = "0x00000000000000000000000000000000000000bb";
    const args = {
      user: W.toLowerCase(),
      onBehalfOf: proxy,
      amount: "1000",
      reserveId: "3",
      hash: `0x${"cd".repeat(32)}`,
      params: { receiver: proxy, path: ["0x00000000000000000000000000000000000000cc"] },
    };
    expect(partiesOf(args).sort()).toEqual([W.toLowerCase(), proxy, "0x00000000000000000000000000000000000000cc"].sort());
    expect(partiesOf({ amount: "5" })).toEqual([]);
  });
});

describe("history page closing", () => {
  const rows = (blocks: number[]) => blocks.map((b) => ({ blockNumber: BigInt(b) }));

  it("serves a page that is not full whole, with nothing older", () => {
    expect(closeHistoryPage(rows([12, 11, 11]), 5)).toEqual({ rows: rows([12, 11, 11]), next: null, wholeBlock: null });
  });

  it("drops the oldest block of a full page, which the next page starts with", () => {
    expect(closeHistoryPage(rows([20, 15, 12, 12]), 4)).toEqual({ rows: rows([20, 15]), next: 13n, wholeBlock: null });
  });

  it("asks for a whole block when one block fills the page, and the next page starts below it", () => {
    expect(closeHistoryPage(rows([12, 12, 12]), 3)).toEqual({ rows: [], next: 12n, wholeBlock: 12n });
  });
});
