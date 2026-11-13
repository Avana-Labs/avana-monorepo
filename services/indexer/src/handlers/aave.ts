// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Aave V4 Spoke and Hub events kept in the log for the app history, monitoring (M-15, M-18, M-19, M-20) and the
// DAO refresh payload list (Q-145). Account-level Spoke events are handled in accounts.ts. Signatures come from the
// Aave ABIs in packages/protocol (built from the pinned Aave V4 commit), not from Avana's minimal interfaces. Every
// Hub and Spoke source of src/config/aaveSources.ts registers the same events under the Aave contract's kind.

import { AAVE_HUB_SOURCES, AAVE_SPOKE_SOURCES } from "../config/aaveSources.ts";
import { logOnly } from "../lib/logOnly.ts";

const SPOKE_EVENTS = [
  "Supply",
  "Withdraw",
  "UpdateUserRiskPremium",
  "RefreshPremiumDebt",
  "RefreshAllUserDynamicConfig",
  "RefreshSingleUserDynamicConfig",
  "SetUserPositionManager",
  "UpdatePositionManager",
  "AddReserve",
  "UpdateReserveConfig",
  "AddDynamicReserveConfig",
  "UpdateDynamicReserveConfig",
  "UpdateLiquidationConfig",
  "UpdateReservePriceSource",
  "SetSpokeImmutables",
  "AuthorityUpdated",
];

const HUB_EVENTS = [
  "Add",
  "Remove",
  "Draw",
  "Restore",
  "ReportDeficit",
  "EliminateDeficit",
  "RefreshPremium",
  "TransferShares",
  "MintFeeShares",
  "UpdateAsset",
  "UpdateAssetConfig",
  "UpdateSpokeConfig",
  "AddAsset",
  "AddSpoke",
  "Reclaim",
  "Sweep",
  "AuthorityUpdated",
];

for (const source of AAVE_SPOKE_SOURCES) logOnly(source, SPOKE_EVENTS, "AaveSpoke");
// `AddSpoke` is also written to the `hub_spoke` table (hubs.ts); every other Hub event is logged only.
for (const source of AAVE_HUB_SOURCES) logOnly(source, HUB_EVENTS.filter((e) => e !== "AddSpoke"), "AaveHub");
