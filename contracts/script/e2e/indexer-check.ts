// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// After the services smoke stops the indexer: reads its PGlite store (schema `e2e`) and checks that every Hub of the
// manifest is recorded (`hub`, from MarketRegistry.HubRecorded) and that every Lend, CDP and First-Loss Reserve of the
// manifest is one of a Hub's Spokes (`hub_spoke`, from Hub.AddSpoke). Prints one line per kind and the CDP Spokes the
// MarketRegistry approved (`cdp_spoke`, from SpokeApproved), naming the others: only the Spokes of the config's
// `listing.spokes` (and of later listings) are approved, and the Aave payload deploys a CDP Spoke for every Hub, so the
// unlisted Hubs' Spokes stay unapproved; this line does not fail the check. Exit 1 when a Hub or Spoke is missing.
//
// Usage: node script/e2e/indexer-check.ts <manifest.json> <services root> <pglite directory>

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [manifestPath, servicesRoot, dataDir] = process.argv.slice(2);
if (!manifestPath || !servicesRoot || !dataDir) {
  console.error("usage: indexer-check.ts <manifest.json> <services root> <pglite directory>");
  process.exit(2);
}

type Entry = { address?: string; proxy?: string; label?: string };
const m = JSON.parse(readFileSync(manifestPath, "utf8"));
const addr = (e: Entry | string) => (typeof e === "string" ? e : (e.address ?? e.proxy ?? "")).toLowerCase();
const hubs: string[] = (m.aave.hubs as Entry[]).map(addr);
const lend: string[] = (m.aave.lendSpokes as Entry[]).map(addr);
const cdp: string[] = (m.aave.borrowSpokes as Entry[]).map(addr);
const coverage: string[] = Object.values((m.avana.firstLossReserves ?? {}) as Record<string, Entry | string>).map(addr);

const { PGlite } = await import(pathToFileURL(join(servicesRoot, "node_modules/@electric-sql/pglite/dist/index.js")).href);
const db = new PGlite(dataDir);
const rows = async (q: string) => ((await db.query(q)).rows as Record<string, string>[]).map((r) => Object.values(r)[0].toLowerCase());
const recorded = new Set(await rows("select hub from e2e.hub"));
const spokes = new Set(await rows("select distinct spoke from e2e.hub_spoke"));
const approved = new Set(await rows("select spoke from e2e.cdp_spoke"));
await db.close();

let ok = true;
const line = (kind: string, want: string[], have: Set<string>) => {
  const missing = want.filter((a) => !have.has(a));
  if (missing.length > 0 || want.length === 0) ok = false;
  console.log(`indexer: ${kind} ${want.length - missing.length}/${want.length}${missing.length ? ` missing ${missing.join(" ")}` : ""}`);
};
line("Hubs recorded", hubs, recorded);
line("Lend Spokes on their Hubs", lend, spokes);
line("CDP Spokes on their Hubs", cdp, spokes);
line("First-Loss Reserves on their Hubs", coverage, spokes);
const unapproved = (m.aave.borrowSpokes as Entry[]).filter((e) => !approved.has(addr(e))).map((e) => e.label ?? addr(e));
console.log(
  `indexer: CDP Spokes approved by the MarketRegistry ${cdp.length - unapproved.length}/${cdp.length}${unapproved.length ? ` (not listed: ${unapproved.join(" ")})` : ""}`,
);
process.exit(ok ? 0 : 1);
