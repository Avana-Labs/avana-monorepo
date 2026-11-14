// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Acts on the Spoke's `UpdateUserRiskPremium` and `UpdateReserveConfig`: the first keeps each attributed account's
// last premium and the log that set it, the second each reserve's collateral risk and the last log that changed it.
// Together they give the proxies whose premium predates a collateral-risk change (`/export/v1/premium-refresh`).
// Both are recorded once under the Aave kind and act only on their first delivery (src/config/aaveSources.ts).

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { AAVE_SPOKE_SOURCES } from "../config/aaveSources.ts";
import { recordLog } from "../lib/record.ts";

for (const source of AAVE_SPOKE_SOURCES) {
  ponder.on(`${source}:UpdateUserRiskPremium`, async ({ event, context }) => {
    const p = await recordLog(event, context, "AaveSpoke.UpdateUserRiskPremium");
    const key = { chainId: p.chainId, spoke: event.log.address, proxy: event.args.user };
    // A user that is not an attributed Avana account (a Lend Spoke supplier, another protocol's user) is only logged.
    if (!p.fresh || !(await context.db.find(schema.account, key))) return;
    const row = { riskPremium: event.args.riskPremium, lastBlock: p.blockNumber, lastLogIndex: p.logIndex };
    await context.db.insert(schema.accountPremium).values({ ...key, ...row }).onConflictDoUpdate(row);
  });

  ponder.on(`${source}:UpdateReserveConfig`, async ({ event, context }) => {
    const p = await recordLog(event, context, "AaveSpoke.UpdateReserveConfig");
    if (!p.fresh) return;
    const c = event.args.config;
    const values = { collateralRisk: Number(c.collateralRisk), paused: c.paused, frozen: c.frozen, borrowable: c.borrowable, lastBlock: p.blockNumber };
    await context.db
      .insert(schema.reserveConfig)
      .values({ chainId: p.chainId, spoke: event.log.address, reserveId: event.args.reserveId, ...values })
      .onConflictDoUpdate((row) =>
        row.collateralRisk === values.collateralRisk ? values : { ...values, riskChangedBlock: p.blockNumber, riskChangedLogIndex: p.logIndex },
      );
  });
}
