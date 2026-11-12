// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The listing metadata file: names, slugs, descriptions, FAQs and long text of the pages a listing adds. The
// governance listing operation commits to it: the operation's timelock salt is keccak256 of the file's exact bytes.
// When the operation executes, Convex fetches the file by that hash, checks the hash and loads it; a file whose hash
// differs from the salt is refused, so only the content governance scheduled reaches the app.

import { keccak256 } from "viem";
import type { Category, PageContent } from "./uiTypes.ts";

export const METADATA_VERSION = 1;

export type MetadataScope = "lend" | "asset" | "pool" | "spoke" | "token";

/** One page's content and its on-chain key. */
export interface MetadataEntry extends PageContent {
  readonly scope: MetadataScope;
  /** lend: `hub:assetId`; asset: `spoke:reserveId`; pool: `marketId`; spoke and token: the address. */
  readonly key: string;
}

export interface MetadataFile {
  readonly version: number;
  readonly chainId: number;
  readonly entries: readonly MetadataEntry[];
}

export class MetadataRejected extends Error {}

const SCOPES: readonly MetadataScope[] = ["lend", "asset", "pool", "spoke", "token"];
const CATEGORIES: readonly Category[] = ["stable", "crypto", "stock"];
const ADDRESS = /^0x[0-9a-f]{40}$/;
const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;

function keyValid(scope: MetadataScope, key: string): boolean {
  switch (scope) {
    case "lend":
      return /^0x[0-9a-f]{40}:\d+$/.test(key);
    case "asset":
      return /^0x[0-9a-f]{40}:\d+$/.test(key);
    case "pool":
      return /^\d+$/.test(key);
    default:
      return ADDRESS.test(key);
  }
}

const str = (x: unknown, max: number): x is string => typeof x === "string" && x.length > 0 && x.length <= max;
const list = (x: unknown): x is readonly Record<string, unknown>[] => Array.isArray(x) && x.every((i) => i !== null && typeof i === "object");

/** keccak256 of the file's bytes, the value the listing operation's salt must equal. */
export function metadataHash(bytes: Uint8Array): `0x${string}` {
  return keccak256(bytes);
}

/**
 * Checks the bytes against the committed hash, then the structure: known scopes, keys in their on-chain form,
 * lower-case slugs unique per scope, bounded text. Throws `MetadataRejected` with the first problem found.
 */
export function parseMetadata(bytes: Uint8Array, committedHash: string, chainId: number): MetadataFile {
  const hash = metadataHash(bytes);
  if (hash !== committedHash.toLowerCase()) throw new MetadataRejected(`file hash ${hash} differs from the operation's ${committedHash}`);
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new MetadataRejected("file is not UTF-8 JSON");
  }
  const file = raw as Partial<MetadataFile>;
  if (file.version !== METADATA_VERSION) throw new MetadataRejected(`version ${String(file.version)} is not ${METADATA_VERSION}`);
  if (file.chainId !== chainId) throw new MetadataRejected(`file is for chain ${String(file.chainId)}, the operation ran on ${chainId}`);
  if (!list(file.entries) || file.entries.length === 0) throw new MetadataRejected("entries must be a non-empty list");
  const seen = new Set<string>();
  for (const [i, e] of (file.entries as readonly Record<string, unknown>[]).entries()) {
    const where = `entry ${i}`;
    if (!SCOPES.includes(e.scope as MetadataScope)) throw new MetadataRejected(`${where}: unknown scope`);
    if (typeof e.key !== "string" || !keyValid(e.scope as MetadataScope, e.key)) throw new MetadataRejected(`${where}: key is not in its on-chain form`);
    if (!str(e.slug, 96) || !SLUG.test(e.slug)) throw new MetadataRejected(`${where}: slug must be lower-case words joined by "-"`);
    const id = `${String(e.scope)}:${e.slug}`;
    if (seen.has(id)) throw new MetadataRejected(`${where}: slug ${e.slug} repeated`);
    seen.add(id);
    if (!str(e.name, 128)) throw new MetadataRejected(`${where}: name missing or longer than 128`);
    if (typeof e.description !== "string" || e.description.length > 4_000) throw new MetadataRejected(`${where}: description missing or longer than 4,000`);
    if (e.longText !== undefined && (typeof e.longText !== "string" || e.longText.length > 50_000)) throw new MetadataRejected(`${where}: longText longer than 50,000`);
    if (e.category !== undefined && !CATEGORIES.includes(e.category as Category)) throw new MetadataRejected(`${where}: unknown category`);
    for (const field of ["stats", "history", "faqs"] as const) if (!list(e[field])) throw new MetadataRejected(`${where}: ${field} must be a list`);
    if ((e.faqs as readonly Record<string, unknown>[]).some((f) => !str(f.question, 500) || !str(f.answer, 5_000))) throw new MetadataRejected(`${where}: every FAQ needs a question and an answer`);
    if (e.iconUrl !== undefined && (typeof e.iconUrl !== "string" || !e.iconUrl.startsWith("https://"))) throw new MetadataRejected(`${where}: iconUrl must be https`);
  }
  return file as MetadataFile;
}
