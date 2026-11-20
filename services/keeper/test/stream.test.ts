// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot stream client: signed requests, paging to the indexed head, a reorg rewinding to the finalized cursor, a
// failure returned instead of thrown, and the accounts AccountCreated records announce per AaveAdapter.

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { createHmac, randomBytes } from "node:crypto";
import { KEEPER_STREAM_VERSION, type ExportRecord } from "@avana/services-common";
import { IndexerStream, accountsFromRecords, readStreamKey, signedHeaders } from "../src/stream.ts";

const key = { id: "bots", secret: randomBytes(32) };
const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as const;
const record = (kind: string, address: string, args: Record<string, unknown>): ExportRecord => ({ key: "k", kind, blockNumber: "10", blockHash: H(1), txHash: H(2), logIndex: 0, address: address as `0x${string}`, args });

describe("stream key and signature", () => {
  it("reads id:base64secret from a file and refuses a short secret", () => {
    const dir = mkdtempSync(join(tmpdir(), "keeper-key-"));
    writeFileSync(join(dir, "ok"), `bots:${key.secret.toString("base64")}\n`);
    writeFileSync(join(dir, "short"), `bots:${randomBytes(8).toString("base64")}`);
    expect(readStreamKey(join(dir, "ok")).id).toBe("bots");
    expect(() => readStreamKey(join(dir, "short"))).toThrow(/32 bytes/);
  });

  it("signs timestamp, method and path with the key", () => {
    const h = signedHeaders(key, "get", "/keeper/v1/events?chainId=1", 100);
    expect(h["x-avana-signature"]).toBe(createHmac("sha256", key.secret).update("100\nGET\n/keeper/v1/events?chainId=1").digest("hex"));
  });
});

describe("IndexerStream", () => {
  const page = (from: number, to: number, indexed: number, records: ExportRecord[] = []) => ({
    version: KEEPER_STREAM_VERSION,
    chainId: 1,
    after: null,
    next: { block: String(to), hash: H(to) },
    fromBlock: String(from),
    toBlock: String(to),
    records,
    indexedBlock: String(indexed),
    finalizedBlock: "0",
  });

  it("reads pages to the indexed head, then continues after the cursor", async () => {
    const urls: string[] = [];
    const answers = [{ status: 200, body: page(1, 5, 9) }, { status: 200, body: page(6, 9, 9, [record("AaveAdapter.AccountCreated", "0xAA", { account: "0xbb", marketId: "7" })]) }, { status: 204 }];
    const s = new IndexerStream("http://indexer:42069", 1, key, async (url) => {
      urls.push(url);
      const a = answers.shift()!;
      return { status: a.status, json: async () => a.body };
    });
    const r = await s.poll();
    expect(r).toMatchObject({ kind: "ok", caughtUp: true });
    expect(r.records).toHaveLength(1);
    await s.poll();
    expect(urls[2]).toContain("after=9");
  });

  it("rewinds to the finalized cursor on a reorg and returns a failure instead of throwing", async () => {
    const s = new IndexerStream("http://i", 1, key, async () => ({ status: 409, json: async () => ({ reorg: true, chainId: 1, finalized: { block: "3", hash: H(3) } }) }));
    expect((await s.poll()).kind).toBe("reorg");
    expect(s.cursor).toEqual({ block: "3", hash: H(3) });
    const down = new IndexerStream("http://i", 1, key, async () => ({ status: 500, json: async () => ({}) }));
    expect(await down.poll()).toMatchObject({ kind: "failed", error: "indexer stream answered HTTP 500" });
  });

  it("refuses a page of another stream version or chain", async () => {
    const other = new IndexerStream("http://i", 1, key, async () => ({ status: 200, json: async () => ({ ...page(1, 1, 1), version: KEEPER_STREAM_VERSION + 1 }) }));
    expect((await other.poll()).kind).toBe("failed");
  });
});

describe("accountsFromRecords", () => {
  it("groups the announced accounts by AaveAdapter and ignores other kinds", () => {
    const m = accountsFromRecords([
      record("AaveAdapter.AccountCreated", "0xAA01", { wallet: "0x1", marketId: "7", account: "0xc1" }),
      record("AaveAdapter.AccountCreated", "0xaa01", { wallet: "0x2", marketId: "8", account: "0xc2" }),
      record("AaveAdapter.Borrowed", "0xaa01", { wallet: "0x1" }),
    ]);
    expect([...m]).toEqual([["0xaa01", [{ account: "0xc1", marketId: 7n }, { account: "0xc2", marketId: 8n }]]]);
  });
});
