// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// AaveAdapter user-action events (proxy creation is in accounts.ts). Each action is one atomic transaction in which
// the Adapter, Collateralization, the LPVault, the vault token and the Spoke emit their own events (Q-076), so the
// log rows of one txHash reconstruct the whole action. A `Repaid` whose payer is not the borrower is a valid
// third-party repay (Q-212).

import { logOnly } from "../lib/logOnly.ts";

logOnly("AaveAdapter", [
  "CollateralAdded",
  "Borrowed",
  "Repaid",
  "CollateralWithdrawn",
  "SeizedUnitsBurned",
  "CollateralRecredited",
  "CollateralReduced",
  "RepaidWithCollateral",
  "CollateralSupplied",
  "CollateralDisabled",
]);
