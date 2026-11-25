// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The export client's contract: signatures equal the indexer's node:crypto HMAC and verify under rotation and skew
// rules; every validator refuses the malformed pages EXPORT.md rules out; the client signs, maps 204/503/other
// statuses and validates before it returns. Keys are generated at run time.

import { createHmac, randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { EXPORT_SCHEMA_VERSION, type ExportPage, type HistoryPage, type PremiumRefreshList } from "@avana/services-common/export";
import { SERIES_SCHEMA_VERSION, type SeriesExportPage } from "@avana/services-common/series";
import {
  ExportHttpError,
  ExportUnavailable,
  MAX_CLOCK_SKEW_SECONDS,
  PageRejected,
  createExportClient,
  parseKeys,
  signRequest,
  validateHistoryPage,
  validatePage,
  validatePremiumRefresh,
  validateSeriesPage,
  verifyRequest,
  withPageHash,
} from "../src/index.ts";

const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as const;
const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as const;
const NOW = 1_767_225_600;
const secret = () => randomBytes(32);

function page(over: Partial<Omit<ExportPage, "pageHash">> = {}): ExportPage {
  return withPageHash({
    schemaVersion: EXPORT_SCHEMA_VERSION,
    chainId: 1,
    after: { throughBlock: "100" },
    next: { throughBlock: "110" },
    fromBlock: "101",
    toBlock: "110",
    toBlockHash: H(110),
    blocks: [
      { number: "105", hash: H(105), timestamp: "1767225600" },
      { number: "110", hash: H(110), timestamp: "1767225660" },
    ],
    records: [
      { key: `1:${H(1)}:0`, kind: "AaveSpoke.Supply", blockNumber: "105", blockHash: H(105), txHash: H(1), logIndex: 0, address: A(2), args: {} },
      { key: `1:${H(1)}:3`, kind: "AaveSpoke.Withdraw", blockNumber: "105", blockHash: H(105), txHash: H(1), logIndex: 3, address: A(2), args: {} },
    ],
    finalizedBlock: "120",
    ...over,
  });
}

describe("request signing", () => {
  it("equals the indexer's node:crypto HMAC", async () => {
    const s = secret();
    const path = "/export/v1/pages?chainId=1&after=5&limit=500";
    const headers = await signRequest(s.toString("base64"), "k1", "get", path, NOW);
    const expected = createHmac("sha256", s).update(`${NOW}\nGET\n${path}`).digest("hex");
    expect(headers).toEqual({ "x-avana-key-id": "k1", "x-avana-timestamp": String(NOW), "x-avana-signature": expected });
  });

  it("refuses a secret under 32 bytes", async () => {
    await expect(signRequest(randomBytes(31).toString("base64"), "k1", "GET", "/", NOW)).rejects.toThrow(/32/);
  });

  it("verifies both keys during a rotation and refuses unknown, stale, malformed and forged requests", async () => {
    const [old, next] = [secret(), secret()];
    const keys = parseKeys(`old:${old.toString("base64")},\nnew:${next.toString("base64")}`);
    const path = "/export/v1/series?chainId=8453&limit=10";
    for (const [id, s] of [["old", old], ["new", next]] as const) {
      const h = await signRequest(s.toString("base64"), id, "GET", path, NOW);
      expect(await verifyRequest(keys, (n) => h[n as keyof typeof h], "GET", path, NOW + MAX_CLOCK_SKEW_SECONDS)).toEqual({ ok: true, keyId: id });
    }
    const h = await signRequest(old.toString("base64"), "old", "GET", path, NOW);
    const read = (over: Record<string, string>) => (n: string) => ({ ...h, ...over })[n];
    expect(await verifyRequest(keys, read({}), "GET", path, NOW + MAX_CLOCK_SKEW_SECONDS + 1)).toEqual({ ok: false, reason: "stale" });
    expect(await verifyRequest(keys, read({ "x-avana-key-id": "gone" }), "GET", path, NOW)).toEqual({ ok: false, reason: "unknownKey" });
    expect(await verifyRequest(keys, read({ "x-avana-timestamp": "1e9" }), "GET", path, NOW)).toEqual({ ok: false, reason: "badTimestamp" });
    expect(await verifyRequest(keys, read({}), "GET", `${path}0`, NOW)).toEqual({ ok: false, reason: "badSignature" });
    expect(await verifyRequest(keys, read({ "x-avana-key-id": "new" }), "GET", path, NOW)).toEqual({ ok: false, reason: "badSignature" });
  });

  it("refuses malformed or duplicate key lists", () => {
    const s = secret().toString("base64");
    expect(() => parseKeys("")).toThrow(/no export key/);
    expect(() => parseKeys("nocolon")).toThrow(/id:base64secret/);
    expect(() => parseKeys(`a:${s},a:${s}`)).toThrow(/twice/);
    expect(() => parseKeys(`a:${randomBytes(8).toString("base64")}`)).toThrow(/32/);
  });
});

describe("event pages", () => {
  it("accepts a page that continues the checkpoint", () => {
    expect(() => validatePage(page(), 1, 100n)).not.toThrow();
    expect(() => validatePage(page({ after: null, fromBlock: "0" }), 1, null)).not.toThrow();
  });

  it("refuses gaps, overlaps, a wrong chain, a passed finality and a moved cursor", () => {
    expect(() => validatePage(page(), 1, 99n)).toThrow(PageRejected);
    expect(() => validatePage(page({ after: { throughBlock: "100" }, fromBlock: "100" }), 1, 100n)).toThrow(/starts at/);
    expect(() => validatePage(page({ after: null }), 1, 100n)).toThrow(/continues/);
    expect(() => validatePage(page({ finalizedBlock: "109" }), 1, 100n)).toThrow(/finalized/);
    expect(() => validatePage(page(), 8453, 100n)).toThrow(/chain/);
    expect(() => validatePage(page({ next: { throughBlock: "109" } }), 1, 100n)).toThrow(/cursor/);
    expect(() => validatePage(page({ fromBlock: "x1" }), 1, 100n)).toThrow(/decimal/);
  });

  it("refuses out-of-order, out-of-range, re-hashed and mis-keyed records, and tampered content", () => {
    const p = page();
    const [r0, r1] = [p.records[0]!, p.records[1]!];
    expect(() => validatePage(page({ records: [r1, r0] }), 1, 100n)).toThrow(/order/);
    expect(() => validatePage(page({ records: [r0, r0] }), 1, 100n)).toThrow(/order/);
    expect(() => validatePage(page({ records: [{ ...r0, blockNumber: "111" }] }), 1, 100n)).toThrow(/outside/);
    expect(() => validatePage(page({ records: [{ ...r0, blockHash: H(999) }] }), 1, 100n)).toThrow(/hash/);
    expect(() => validatePage(page({ records: [{ ...r0, key: `8453:${H(1)}:0` }] }), 1, 100n)).toThrow(/malformed/);
    expect(() => validatePage(page({ toBlockHash: H(1) }), 1, 100n)).toThrow(/toBlock hash/);
    expect(() => validatePage({ ...p, records: [{ ...r0, args: { amount: "1" } }, r1] }, 1, 100n)).toThrow(/page hash/);
  });
});

describe("series, history and premium-refresh responses", () => {
  const series = (over: Partial<Omit<SeriesExportPage, "pageHash">> = {}): SeriesExportPage =>
    withPageHash({ schemaVersion: SERIES_SCHEMA_VERSION, chainId: 1, after: { throughTime: 3600 }, next: { throughTime: 7200 }, records: [], finalizedBlock: "10", ...over });

  it("checks series pages", () => {
    expect(() => validateSeriesPage(series(), 1, 3600)).not.toThrow();
    expect(() => validateSeriesPage(series({ after: null }), 1, -1)).not.toThrow();
    expect(() => validateSeriesPage(series(), 1, 0)).toThrow(/checkpoint/);
    expect(() => validateSeriesPage(series({ next: { throughTime: 3600 } }), 1, 3600)).toThrow(/advance/);
    expect(() => validateSeriesPage(series({ schemaVersion: 99 }), 1, 3600)).toThrow(/version/);
    expect(() => validateSeriesPage({ ...series(), finalizedBlock: "11" }, 1, 3600)).toThrow(/hash/);
  });

  const WALLET = A(0xc1);
  const rec = (block: number, logIndex: number) => ({ ...page().records[0]!, key: `1:${H(1)}:${logIndex}`, blockNumber: String(block), logIndex });
  const history = (over: Partial<HistoryPage> = {}): HistoryPage => ({
    schemaVersion: EXPORT_SCHEMA_VERSION,
    chainId: 1,
    wallet: WALLET,
    proxies: [A(0xd1)],
    before: "200",
    records: [rec(150, 2), rec(150, 1), rec(120, 9)],
    next: { before: "120" },
    ...over,
  });

  it("checks history pages", () => {
    expect(() => validateHistoryPage(history(), 1, WALLET.toUpperCase().replace("0X", "0x"), 200n)).not.toThrow();
    expect(() => validateHistoryPage(history(), 1, WALLET, 150n)).toThrow(/above/);
    expect(() => validateHistoryPage(history({ records: [rec(120, 9), rec(150, 1)] }), 1, WALLET, null)).toThrow(/order/);
    expect(() => validateHistoryPage(history({ records: [rec(200, 0)] }), 1, WALLET, null)).toThrow(/not below/);
    expect(() => validateHistoryPage(history({ next: { before: "300" } }), 1, WALLET, null)).toThrow(/cursor/);
    expect(() => validateHistoryPage(history({ proxies: ["0xABC" as `0x${string}`] }), 1, WALLET, null)).toThrow(/proxy/);
  });

  it("checks premium-refresh lists", () => {
    const list = (over: Partial<PremiumRefreshList> = {}): PremiumRefreshList => ({ chainId: 1, spoke: A(5), asOfBlock: "9", riskChangedBlock: "8", proxies: [A(1), A(2)], ...over });
    expect(() => validatePremiumRefresh(list(), 1, A(5))).not.toThrow();
    expect(() => validatePremiumRefresh(list({ proxies: [A(2), A(1)] }), 1, A(5))).toThrow(/sorted/);
    expect(() => validatePremiumRefresh(list({ riskChangedBlock: null }), 1, A(5))).toThrow(/without a risk change/);
    expect(() => validatePremiumRefresh(list(), 1, A(6))).toThrow(/Spoke/);
  });
});

describe("client", () => {
  function fakeIndexer(respond: (path: string) => Response) {
    const seen: { url: string; headers: Record<string, string> }[] = [];
    const f = (async (url: string, init?: RequestInit) => {
      seen.push({ url, headers: init?.headers as Record<string, string> });
      return respond(new URL(url).pathname + new URL(url).search);
    }) as unknown as typeof fetch;
    return { f, seen };
  }

  it("signs the exact path and query it requests, validates and returns the page", async () => {
    const s = secret();
    const { f, seen } = fakeIndexer(() => Response.json(page()));
    const client = createExportClient({ baseUrl: "http://indexer.internal:42069/", keyId: "k1", secretBase64: s.toString("base64"), fetch: f, now: () => NOW });
    expect(await client.pages(1, 100n)).toEqual(page());
    expect(seen[0]!.url).toBe("http://indexer.internal:42069/export/v1/pages?chainId=1&after=100&limit=500");
    const keys = parseKeys(`k1:${s.toString("base64")}`);
    expect(await verifyRequest(keys, (n) => seen[0]!.headers[n], "GET", "/export/v1/pages?chainId=1&after=100&limit=500", NOW)).toEqual({ ok: true, keyId: "k1" });
  });

  it("returns null on 204, throws ExportUnavailable on 503 and ExportHttpError otherwise", async () => {
    const make = (status: number) =>
      createExportClient({ baseUrl: "http://i", keyId: "k", secretBase64: secret().toString("base64"), fetch: fakeIndexer(() => new Response(null, { status })).f, now: () => NOW });
    expect(await make(204).pages(1, null)).toBeNull();
    await expect(make(503).history(1, A(1), null)).rejects.toBeInstanceOf(ExportUnavailable);
    await expect(make(401).series(1, -1)).rejects.toBeInstanceOf(ExportHttpError);
  });

  it("refuses a page that fails validation and bad arguments before any request", async () => {
    const { f, seen } = fakeIndexer(() => Response.json(page({ chainId: 8453 })));
    const client = createExportClient({ baseUrl: "http://i", keyId: "k", secretBase64: secret().toString("base64"), fetch: f, now: () => NOW });
    await expect(client.pages(1, 100n)).rejects.toBeInstanceOf(PageRejected);
    const before = seen.length;
    await expect(client.pages(1, 100n, 501)).rejects.toThrow(RangeError);
    await expect(client.history(1, "0x12", null)).rejects.toThrow(/address/);
    await expect(client.poolHistory(1, A(3), 1n, 50_001n)).rejects.toThrow(RangeError);
    expect(seen.length).toBe(before);
  });
});
