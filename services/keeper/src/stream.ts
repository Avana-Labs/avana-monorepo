// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot stream from the indexer (services/indexer/EXPORT.md, "Keeper stream"): pages of the account events the bots
// follow, at the chain head, after a cursor that carries its block hash. `AaveAdapter.AccountCreated` adds an account
// (one proxy per wallet and market) to the AaveAdapter's set; the other kinds never decide anything, since the
// LiquidationBot re-reads every health factor on chain. A failed request or a 409 after a reorg leaves the set as it
// is, and the runner falls back to its own RPC scan of `AccountCreated` until the stream answers again.

import { createHmac } from "node:crypto";
import { readFileSync } from "node:fs";
import type { Address } from "viem";
import { KEEPER_STREAM_VERSION, type ExportRecord, type KeeperStreamCursor, type KeeperStreamPage, type KeeperStreamReorg } from "@avana/services-common";

/** A request that has not answered within this time counts as a failed stream. */
export const STREAM_TIMEOUT_MS = 2_000;
/** Pages read per pass once caught up; the first read has no cap. */
export const PAGES_PER_PASS = 20;

export interface StreamKey {
  readonly id: string;
  readonly secret: Buffer;
}

/** Reads the key file (`id:base64secret`, at least 32 bytes): the bot runner's entry in the indexer's `INDEXER_EXPORT_KEYS`. */
export function readStreamKey(path: string): StreamKey {
  const [id, secret] = readFileSync(path, "utf8").trim().split(":");
  if (!id || !secret) throw new Error("KEEPER_INDEXER_KEY_FILE must hold id:base64secret");
  const bytes = Buffer.from(secret, "base64");
  if (bytes.length < 32) throw new Error("KEEPER_INDEXER_KEY_FILE secret is shorter than 32 bytes");
  return { id, secret: bytes };
}

/** The indexer's request authentication: hex(HMAC-SHA256(secret, timestamp + "\n" + METHOD + "\n" + path?query)). */
export function signedHeaders(key: StreamKey, method: string, pathWithQuery: string, nowSeconds: number): Record<string, string> {
  const timestamp = String(nowSeconds);
  const signature = createHmac("sha256", key.secret).update(`${timestamp}\n${method.toUpperCase()}\n${pathWithQuery}`).digest("hex");
  return { "x-avana-key-id": key.id, "x-avana-timestamp": timestamp, "x-avana-signature": signature };
}

export type PollResult =
  | { readonly kind: "ok"; readonly records: readonly ExportRecord[]; readonly caughtUp: boolean }
  /** The cursor left the canonical chain; the stream continues from `finalized`. */
  | { readonly kind: "reorg"; readonly records: readonly ExportRecord[] }
  | { readonly kind: "failed"; readonly records: readonly ExportRecord[]; readonly error: string };

type Fetch = (url: string, init: { headers: Record<string, string>; signal: AbortSignal }) => Promise<{ status: number; json(): Promise<unknown> }>;

export class IndexerStream {
  cursor: KeeperStreamCursor | null = null;

  constructor(
    private readonly baseUrl: string,
    private readonly chainId: number,
    private readonly key: StreamKey,
    private readonly fetchFn: Fetch = fetch as unknown as Fetch,
    private readonly now: () => number = () => Math.floor(Date.now() / 1000),
  ) {}

  private async page(): Promise<{ status: 200; body: KeeperStreamPage } | { status: 204 } | { status: 409; body: KeeperStreamReorg }> {
    const q = new URLSearchParams({ chainId: String(this.chainId) });
    if (this.cursor) {
      q.set("after", this.cursor.block);
      q.set("afterHash", this.cursor.hash);
    }
    const path = `/keeper/v1/events?${q.toString()}`;
    const res = await this.fetchFn(new URL(path, this.baseUrl).toString(), { headers: signedHeaders(this.key, "GET", path, this.now()), signal: AbortSignal.timeout(STREAM_TIMEOUT_MS) });
    if (res.status === 204) return { status: 204 };
    if (res.status === 409) return { status: 409, body: (await res.json()) as KeeperStreamReorg };
    if (res.status !== 200) throw new Error(`indexer stream answered HTTP ${res.status}`);
    const body = (await res.json()) as KeeperStreamPage;
    if (body.version !== KEEPER_STREAM_VERSION) throw new Error(`indexer stream version ${body.version}, the bot runner reads ${KEEPER_STREAM_VERSION}`);
    if (body.chainId !== this.chainId) throw new Error(`indexer stream served chain ${body.chainId} for ${this.chainId}`);
    return { status: 200, body };
  }

  /** Reads pages until caught up, a reorg, a failure or `maxPages`. Records read before a failure are still returned. */
  async poll(maxPages = PAGES_PER_PASS): Promise<PollResult> {
    const records: ExportRecord[] = [];
    try {
      for (let i = 0; i < maxPages; i++) {
        const r = await this.page();
        if (r.status === 204) return { kind: "ok", records, caughtUp: true };
        if (r.status === 409) {
          this.cursor = r.body.finalized;
          return { kind: "reorg", records };
        }
        records.push(...r.body.records);
        this.cursor = r.body.next;
        if (BigInt(r.body.toBlock) >= BigInt(r.body.indexedBlock)) return { kind: "ok", records, caughtUp: true };
      }
      return { kind: "ok", records, caughtUp: false };
    } catch (err) {
      return { kind: "failed", records, error: err instanceof Error ? err.message : String(err) };
    }
  }
}

/** The accounts `AaveAdapter.AccountCreated` records announce, by the AaveAdapter that deployed them (lower-case). */
export function accountsFromRecords(records: readonly ExportRecord[]): Map<string, { account: Address; marketId: bigint }[]> {
  const out = new Map<string, { account: Address; marketId: bigint }[]>();
  for (const r of records) {
    if (r.kind !== "AaveAdapter.AccountCreated") continue;
    const a = r.args as { account: Address; marketId: string };
    const adapter = r.address.toLowerCase();
    out.set(adapter, [...(out.get(adapter) ?? []), { account: a.account, marketId: BigInt(a.marketId) }]);
  }
  return out;
}
