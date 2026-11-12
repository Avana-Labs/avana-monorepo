// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The import's checks: a page is applied only when it continues the checkpoint, stays within finality, keeps its
// records in order with their blocks' hashes, and hashes to its `pageHash`; requests are signed as the indexer
// verifies them; listing metadata loads only when its bytes hash to the operation's salt.

import { createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { keccak256, toBytes } from "viem";
import { EXPORT_SCHEMA_VERSION, type ExportPage, canonicalJson } from "@avana/services-common/export";
import { PageRejected, validatePage } from "../convex/lib/exportPage.ts";
import { signRequest } from "../convex/lib/hmac.ts";
import { MetadataRejected, metadataHash, parseMetadata } from "../convex/lib/metadata.ts";

const H = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as const;

function page(over: Partial<Omit<ExportPage, "pageHash">> = {}): ExportPage {
  const body = {
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
      { key: `1:${H(1)}:0`, kind: "AaveSpoke.Supply", blockNumber: "105", blockHash: H(105), txHash: H(1), logIndex: 0, address: "0x2222222222222222222222222222222222222222" as const, args: {} },
      { key: `1:${H(1)}:3`, kind: "AaveSpoke.Withdraw", blockNumber: "105", blockHash: H(105), txHash: H(1), logIndex: 3, address: "0x2222222222222222222222222222222222222222" as const, args: {} },
    ],
    finalizedBlock: "120",
    ...over,
  };
  return { ...body, pageHash: keccak256(toBytes(canonicalJson(body))) };
}

describe("export page checks", () => {
  it("accepts a page that continues the checkpoint", () => {
    expect(() => validatePage(page(), 1, 100n)).not.toThrow();
  });

  it("refuses a gap, an overlap, a page past finality or for another chain", () => {
    expect(() => validatePage(page(), 1, 99n)).toThrow(PageRejected);
    expect(() => validatePage(page({ finalizedBlock: "109" }), 1, 100n)).toThrow(/finalized/);
    expect(() => validatePage(page(), 8453, 100n)).toThrow(/chain/);
  });

  it("refuses records out of order or with another block hash", () => {
    const p = page();
    expect(() => validatePage(page({ records: [p.records[1]!, p.records[0]!] }), 1, 100n)).toThrow(/order/);
    expect(() => validatePage(page({ records: [{ ...p.records[0]!, blockHash: H(999) }] }), 1, 100n)).toThrow(/hash/);
  });

  it("refuses a tampered record whose page hash no longer matches", () => {
    const p = page();
    const tampered = { ...p, records: [{ ...p.records[0]!, args: { suppliedAmount: "1" } }, p.records[1]!] };
    expect(() => validatePage(tampered, 1, 100n)).toThrow(/page hash/);
  });
});

describe("request signing", () => {
  it("matches the HMAC the indexer verifies", async () => {
    const secret = Buffer.alloc(32, 7);
    const headers = await signRequest(secret.toString("base64"), "k1", "get", "/export/v1/pages?chainId=1&after=5&limit=500", 1_767_225_600);
    const expected = createHmac("sha256", secret).update("1767225600\nGET\n/export/v1/pages?chainId=1&after=5&limit=500").digest("hex");
    expect(headers).toEqual({ "x-avana-key-id": "k1", "x-avana-timestamp": "1767225600", "x-avana-signature": expected });
  });
});

describe("listing metadata", () => {
  const file = {
    version: 1,
    chainId: 1,
    entries: [
      { scope: "pool", key: "4", slug: "ethereum-usdc-usdt-001", name: "USDC/USDT 0.01%", description: "A stable pool.", stats: [], history: [], faqs: [{ question: "What is it?", answer: "A pool." }] },
      { scope: "lend", key: "0x1111111111111111111111111111111111111111:1", slug: "ethereum-usdc", name: "USDC", description: "", stats: [], history: [], faqs: [] },
    ],
  };
  const bytes = new TextEncoder().encode(JSON.stringify(file));

  it("loads a file whose bytes hash to the operation's salt", () => {
    expect(parseMetadata(bytes, metadataHash(bytes), 1).entries).toHaveLength(2);
  });

  it("refuses a file that differs from the committed hash by one byte", () => {
    const changed = new TextEncoder().encode(JSON.stringify(file).replace("A pool.", "A pool!"));
    expect(() => parseMetadata(changed, metadataHash(bytes), 1)).toThrow(MetadataRejected);
  });

  it("refuses a file for another chain, a duplicate slug or a key not in its on-chain form", () => {
    const check = (f: unknown) => {
      const b = new TextEncoder().encode(JSON.stringify(f));
      return () => parseMetadata(b, metadataHash(b), 1);
    };
    expect(check({ ...file, chainId: 8453 })).toThrow(/chain/);
    expect(check({ ...file, entries: [file.entries[0], file.entries[0]] })).toThrow(/repeated/);
    expect(check({ ...file, entries: [{ ...file.entries[1], key: "USDC" }] })).toThrow(/on-chain form/);
    expect(check({ ...file, entries: [{ ...file.entries[0], slug: "Bad Slug" }] })).toThrow(/slug/);
  });
});
