// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseState} from "../../../types/PauseState.sol";

/// @notice One enabled debt reserve with its Hub totals, rates and rate curve.
/// @dev Rates RAY per year; strategy parameters bps; `utilizationBps` and `supplyRateRay` rounded down.
struct DebtReserveView {
    uint256 blockNumber;
    uint256 timestamp;
    address spoke;
    uint256 reserveId;
    address asset;
    uint8 decimals;
    uint256 price;
    bool fixedPrice;
    address hub;
    uint256 hubAssetId;
    uint256 added;
    uint256 drawn;
    uint256 premium;
    uint256 liquidity;
    uint256 utilizationBps;
    uint256 drawnRateRay;
    uint256 supplyRateRay;
    uint256 liquidityFeeBps;
    uint256 optimalUsageBps;
    uint256 baseDrawnRateBps;
    uint256 rateGrowthBeforeOptimalBps;
    uint256 rateGrowthAfterOptimalBps;
    uint256 drawCap;
    uint256 drawHeadroom;
    bool paused;
    bool frozen;
    bool borrowable;
    uint32 breakerReasons;
    PauseState pauseState;
}
