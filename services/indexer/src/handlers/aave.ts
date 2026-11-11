// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Aave V4 Spoke and Hub events kept in the log for the app history, monitoring (M-15, M-18, M-19, M-20) and the
// DAO refresh payload list (Q-145). Account-level Spoke events are handled in accounts.ts. Signatures come from the
// Aave ABIs in packages/protocol (built from the pinned Aave V4 commit), not from Avana's minimal interfaces.

import { logOnly } from "../lib/logOnly.ts";

logOnly("AaveSpoke", [
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
]);

logOnly("AaveHub", [
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
]);
