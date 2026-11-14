// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The indexer stream (services/indexer/EXPORT.md, "Keeper stream"): pages of the events the keeper follows, at the
// chain head, after a cursor that carries its block hash. Creation events add accounts to the cache; the other kinds
// only say what changed, because every decision re-reads the chain at a pinned block anyway. A failed request, or a
// 409 after a reorg, tells the caller to re-read RPC logs from the finalized block before new heads are processed.

import { createHmac } from "node:crypto";
import type { Address } from "viem";
import {
  KEEPER_ACCOUNT_KINDS,
  KEEPER_PENDING_KINDS,
  KEEPER_STATUS_KINDS,
  KEEPER_STREAM_VERSION,
  type ExportRecord,
  type KeeperStreamCursor,
  type KeeperStreamPage,
  type KeeperStreamReorg,
  type ServiceManifest,
} from "@avana/services-common";
import type { AccountCache } from "./accountCache.ts";

/** A request that has not answered within this time counts as a failed stream; the block pass never waits longer. */
export const STREAM_TIMEOUT_MS = 2_000;
/** Pages read per head once caught up; the startup read has no cap. */
export const PAGES_PER_HEAD = 20;

export interface StreamKey {
  readonly id: string;
  readonly secret: Buffer;
}

/** Reads `KEEPER_INDEXER_KEY` (`id:base64secret`, at least 32 bytes), the keeper's entry in `INDEXER_EXPORT_KEYS`. */
export function parseStreamKey(raw: string): StreamKey {
  const [id, secret] = raw.split(":");
  if (!id || !secret) throw new Error("KEEPER_INDEXER_KEY must be id:base64secret");
  const bytes = Buffer.from(secret, "base64");
  if (bytes.length < 32) throw new Error("KEEPER_INDEXER_KEY secret is shorter than 32 bytes");
  return { id, secret: bytes };
}

/** The indexer's request authentication: hex(HMAC-SHA256(secret, timestamp + "\n" + METHOD + "\n" + path?query)). */
export function signedHeaders(key: StreamKey, method: string, pathWithQuery: string, nowSeconds: number): Record<string, string> {
  const timestamp = String(nowSeconds);
  const signature = createHmac("sha256", key.secret).update(`${timestamp}\n${method.toUpperCase()}\n${pathWithQuery}`).digest("hex");
  return { "x-avana-key-id": key.id, "x-avana-timestamp": timestamp, "x-avana-signature": signature };
}

export type PollResult =
  /** Pages applied; `reconnected` is true on the first success after a failure, which calls for an RPC backfill. */
  | { readonly kind: "ok"; readonly records: readonly ExportRecord[]; readonly caughtUp: boolean; readonly reconnected: boolean }
  /** The cursor left the canonical chain; the stream now continues from `finalized`. */
  | { readonly kind: "reorg"; readonly records: readonly ExportRecord[]; readonly finalized: KeeperStreamCursor }
  | { readonly kind: "failed"; readonly records: readonly ExportRecord[]; readonly error: string };

type Fetch = (url: string, init: { headers: Record<string, string>; signal: AbortSignal }) => Promise<{ status: number; json(): Promise<unknown> }>;

export class IndexerStream {
  cursor: KeeperStreamCursor | null = null;
  /** The last block the indexer reported fully handled; the one-sided account check compares up to it. */
  indexedBlock: bigint = -1n;
  private failing = false;

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
    const res = await this.fetchFn(new URL(path, this.baseUrl).toString(), {
      headers: signedHeaders(this.key, "GET", path, this.now()),
      signal: AbortSignal.timeout(STREAM_TIMEOUT_MS),
    });
    if (res.status === 204) return { status: 204 };
    if (res.status === 409) return { status: 409, body: (await res.json()) as KeeperStreamReorg };
    if (res.status !== 200) throw new Error(`indexer stream answered HTTP ${res.status}`);
    const body = (await res.json()) as KeeperStreamPage;
    if (body.version !== KEEPER_STREAM_VERSION) throw new Error(`indexer stream version ${body.version}, keeper reads ${KEEPER_STREAM_VERSION}`);
    if (body.chainId !== this.chainId) throw new Error(`indexer stream served chain ${body.chainId} for ${this.chainId}`);
    return { status: 200, body };
  }

  /** Reads pages until caught up, a reorg, a failure or `maxPages`. Records read before a failure are still returned. */
  async poll(maxPages = PAGES_PER_HEAD): Promise<PollResult> {
    const records: ExportRecord[] = [];
    let caughtUp = false;
    try {
      for (let i = 0; i < maxPages; i++) {
        const r = await this.page();
        if (r.status === 204) {
          caughtUp = true;
          break;
        }
        if (r.status === 409) {
          this.cursor = r.body.finalized;
          return { kind: "reorg", records, finalized: r.body.finalized };
        }
        records.push(...r.body.records);
        this.cursor = r.body.next;
        this.indexedBlock = BigInt(r.body.indexedBlock);
        if (BigInt(r.body.toBlock) >= this.indexedBlock) {
          caughtUp = true;
          break;
        }
      }
    } catch (err) {
      this.failing = true;
      return { kind: "failed", records, error: err instanceof Error ? err.message : String(err) };
    }
    const reconnected = this.failing;
    this.failing = false;
    return { kind: "ok", records, caughtUp, reconnected };
  }
}

const CREATION = new Set<string>(["AaveAdapter.UserProxyCreated", "ProxyManager.ProxyDeployed"]);
const ACCOUNT = new Set<string>(KEEPER_ACCOUNT_KINDS);
const PENDING = new Set<string>(KEEPER_PENDING_KINDS);
const STATUS = new Set<string>(KEEPER_STATUS_KINDS);

export interface Applied {
  /** Accounts added or confirmed by a creation event. */
  readonly announced: number;
  /** Other account events: the proxies they name (already re-read every block; logged for the record). */
  readonly touched: ReadonlySet<string>;
  readonly pending: boolean;
  readonly status: boolean;
  readonly market: boolean;
}

/**
 * Applies streamed records to the cache. A creation event of a market missing from the manifest is ignored, as in
 * the RPC backfill. Values in the records never decide anything; they only add accounts and name what changed.
 */
export function applyStreamRecords(records: readonly ExportRecord[], cache: AccountCache, manifest: ServiceManifest, chainId: number): Applied {
  let announced = 0;
  const touched = new Set<string>();
  let pending = false;
  let status = false;
  let market = false;
  for (const r of records) {
    if (CREATION.has(r.kind)) {
      const a = r.args as { wallet: Address; spoke: Address; marketId: string; proxy: Address };
      const marketId = BigInt(a.marketId);
      const m = manifest.markets.find((x) => x.marketId === marketId);
      if (!m) continue;
      cache.upsert({ chainId, spoke: a.spoke, proxy: a.proxy, wallet: a.wallet, marketId, vaultToken: m.vaultToken.address, createdBlock: BigInt(r.blockNumber) }, "indexer");
      announced++;
    } else if (ACCOUNT.has(r.kind)) {
      const user = (r.args.user ?? r.args.proxy ?? r.args.onBehalfOf) as string | undefined;
      if (user) touched.add(user.toLowerCase());
    } else if (PENDING.has(r.kind)) pending = true;
    else if (STATUS.has(r.kind)) status = true;
    else market = true;
  }
  return { announced, touched, pending, status, market };
}
