// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The private export contract between the indexer (producer) and Convex (consumer). services/indexer/EXPORT.md
// gives the rules; these types are the wire format. Amounts are decimal strings, never JavaScript numbers.

/** Bumped on any change to a record's fields; Convex refuses a page whose version it does not know. */
export const EXPORT_SCHEMA_VERSION = 1;

/** At most this many records per page; a page still never splits a block (EXPORT.md, "Pages"). */
export const EXPORT_MAX_RECORDS = 500;

export type DecimalString = string;
export type HexString = `0x${string}`;

/**
 * A page always covers whole blocks, so the cursor is the last block fully served: the next page starts at
 * `throughBlock + 1`. A block with more records than the page limit is served whole in one page.
 */
export interface ExportCursor {
  readonly throughBlock: DecimalString;
}

export interface ExportBlock {
  readonly number: DecimalString;
  readonly hash: HexString;
  readonly timestamp: DecimalString;
}

/** One indexed log, normalised. `kind` is `<Contract>.<Event>` as listed in services/indexer/EVENTS.md. */
export interface ExportRecord {
  /** `chainId:txHash:logIndex`, unique across chains; Convex's duplicate check keys on it. */
  readonly key: string;
  readonly kind: string;
  readonly blockNumber: DecimalString;
  readonly blockHash: HexString;
  readonly txHash: HexString;
  readonly logIndex: number;
  readonly address: HexString;
  /** Decoded event arguments; uint/int values as decimal strings, addresses lower-case. */
  readonly args: Readonly<Record<string, unknown>>;
}

export interface ExportPage {
  readonly schemaVersion: number;
  readonly chainId: number;
  /** The cursor the request named; null for the first page. */
  readonly after: ExportCursor | null;
  /** The cursor for the next page: `{ throughBlock: toBlock }`. */
  readonly next: ExportCursor;
  /** Inclusive block range the page covers; every indexed log of every block in it is in this page. */
  readonly fromBlock: DecimalString;
  readonly toBlock: DecimalString;
  /** Hash of `toBlock` as the indexer saw it; Convex re-reads it over its own RPC before applying the page. */
  readonly toBlockHash: HexString;
  /** Every block that holds a record, plus `toBlock`. */
  readonly blocks: readonly ExportBlock[];
  readonly records: readonly ExportRecord[];
  /** The chain's finalized block at serving time; `toBlock` never exceeds it. */
  readonly finalizedBlock: DecimalString;
  /** keccak256 of the canonical JSON of every field above; the page's identity for duplicate detection. */
  readonly pageHash: HexString;
}

/** JSON with object keys sorted at every level, so producer and consumer hash the same bytes (`pageHash`). */
export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value !== null && typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

/** At most this many records per history page (`/export/v1/history`); a page still never splits a block. */
export const HISTORY_MAX_RECORDS = 500;

/**
 * Older activity of one wallet (EXPORT.md, "Older history"): the records naming the wallet or one of its attributed
 * proxies, newest first, from blocks before `before` and no later than the export's servable block. Shown, not stored.
 */
export interface HistoryPage {
  readonly schemaVersion: number;
  readonly chainId: number;
  readonly wallet: HexString;
  /** The wallet's attributed proxies on the chain (both creation events seen), lower-case. */
  readonly proxies: readonly HexString[];
  /** The exclusive upper block the request named, or the servable block + 1 when it named none. */
  readonly before: DecimalString;
  readonly records: readonly ExportRecord[];
  /** `before` of the next (older) page; null when no older record exists. */
  readonly next: { readonly before: DecimalString } | null;
}
