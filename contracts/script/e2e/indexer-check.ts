// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// After the services smoke stops the indexer: reads its PGlite store (schema `e2e`) and checks it against the release
// manifest. Every Lend Spoke, CDP Spoke, First-Loss Reserve and DAO deficit offset of the manifest is one of a Hub's
// Spokes (`hub_spoke`, from Hub.AddSpoke); every market is listed by its integration's RiskModule and active with the
// manifest's vault token, LPOracle and reserve (`market`, from MarketListed and MarketActivated, keyed by integration
// and market ID: each RiskModule numbers its own markets, so no other integration's row may stand in); every debt reserve is
// set with its First-Loss Reserve (`debt_reserve`, from DebtReserveSet); and every keeper of the manifest is registered
// (`keeper`, from KeeperAdded). Prints one line per kind; exit 1 when any entry is missing or differs.
//
// Usage: node script/e2e/indexer-check.ts <manifest.json> <services root> <pglite directory>

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [manifestPath, servicesRoot, dataDir] = process.argv.slice(2);
if (!manifestPath || !servicesRoot || !dataDir) {
  process.stderr.write("usage: indexer-check.ts <manifest.json> <services root> <pglite directory>\n");
  process.exit(2);
}

type Json = Record<string, any>;
const m = JSON.parse(readFileSync(manifestPath, "utf8")) as Json;
const lower = (a: unknown) => String(a ?? "").toLowerCase();
const riskModuleOf = new Map((m.avana.integrations as Json[]).map((x) => [Number(x.integrationId), lower(x.riskModule.address)]));

const { PGlite } = await import(pathToFileURL(join(servicesRoot, "node_modules/@electric-sql/pglite/dist/index.js")).href);
const db = new PGlite(dataDir);
const rows = async (q: string) => (await db.query(q)).rows as Record<string, unknown>[];
const spokes = new Set((await rows("select distinct spoke from e2e.hub_spoke")).map((r) => lower(r.spoke)));
const markets = await rows("select integration_id, market_id, risk_module, vault_token, lp_oracle, reserve_id, active from e2e.market");
const reserves = await rows("select risk_module, spoke, debt_reserve_id, first_loss_reserve, listed from e2e.debt_reserve");
const keepers = await rows("select risk_module, keeper, active from e2e.keeper");
await db.close();

let ok = true;
const line = (kind: string, want: { label: string; problem: string | null }[]) => {
  const bad = want.filter((w) => w.problem !== null);
  if (bad.length > 0 || want.length === 0) ok = false;
  process.stdout.write(`indexer: ${kind} ${want.length - bad.length}/${want.length}${bad.length ? ` (${bad.map((b) => `${b.label}: ${b.problem}`).join("; ")})` : ""}\n`);
};
const onHub = (list: Json[]) => list.map((e) => ({ label: lower(e.address), problem: spokes.has(lower(e.address)) ? null : "not on its Hub" }));
line("Lend Spokes on their Hubs", onHub(m.aave.lendSpokes));
line("CDP Spokes on their Hubs", onHub(m.aave.borrowSpokes));
line("First-Loss Reserves on their Hubs", onHub(m.coverage.firstLossReserves));
line("DAO deficit offsets on their Hubs", onHub(m.coverage.daoDeficitOffsets));
line(
  "markets listed and active",
  (m.markets as Json[]).map((x) => {
    const rm = riskModuleOf.get(Number(x.integrationId));
    const r = markets.find((y) => Number(y.integration_id) === Number(x.integrationId) && String(y.market_id) === String(x.marketId));
    const label = `${x.name} ${x.kind} (${x.integrationId}:${x.marketId})`;
    if (!r) return { label, problem: "not indexed for its integration" };
    if (lower(r.risk_module) !== rm) return { label, problem: `listed by RiskModule ${r.risk_module}, the integration's is ${rm}` };
    if (r.active !== true) return { label, problem: "not active" };
    if (lower(r.vault_token) !== lower(x.vaultToken.address) || lower(r.lp_oracle) !== lower(x.lpOracle.address) || String(r.reserve_id) !== String(x.reserveId)) {
      return { label, problem: `vault token ${r.vault_token}, LPOracle ${r.lp_oracle}, reserve ${r.reserve_id}` };
    }
    return { label, problem: null };
  }),
);
line(
  "debt reserves set with their First-Loss Reserve",
  (m.debtReserves as Json[]).map((d) => {
    const r = reserves.find((y) => lower(y.spoke) === lower(d.spoke) && String(y.debt_reserve_id) === String(d.debtReserveId) && y.listed === true);
    const label = `${d.spoke}:${d.debtReserveId}`;
    return { label, problem: !r ? "not set" : lower(r.first_loss_reserve) !== lower(d.firstLossReserve) ? `First-Loss Reserve ${r.first_loss_reserve}` : null };
  }),
);
line(
  "keepers registered on every RiskModule",
  (m.roles.keepers as string[]).map((k) => {
    const missing = [...riskModuleOf.values()].filter((rm) => !keepers.some((y) => lower(y.keeper) === lower(k) && lower(y.risk_module) === rm && y.active === true));
    return { label: lower(k), problem: missing.length ? `not on ${missing.join(" ")}` : null };
  }),
);
process.exit(ok ? 0 : 1);
