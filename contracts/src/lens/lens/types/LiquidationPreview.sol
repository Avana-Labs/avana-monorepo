// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../../liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {PauseState} from "../../../types/MarketTypes.sol";
import {RouteStatus} from "./RouteStatus.sol";

/// @notice Liquidation gates, Aave sizing and ready-to-send parameters for one account and one debt reserve.
/// @dev Advisory; `params.debtToCover` may exceed `expectedDebtRepaid` near Aave's dust threshold.
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
