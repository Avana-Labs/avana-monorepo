// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Timelock operations, implementations and roles of every upgradeable contract, ParameterStore and RiskModule
// events, First-Loss Reserve balances, vault tokens and the factory.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import { AAVE_HUB_SOURCES, AAVE_SPOKE_SOURCES } from "../config/aaveSources.ts";
import { logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

/** AvanaTimelock `GRACE_PERIOD`: an operation not executed by `readyAt + 14 days` expires (REQ-ACCESS-108). */
const GRACE_PERIOD_SECONDS = 14n * 24n * 3600n;

ponder.on("AvanaTimelock:CallScheduled", async ({ event, context }) => {
  const p = await recordLog(event, context, "AvanaTimelock.CallScheduled");
  const { id, index, target, value, data, delay } = event.args;
  const call = { index: Number(index), target: target.toLowerCase(), value: value.toString(10), data };
  const readyAt = p.blockTimestamp + delay;
  await context.db
    .insert(schema.timelockOperation)
    .values({
      chainId: p.chainId,
      timelockOperationId: id,
      status: "Scheduled",
      calls: [call],
      readyAt,
      expiresAt: readyAt + GRACE_PERIOD_SECONDS,
      scheduledBlock: p.blockNumber,
      lastBlock: p.blockNumber,
    })
    .onConflictDoUpdate((row) => ({ calls: [...(row.calls as unknown[]), call], lastBlock: p.blockNumber }));
});

for (const [name, status] of [
  ["CallExecuted", "Executed"],
  ["Cancelled", "Cancelled"],
  ["ExpiredOperationCleaned", "Cleaned"],
] as const) {
  ponder.on(`AvanaTimelock:${name}`, async ({ event, context }) => {
    const p = await recordLog(event, context, `AvanaTimelock.${name}`);
    await context.db
      .update(schema.timelockOperation, { chainId: p.chainId, timelockOperationId: event.args.id })
      .set({ status, lastBlock: p.blockNumber });
  });
}

logOnly("AvanaTimelock", ["CallSalt", "MinDelayChange", "NormalDelayChanged", "ShortDelaySelectorSet", "PublicExecutionToggled"]);

/**
 * Contracts whose ABI carries ERC-1967 `Upgraded` and AccessControl role events (src/config/abis.ts), each with the
 * kind its logs are recorded under: every Aave Hub or Spoke source records under the Aave contract's name.
 */
const UPGRADEABLE = [
  ...(["AaveAdapter", "LPVaultSwap", "MarketRegistry", "ParameterStore", "RiskModule", "LPOracle", "DebtOracle"] as const).map((c) => [c, c] as const),
  ...AAVE_SPOKE_SOURCES.map((c) => [c, "AaveSpoke"] as const),
  ...AAVE_HUB_SOURCES.map((c) => [c, "AaveHub"] as const),
];

for (const [contract, kind] of UPGRADEABLE) {
  ponder.on(`${contract}:Upgraded`, async ({ event, context }) => {
    const p = await recordLog(event, context, `${kind}.Upgraded`);
    const row = { implementation: event.args.implementation, changedBlock: p.blockNumber };
    await context.db
      .insert(schema.implementation)
      .values({ chainId: p.chainId, proxy: event.log.address, ...row })
      .onConflictDoUpdate(row);
  });
  for (const [name, granted] of [["RoleGranted", true], ["RoleRevoked", false]] as const) {
    ponder.on(`${contract}:${name}`, async ({ event, context }) => {
      const p = await recordLog(event, context, `${kind}.${name}`);
      await context.db
        .insert(schema.roleMember)
        .values({ chainId: p.chainId, contract: event.log.address, role: event.args.role, account: event.args.account, granted, lastBlock: p.blockNumber })
        .onConflictDoUpdate({ granted, lastBlock: p.blockNumber });
    });
  }
}

// The timelock's own roles (it holds its DEFAULT_ADMIN_ROLE itself).
for (const [name, granted] of [["RoleGranted", true], ["RoleRevoked", false]] as const) {
  ponder.on(`AvanaTimelock:${name}`, async ({ event, context }) => {
    const p = await recordLog(event, context, `AvanaTimelock.${name}`);
    await context.db
      .insert(schema.roleMember)
      .values({ chainId: p.chainId, contract: event.log.address, role: event.args.role, account: event.args.account, granted, lastBlock: p.blockNumber })
      .onConflictDoUpdate({ granted, lastBlock: p.blockNumber });
  });
}

logOnly("ParameterStore", [
  "SequencerSet",
  "MarketSpeedLimitsSet",
  "DebtSpeedLimitSet",
  "SecondSourceSwitched",
  "ParameterTightened",
  "ParameterLoosened",
  "ParameterSet",
  "CapTightened",
  "CapLoosened",
  "StressFloorSet",
  "FeedConfigured",
  "RouteDepthThresholdSet",
  "MinPledgeUsdSet",
  "DebtAssetParamsSet",
]);

logOnly("RiskModule", ["ConfigDriftDetected", "BreakersPoked"]);

for (const name of ["ReserveFunded", "DeficitCovered", "WithdrawalExecuted"] as const) {
  ponder.on(`AvanaFirstLossReserve:${name}`, async ({ event, context }) => {
    const p = await recordLog(event, context, `AvanaFirstLossReserve.${name}`);
    const row = { balance: event.args.balanceAfter, lastBlock: p.blockNumber };
    await context.db
      .insert(schema.coverageBalance)
      .values({ chainId: p.chainId, firstLossReserve: event.log.address, ...row })
      .onConflictDoUpdate(row);
  });
}

logOnly("AvanaFirstLossReserve", ["ReserveBelowMinimum", "WithdrawalRequested", "WithdrawalCancelled", "BorrowSpokeAllowlistUpdated", "FirstLossReserveMinimumUpdated"]);
logOnly("VaultToken", ["Transfer", "ProxyAdded"]);
logOnly("VaultTokenFactory", ["IntegrationRegistered", "VaultTokenDeployed"]);
