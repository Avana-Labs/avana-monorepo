// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A page is sent only after the rows it was judged from read the same on a second RPC provider at the same block
// (services/README.md: "re-checked against a second RPC source before paging"). A page the second provider reads
// differently goes out as a warn with a note, because two providers disagreeing is itself a fault to look at.

import type { ChainSnapshot } from "@avana/services-common/views";
import type { Finding } from "./types.ts";

/** The snapshot rows a finding's subject was judged from, as text; null for a subject no row backs. */
export function rowsFor(snap: ChainSnapshot, subject: string): string | null {
  const [kind, ...rest] = subject.split(":");
  let rows: readonly unknown[];
  switch (kind) {
    case "market":
      rows = snap.markets.filter((m) => m.marketId === rest[0]);
      break;
    case "reserve":
      rows = snap.spokeReserves.filter((r) => r.spoke === rest[0] && r.reserveId === rest[1]);
      break;
    case "hubAsset":
      rows = snap.hubAssets.filter((a) => a.hub === rest[0] && a.assetId === rest[1]);
      break;
    case "slice":
      rows = snap.slices.filter((s) => s.hub === rest[0] && s.assetId === rest[1] && s.spoke === rest[2]);
      break;
    case "hub":
      rows = snap.hubs.filter((h) => h.hub === rest[0]);
      break;
    default:
      return null;
  }
  return rows.length > 0 ? JSON.stringify(rows) : null;
}

/**
 * Keeps each page whose rows match on the second provider's snapshot of the same block and turns the others into
 * warns. `secondary` is read only when there is a page to confirm, so pass it lazily.
 */
export async function confirmPages(findings: readonly Finding[], primary: ChainSnapshot, secondary: () => Promise<ChainSnapshot>): Promise<Finding[]> {
  if (!findings.some((f) => f.level === "page")) return [...findings];
  let second: ChainSnapshot | null = null;
  let error = "";
  try {
    second = await secondary();
    if (second.blockNumber !== primary.blockNumber) throw new Error(`second provider read block ${second.blockNumber}, not ${primary.blockNumber}`);
  } catch (err) {
    second = null;
    error = err instanceof Error ? err.message : String(err);
  }
  return findings.map((f) => {
    if (f.level !== "page") return f;
    // With the second provider down the page still goes out, marked unconfirmed: withholding every page while one
    // RPC endpoint is down would hide a real emergency, and the note sends the reader to check it by hand.
    if (!second) return { ...f, detail: { ...f.detail, note: `unconfirmed, second provider unavailable: ${error}` } };
    const mine = rowsFor(primary, f.subject);
    if (mine !== null && mine === rowsFor(second, f.subject)) return f;
    return { ...f, level: "warn", detail: { ...f.detail, note: "not confirmed on the second provider" } };
  });
}
