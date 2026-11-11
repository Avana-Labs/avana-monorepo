// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../../liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {PauseState} from "../../../types/PauseState.sol";
import {RouteStatus} from "./RouteStatus.sol";

/// @notice Liquidation gates, Aave sizing and ready-to-send parameters for one account (one market) and one debt
/// reserve.
/// @dev `healthFactor`, `bonusBps` and `params.debtToCover` equal the values the Spoke uses in a liquidation at the same
/// block; `expectedDebtRepaid` is the debt Aave repays (debt-asset base units), which `params.debtToCover` may exceed
/// (whole debt near the dust threshold). `targetHealthFactor`, `healthFactorForMaxBonus` and `liquidationBonusFactor`
/// are the Spoke's `LiquidationConfig`. Gates are evaluated as LPVaultSwap evaluates them, on the seized market and the
/// repaid reserve only: `pricesUsable`, `feedsDisagree`, `debtPriceFresh`, `stressValued` (another reserve counts at a
/// stress price; never blocking), `inGrace` and `belowGraceHealthFactor`, `sharesEqualAssets`, `routeUsable` (one swap
/// route per pool token other than the debt asset), `activeKeeperCount` (registered committed operators whose address
/// is not frozen; informational, it gates no liquidation), and the Aave paused flags `vaultTokenReservePaused` and
/// `debtReservePaused`. `pauseState` is the market's home Hub's and is informational: `liquidate` does not read it.
/// The preview quotes no flash loan: LPVaultSwap takes none, and a caller that borrows through a flash liquidation helper
/// reads the helper's own quotes (REQ-HELPER-009). `slippageBps` is SPEC-LIQ-003; `minOutPerWholeToken` is the recovery
/// floor for one whole vault token. `params` is ready to submit (minPayout 0, maxShortfall 0, empty minAmounts, the
/// caller's deadline); the caller funds `params.debtToCover` itself. `expectedUnitsSeized` is in vault-token units;
/// `recoveryFloor` (the floor for that seizure), `expectedPayout` (keeperOut for caller funding `params.debtToCover`
/// with every swap at the oracle value), `expectedNetPayout` (`max(0, expectedPayout - params.debtToCover)`, the keeper
/// reward beyond the returned funding, Q-345), `expectedAvanaFee` and `expectedBorrowerSurplus` are in debt-asset base
/// units. `expectedCallerLoss = max(0, D - Rv)`, with `Rv` the oracle value of the unwound tokens, is the amount the
/// caller's payout can fall below its funding at oracle prices (REQ-LENS-029, SPEC-SET-005); a helper's caller sets its
/// top-up bound to at least `max(0, premium + expectedCallerLoss - expectedNetPayout)`. There is no remaining-capacity
/// view (Q-397). A USD-band breach alone is never reported as blocking.
/// @custom:spec SPEC-SET-005, SPEC-LIQ-019, REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, Q-232, Q-247, Q-268, Q-345, Q-379, Q-404
struct LiquidationPreview {
    uint256 blockNumber;
    uint256 timestamp;
    address proxy;
    uint256 marketId;
    address vaultToken;
    uint256 reserveId;
    uint256 debtReserveId;
    address debtAsset;
    uint256 healthFactor;
    bool aaveLiquidatable;
    uint256 bonusBps;
    uint256 targetHealthFactor;
    uint256 healthFactorForMaxBonus;
    uint256 liquidationBonusFactor;
    uint256 suppliedUnits;
    bool pricesUsable;
    bool feedsDisagree;
    bool debtPriceFresh;
    bool stressValued;
    bool inGrace;
    bool belowGraceHealthFactor;
    bool sharesEqualAssets;
    RouteStatus[] routeUsable;
    uint256 activeKeeperCount;
    bool vaultTokenReservePaused;
    bool debtReservePaused;
    PauseState pauseState;
    uint256 slippageBps;
    uint256 minOutPerWholeToken;
    LiquidationParams params;
    uint256 expectedDebtRepaid;
    uint256 expectedUnitsSeized;
    uint256 recoveryFloor;
    uint256 expectedPayout;
    uint256 expectedNetPayout;
    uint256 expectedAvanaFee;
    uint256 expectedBorrowerSurplus;
    uint256 expectedCallerLoss;
}
