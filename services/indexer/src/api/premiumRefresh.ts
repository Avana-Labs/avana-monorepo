// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The risk premium refresh list of one Spoke (EXPORT.md, "Risk premium refresh"): the attributed proxies with drawn
// debt whose last `UpdateUserRiskPremium` predates the Spoke's last collateral-risk change, read at the indexer's head.
// The Aave DAO's refresh payload passes them to `updateUserRiskPremium`; the list is a convenience, since any proxy left
// out keeps its old premium until its next action (stale premiums between payloads are accepted).

import { db } from "ponder:api";
import schema from "ponder:schema";
import { and, eq } from "ponder";
import type { PremiumRefreshList } from "@avana/services-common";
import { lastRiskChange, refreshList } from "../lib/premiumRefresh.ts";

export async function buildPremiumRefresh(chainId: number, spoke: `0x${string}`): Promise<PremiumRefreshList | null> {
  const [progress] = await db.select().from(schema.chainProgress).where(eq(schema.chainProgress.chainId, chainId));
  if (!progress) return null;
  const reserves = await db.select().from(schema.reserveConfig).where(and(eq(schema.reserveConfig.chainId, chainId), eq(schema.reserveConfig.spoke, spoke)));
  const change = lastRiskChange(reserves.map((r) => (r.riskChangedBlock === null ? null : { blockNumber: r.riskChangedBlock, logIndex: r.riskChangedLogIndex ?? 0 })));
  const accounts = await db.select().from(schema.account).where(and(eq(schema.account.chainId, chainId), eq(schema.account.spoke, spoke)));
  const debts = await db.select().from(schema.accountDebt).where(and(eq(schema.accountDebt.chainId, chainId), eq(schema.accountDebt.spoke, spoke)));
  const premiums = await db.select().from(schema.accountPremium).where(and(eq(schema.accountPremium.chainId, chainId), eq(schema.accountPremium.spoke, spoke)));
  const drawn = new Map<string, bigint>();
  for (const d of debts) if (!d.deficitReported) drawn.set(d.proxy, (drawn.get(d.proxy) ?? 0n) + d.drawnShares);
  const premiumOf = new Map(premiums.map((p) => [p.proxy, { blockNumber: p.lastBlock, logIndex: p.lastLogIndex }]));
  const proxies = refreshList(
    change,
    accounts.filter((a) => a.adapterSeen && a.managerSeen).map((a) => ({ proxy: a.proxy, drawnShares: drawn.get(a.proxy) ?? 0n, premiumAt: premiumOf.get(a.proxy) ?? null })),
  );
  return {
    chainId,
    spoke,
    asOfBlock: progress.blockNumber.toString(10),
    riskChangedBlock: change === null ? null : change.blockNumber.toString(10),
    proxies,
  };
}
