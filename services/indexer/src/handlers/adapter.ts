// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// AaveAdapter user actions (account creation is in accounts.ts). Each action is one transaction in which the Adapter,
// the LPVault, the vault token and the Spoke emit their own events, so the log rows of one txHash reconstruct it.
// `Pledged` names the wallet behind a position; the LPVault's events move the position itself (collateral.ts). A
// `Repaid` whose payer is not the wallet is a valid third-party repay; `WithdrawAllowed` opens a repay with collateral.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { lpVaultOfAdapter } from "../config/integrations.ts";
import { logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

ponder.on("AaveAdapter:Pledged", async ({ event, context }) => {
  const p = await recordLog(event, context, "AaveAdapter.Pledged");
  // The LPVault's PositionPledged, emitted first in the same call, created the row.
  const lpVault = lpVaultOfAdapter(p.chainId, event.log.address);
  const key = { chainId: p.chainId, lpVault: lpVault ?? "0x", positionKey: event.args.positionKey };
  if (!lpVault || !(await context.db.find(schema.position, key))) {
    throw new Error(`Pledged for position ${event.args.positionKey} on chain ${p.chainId} without its PositionPledged`);
  }
  await context.db.update(schema.position, key).set({ wallet: event.args.wallet });
});

logOnly("AaveAdapter", ["LiquidityAdded", "Withdrawn", "WithdrawAllowed", "Borrowed", "Repaid"]);
