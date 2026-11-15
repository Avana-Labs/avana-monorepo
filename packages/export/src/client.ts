// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A typed client for every endpoint of the indexer's private export (services/indexer/EXPORT.md). Each request is
// signed; 204 means "nothing new yet" and returns null; 503 (the indexer is still reindexing) throws
// `ExportUnavailable` so callers can show "unavailable" instead of an empty answer; any other non-2xx throws
// `ExportHttpError`. Every response is checked by the matching validator before it is returned.

import type { ExportPage, HistoryPage, PremiumRefreshList } from "@avana/services-common/export";
import { EXPORT_MAX_RECORDS, HISTORY_MAX_RECORDS } from "@avana/services-common/export";
import type { SeriesExportPage } from "@avana/services-common/series";
import { signRequest } from "./auth.ts";
import { type PoolHistoryPage, validateHistoryPage, validatePage, validatePoolHistory, validatePremiumRefresh, validateSeriesPage } from "./validate.ts";

export const SERIES_MAX_RECORDS = 2_000;
/** The widest block range one pool-history request may name. */
export const POOL_HISTORY_MAX_BLOCKS = 50_000n;

export class ExportHttpError extends Error {
  override readonly name: string = "ExportHttpError";
  constructor(
    readonly status: number,
    readonly path: string,
  ) {
    super(`export ${path} answered ${status}`);
  }
}

export class ExportUnavailable extends ExportHttpError {
  override readonly name: string = "ExportUnavailable";
}

export interface ExportClientOptions {
  readonly baseUrl: string;
  readonly keyId: string;
  readonly secretBase64: string;
  readonly fetch?: typeof fetch;
  /** Unix seconds; defaults to the wall clock. */
  readonly now?: () => number;
}

function limitIn(limit: number, max: number): number {
  if (!Number.isInteger(limit) || limit < 1 || limit > max) throw new RangeError(`limit is 1 to ${max}`);
  return limit;
}

function address(value: string, what: string): string {
  if (!/^0x[0-9a-fA-F]{40}$/.test(value)) throw new TypeError(`${what} is a 20-byte address`);
  return value.toLowerCase();
}

export function createExportClient(options: ExportClientOptions) {
  const base = options.baseUrl.replace(/\/$/, "");
  const doFetch = options.fetch ?? fetch;
  const now = options.now ?? (() => Math.floor(Date.now() / 1000));

  async function get<T>(pathAndQuery: string): Promise<T | null> {
    const headers = await signRequest(options.secretBase64, options.keyId, "GET", pathAndQuery, now());
    const res = await doFetch(`${base}${pathAndQuery}`, { headers });
    if (res.status === 204) return null;
    if (res.status === 503) throw new ExportUnavailable(res.status, pathAndQuery);
    if (!res.ok) throw new ExportHttpError(res.status, pathAndQuery);
    return (await res.json()) as T;
  }

  return {
    /** The next event page after `throughBlock` (null: from the start); null when no new block is servable. */
    async pages(chainId: number, throughBlock: bigint | null, limit = EXPORT_MAX_RECORDS): Promise<ExportPage | null> {
      const after = throughBlock === null ? "" : `&after=${throughBlock}`;
      const page = await get<ExportPage>(`/export/v1/pages?chainId=${chainId}${after}&limit=${limitIn(limit, EXPORT_MAX_RECORDS)}`);
      if (page) validatePage(page, chainId, throughBlock);
      return page;
    },

    /** Closed series buckets after `throughTime` (-1: from the start); null when none closed. */
    async series(chainId: number, throughTime: number, limit = SERIES_MAX_RECORDS): Promise<SeriesExportPage | null> {
      const after = throughTime >= 0 ? `&after=${throughTime}` : "";
      const page = await get<SeriesExportPage>(`/export/v1/series?chainId=${chainId}${after}&limit=${limitIn(limit, SERIES_MAX_RECORDS)}`);
      if (page) validateSeriesPage(page, chainId, throughTime);
      return page;
    },

    /** A wallet's records before `before` (null: the newest page), newest first. Throws ExportUnavailable while reindexing. */
    async history(chainId: number, wallet: string, before: bigint | null, limit = 100): Promise<HistoryPage> {
      const w = address(wallet, "wallet");
      const b = before === null ? "" : `&before=${before}`;
      const page = await get<HistoryPage>(`/export/v1/history?chainId=${chainId}&wallet=${w}${b}&limit=${limitIn(limit, HISTORY_MAX_RECORDS)}`);
      if (!page) throw new ExportHttpError(204, "/export/v1/history");
      validateHistoryPage(page, chainId, w, before);
      return page;
    },

    async poolHistory(chainId: number, pool: string, fromBlock: bigint, toBlock: bigint): Promise<PoolHistoryPage> {
      const p = address(pool, "pool");
      if (toBlock < fromBlock || toBlock - fromBlock + 1n > POOL_HISTORY_MAX_BLOCKS) throw new RangeError(`a pool-history range is 1 to ${POOL_HISTORY_MAX_BLOCKS} blocks`);
      const page = await get<PoolHistoryPage>(`/export/v1/pool-history?chainId=${chainId}&pool=${p}&fromBlock=${fromBlock}&toBlock=${toBlock}`);
      if (!page) throw new ExportHttpError(204, "/export/v1/pool-history");
      validatePoolHistory(page, chainId, p, fromBlock, toBlock);
      return page;
    },

    async premiumRefresh(chainId: number, spoke: string): Promise<PremiumRefreshList> {
      const s = address(spoke, "spoke");
      const list = await get<PremiumRefreshList>(`/export/v1/premium-refresh?chainId=${chainId}&spoke=${s}`);
      if (!list) throw new ExportHttpError(204, "/export/v1/premium-refresh");
      validatePremiumRefresh(list, chainId, s);
      return list;
    },
  };
}

export type ExportClient = ReturnType<typeof createExportClient>;
