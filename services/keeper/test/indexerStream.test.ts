// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The indexer stream from the keeper's side: requests are signed as the indexer verifies them, pages are followed until
// caught up, a 409 rewinds the cursor to the finalized block, a failure is reported once and the first success after
// it asks for an RPC backfill, and creation events add accounts that the one-sided check compares up to a common block.

import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import type { Address } from "viem";
import { type ExportRecord, KEEPER_STREAM_VERSION, type KeeperStreamPage, type ServiceManifest } from "@avana/services-common";
import { AccountCache } from "../src/discovery/accountCache.ts";
import { IndexerStream, applyStreamRecords, parseStreamKey, signedHeaders } from "../src/discovery/indexerStream.ts";

const SECRET = Buffer.alloc(32, 7);
const KEY = { id: "keeper-1", secret: SECRET };
const HASH = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as const;
const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const SPOKE = addr(0x5);
const VAULT = addr(0x7);
const manifest = { markets: [{ marketId: 3n, vaultToken: { address: VAULT } }] } as unknown as ServiceManifest;

function created(block: number, proxy: Address, marketId = 3): ExportRecord {
  return {
    key: `1:${HASH(block)}:0`,
    kind: "AaveAdapter.UserProxyCreated",
    blockNumber: String(block),
    blockHash: HASH(block),
    txHash: HASH(block),
    logIndex: 0,
    address: addr(0xad),
    args: { wallet: addr(0x99), spoke: SPOKE, marketId: String(marketId), proxy },
  };
}

function page(after: number | null, to: number, indexed: number, records: ExportRecord[]): KeeperStreamPage {
  return {
    version: KEEPER_STREAM_VERSION,
    chainId: 1,
    after: after === null ? null : { block: String(after), hash: HASH(after) },
    next: { block: String(to), hash: HASH(to) },
    fromBlock: String((after ?? -1) + 1),
    toBlock: String(to),
    records,
    indexedBlock: String(indexed),
    finalizedBlock: "0",
  };
}

/** A fake indexer answering from a queue; records the URLs and headers it was asked with. */
function fakeIndexer(answers: (() => { status: number; body?: unknown })[]) {
  const calls: { url: string; headers: Record<string, string> }[] = [];
  const fetchFn = async (url: string, init: { headers: Record<string, string> }) => {
    calls.push({ url, headers: init.headers });
    const next = answers.shift();
    if (!next) throw new Error("no answer queued");
    const a = next();
    return { status: a.status, json: async () => a.body };
  };
  return { calls, fetchFn };
}

describe("stream authentication", () => {
  it("signs exactly as the indexer's export check verifies", () => {
    const h = signedHeaders(KEY, "get", "/keeper/v1/events?chainId=1", 1_767_225_600);
    const expected = createHmac("sha256", SECRET).update("1767225600\nGET\n/keeper/v1/events?chainId=1").digest("hex");
    expect(h).toEqual({ "x-avana-key-id": "keeper-1", "x-avana-timestamp": "1767225600", "x-avana-signature": expected });
  });

  it("reads KEEPER_INDEXER_KEY as id:base64secret of at least 32 bytes", () => {
    expect(parseStreamKey(`k:${SECRET.toString("base64")}`)).toEqual({ id: "k", secret: SECRET });
    expect(() => parseStreamKey(`k:${Buffer.alloc(16).toString("base64")}`)).toThrow(/32 bytes/);
    expect(() => parseStreamKey("no-secret")).toThrow(/id:base64secret/);
  });
});

describe("polling", () => {
  it("follows pages with the hash-carrying cursor until caught up", async () => {
    const { calls, fetchFn } = fakeIndexer([
      () => ({ status: 200, body: page(null, 100, 150, [created(90, addr(0xa))]) }),
      () => ({ status: 200, body: page(100, 150, 150, [created(140, addr(0xb))]) }),
    ]);
    const s = new IndexerStream("http://indexer:42069", 1, KEY, fetchFn, () => 1_767_225_600);
    const r = await s.poll();
    expect(r).toMatchObject({ kind: "ok", caughtUp: true, reconnected: false });
    expect(r.records.map((x) => x.blockNumber)).toEqual(["90", "140"]);
    expect(s.cursor).toEqual({ block: "150", hash: HASH(150) });
    expect(s.indexedBlock).toBe(150n);
    expect(calls[0]!.url).toBe("http://indexer:42069/keeper/v1/events?chainId=1");
    expect(calls[1]!.url).toBe(`http://indexer:42069/keeper/v1/events?chainId=1&after=100&afterHash=${HASH(100)}`);
    // The signature covers the path and query actually requested.
    const expected = createHmac("sha256", SECRET).update(`1767225600\nGET\n/keeper/v1/events?chainId=1&after=100&afterHash=${HASH(100)}`).digest("hex");
    expect(calls[1]!.headers["x-avana-signature"]).toBe(expected);
  });

  it("stops at 204 and at the page cap", async () => {
    const quiet = fakeIndexer([() => ({ status: 204 })]);
    expect(await new IndexerStream("http://i", 1, KEY, quiet.fetchFn).poll()).toMatchObject({ kind: "ok", caughtUp: true, records: [] });
    const busy = fakeIndexer([() => ({ status: 200, body: page(null, 10, 99, []) }), () => ({ status: 200, body: page(10, 20, 99, []) })]);
    const s = new IndexerStream("http://i", 1, KEY, busy.fetchFn);
    expect(await s.poll(1)).toMatchObject({ kind: "ok", caughtUp: false });
    expect(s.cursor?.block).toBe("10");
  });

  it("rewinds to the finalized cursor on 409", async () => {
    const finalized = { block: "64", hash: HASH(64) };
    const { fetchFn } = fakeIndexer([
      () => ({ status: 200, body: page(null, 100, 120, [created(99, addr(0xa))]) }),
      () => ({ status: 409, body: { reorg: true, chainId: 1, finalized } }),
    ]);
    const s = new IndexerStream("http://i", 1, KEY, fetchFn);
    const r = await s.poll();
    expect(r).toMatchObject({ kind: "reorg", finalized });
    expect(r.records).toHaveLength(1);
    expect(s.cursor).toEqual(finalized);
  });

  it("reports a failure, keeps the cursor, and flags the next success as a reconnect", async () => {
    const { fetchFn } = fakeIndexer([
      () => ({ status: 200, body: page(null, 50, 50, []) }),
      () => ({ status: 503 }),
      () => ({ status: 204 }),
      () => ({ status: 204 }),
    ]);
    const s = new IndexerStream("http://i", 1, KEY, fetchFn);
    await s.poll();
    const failed = await s.poll();
    expect(failed).toMatchObject({ kind: "failed", error: "indexer stream answered HTTP 503" });
    expect(s.cursor?.block).toBe("50");
    expect(await s.poll()).toMatchObject({ kind: "ok", reconnected: true });
    expect(await s.poll()).toMatchObject({ kind: "ok", reconnected: false });
  });

  it("refuses a page of another version or chain", async () => {
    const other = fakeIndexer([() => ({ status: 200, body: { ...page(null, 1, 1, []), version: KEEPER_STREAM_VERSION + 1 } })]);
    expect(await new IndexerStream("http://i", 1, KEY, other.fetchFn).poll()).toMatchObject({ kind: "failed" });
    const chain = fakeIndexer([() => ({ status: 200, body: { ...page(null, 1, 1, []), chainId: 8453 } })]);
    expect(await new IndexerStream("http://i", 1, KEY, chain.fetchFn).poll()).toMatchObject({ kind: "failed" });
  });
});

describe("applying records", () => {
  it("adds accounts from creation events of manifest markets, as the indexer's", () => {
    const cache = new AccountCache();
    const applied = applyStreamRecords([created(10, addr(0xa)), created(11, addr(0xb), 99)], cache, manifest, 1);
    expect(applied.announced).toBe(1);
    const a = cache.get(1, SPOKE, addr(0xa))!;
    expect(a).toMatchObject({ marketId: 3n, vaultToken: VAULT, createdBlock: 10n, seenBy: { indexer: true, rpc: false } });
    expect(cache.get(1, SPOKE, addr(0xb))).toBeUndefined();
  });

  it("names what other kinds touched without changing the cache", () => {
    const cache = new AccountCache();
    const rec = (kind: string, args: Record<string, unknown>) => ({ ...created(5, addr(0xa)), kind, args });
    const applied = applyStreamRecords(
      [rec("AaveSpoke.Borrow", { user: addr(0xa).toUpperCase().replace("0X", "0x") }), rec("Collateralization.SeizureReconciled", {}), rec("LPVaultSwap.KeeperRemoved", {}), rec("LPOracle.PriceStateChanged", {})],
      cache,
      manifest,
      1,
    );
    expect([...applied.touched]).toEqual([addr(0xa)]);
    expect(applied).toMatchObject({ announced: 0, pending: true, status: true, market: true });
    expect(cache.ofChain(1)).toHaveLength(0);
  });

  it("reports one-sided accounts only up to the block both sources have read", () => {
    const cache = new AccountCache();
    applyStreamRecords([created(10, addr(0xa)), created(30, addr(0xc))], cache, manifest, 1);
    cache.upsert({ chainId: 1, spoke: SPOKE, proxy: addr(0xa), wallet: addr(0x99), marketId: 3n, vaultToken: VAULT, createdBlock: 10n }, "rpc");
    cache.upsert({ chainId: 1, spoke: SPOKE, proxy: addr(0xb), wallet: addr(0x99), marketId: 3n, vaultToken: VAULT, createdBlock: 12n }, "rpc");
    // Through block 20: B is RPC-only (reported); C was created after 20 and the RPC read has not reached it.
    expect(cache.oneSided(1, 20n).map((a) => a.proxy)).toEqual([addr(0xb)]);
    expect(cache.oneSided(1, 40n).map((a) => a.proxy).sort()).toEqual([addr(0xb), addr(0xc)]);
  });
});
