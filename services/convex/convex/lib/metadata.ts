// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The listing metadata file: names, slugs, descriptions, FAQs and long text of the pages a listing adds. The
// governance listing operation commits to it: the operation's timelock salt is keccak256 of the file's exact bytes.
// When the operation executes, Convex fetches the file by that hash, checks the hash and loads it; a file whose hash
// differs from the salt is refused, so only the content governance scheduled reaches the app.
//
// Version 2 adds, per entry, the project links (website, X, docs, GitHub, audits) and the risk text of the page's
// risk card (a summary and rated factors), bounds the FAQs, and requires a Lend entry to name its symbol and
// category. Version 1 files stay valid; a version 1 entry that carries a version 2 field is refused.
// Version 2 risk text may also carry the review day, a bps share per factor and the contracts the market relies on;
// a Hub entry may carry the risk disclosures of its Borrow and Lend pages; a token entry names its symbol.

import { keccak256 } from "viem";
import type { Category, PageContent, PageDisclosures, PageLinks, PageRisk, RiskDependency, RiskLevel } from "./uiTypes.ts";

export const METADATA_VERSION = 2;
export const METADATA_VERSIONS: readonly number[] = [1, 2];
export const MAX_FAQS = 30;
export const MAX_RISK_FACTORS = 12;
export const MAX_RISK_DEPENDENCIES = 64;

export type MetadataScope = "lend" | "asset" | "pool" | "spoke" | "token" | "hub";

/** One page's content and its on-chain key. */
export interface MetadataEntry extends PageContent {
  readonly scope: MetadataScope;
  /** lend: `hub:assetId`; asset: `spoke:reserveId`; pool: `marketId`; spoke, token and hub: the address. */
  readonly key: string;
}

export interface MetadataFile {
  readonly version: number;
  readonly chainId: number;
  readonly entries: readonly MetadataEntry[];
}

export class MetadataRejected extends Error {}

const SCOPES: readonly MetadataScope[] = ["lend", "asset", "pool", "spoke", "token", "hub"];
const CATEGORIES: readonly Category[] = ["stable", "crypto", "stock"];
const LEVELS: readonly RiskLevel[] = ["low", "moderate", "elevated", "high"];
const DEPENDENCY_KINDS: readonly RiskDependency["kind"][] = ["amm", "oracle", "hub", "spoke"];
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const LINK_KEYS = ["website", "x", "docs", "github"] as const;
const HTTPS = /^https:\/\/[^\s/?#]+(\/[^\s]*)?$/;
const X_PROFILE = /^https:\/\/(www\.)?(x|twitter)\.com\/[A-Za-z0-9_]{1,15}\/?$/;
const ID = /^[a-z][a-zA-Z0-9]{0,47}$/;
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
const https = (x: unknown): x is string => typeof x === "string" && x.length <= 500 && HTTPS.test(x);

function checkLinks(where: string, raw: unknown): PageLinks {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new MetadataRejected(`${where}: links must be an object`);
  const l = raw as Record<string, unknown>;
  for (const k of Object.keys(l)) if (![...LINK_KEYS, "audits"].includes(k)) throw new MetadataRejected(`${where}: unknown link ${k}`);
  for (const k of LINK_KEYS) if (l[k] !== undefined && !https(l[k])) throw new MetadataRejected(`${where}: link ${k} must be an https URL`);
  if (l.x !== undefined && !X_PROFILE.test(l.x as string)) throw new MetadataRejected(`${where}: link x must be an x.com or twitter.com profile`);
  if (l.audits !== undefined && (!list(l.audits) || l.audits.length > 20 || l.audits.some((a) => !str(a.label, 128) || !https(a.href)))) {
    throw new MetadataRejected(`${where}: audits are up to 20 { label, https href }`);
  }
  return l as PageLinks;
}

function checkRisk(where: string, raw: unknown): PageRisk {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new MetadataRejected(`${where}: risk must be an object`);
  const r = raw as Record<string, unknown>;
  if (!str(r.summary, 2_000)) throw new MetadataRejected(`${where}: risk summary missing or longer than 2,000`);
  if (!list(r.factors) || r.factors.length > MAX_RISK_FACTORS) throw new MetadataRejected(`${where}: risk factors are a list of up to ${MAX_RISK_FACTORS}`);
  const ids = new Set<string>();
  for (const x of r.factors) {
    if (typeof x.id !== "string" || !ID.test(x.id) || ids.has(x.id)) throw new MetadataRejected(`${where}: each risk factor needs a unique camelCase id`);
    ids.add(x.id);
    if (!str(x.label, 128) || !str(x.text, 1_000) || !LEVELS.includes(x.level as RiskLevel)) throw new MetadataRejected(`${where}: risk factor ${x.id} needs a label, a level and text up to 1,000`);
    if (x.bps !== undefined && !(Number.isInteger(x.bps) && (x.bps as number) >= 0 && (x.bps as number) <= 10_000)) throw new MetadataRejected(`${where}: risk factor ${x.id} bps must be a whole number from 0 to 10,000`);
  }
  if (r.reviewedAt !== undefined && !(typeof r.reviewedAt === "string" && DAY.test(r.reviewedAt) && !Number.isNaN(Date.parse(`${r.reviewedAt}T00:00:00Z`)) && new Date(`${r.reviewedAt}T00:00:00Z`).toISOString().startsWith(r.reviewedAt))) {
    throw new MetadataRejected(`${where}: risk reviewedAt must be a YYYY-MM-DD day`);
  }
  if (r.dependencies !== undefined) {
    if (!list(r.dependencies) || r.dependencies.length > MAX_RISK_DEPENDENCIES) throw new MetadataRejected(`${where}: risk dependencies are a list of up to ${MAX_RISK_DEPENDENCIES}`);
    for (const d of r.dependencies) {
      if (!DEPENDENCY_KINDS.includes(d.kind as RiskDependency["kind"]) || !str(d.label, 128) || typeof d.address !== "string" || !ADDRESS.test(d.address)) {
        throw new MetadataRejected(`${where}: each risk dependency needs a kind (${DEPENDENCY_KINDS.join(", ")}), a label and a lower-case address`);
      }
    }
  }
  return r as unknown as PageRisk;
}

function checkDisclosures(where: string, raw: unknown): PageDisclosures {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) throw new MetadataRejected(`${where}: disclosures must be an object`);
  const d = raw as Record<string, unknown>;
  for (const k of Object.keys(d)) if (k !== "borrow" && k !== "lend") throw new MetadataRejected(`${where}: unknown disclosure ${k}`);
  for (const k of ["borrow", "lend"] as const) if (d[k] !== undefined && !str(d[k], 4_000)) throw new MetadataRejected(`${where}: disclosure ${k} must be text up to 4,000`);
  return d as PageDisclosures;
}

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
  if (!METADATA_VERSIONS.includes(file.version as number)) throw new MetadataRejected(`version ${String(file.version)} is not one of ${METADATA_VERSIONS.join(", ")}`);
  const v2 = file.version === 2;
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
    if (!v2) {
      if (e.links !== undefined || e.risk !== undefined || e.disclosures !== undefined) throw new MetadataRejected(`${where}: links, risk and disclosures need version 2`);
      continue;
    }
    if ((e.faqs as readonly unknown[]).length > MAX_FAQS) throw new MetadataRejected(`${where}: at most ${MAX_FAQS} FAQs`);
    if (e.scope === "lend" && (!str(e.symbol, 32) || e.category === undefined)) throw new MetadataRejected(`${where}: a Lend entry names its symbol and category`);
    if (e.links !== undefined) checkLinks(where, e.links);
    if (e.scope === "token" && !str(e.symbol, 32)) throw new MetadataRejected(`${where}: a token entry names its symbol`);
    if (e.risk !== undefined) checkRisk(where, e.risk);
    if (e.disclosures !== undefined) {
      if (e.scope !== "hub") throw new MetadataRejected(`${where}: only a Hub entry carries disclosures`);
      checkDisclosures(where, e.disclosures);
    }
  }
  return file as MetadataFile;
}
