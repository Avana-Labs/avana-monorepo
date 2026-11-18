// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMode} from "./RouteMode.sol";

/// @notice Arguments of `liquidate`, the one liquidation entry point.
/// @dev Amounts are in base units of the debt reserve's asset.
struct LiquidationParams {
    address proxy;
    // Collateral market to seize; must equal the proxy's MARKET_ID().
    uint256 marketId;
    uint256 debtReserveId;
    // Debt asset pulled from msg.sender; the amount measured bounds Aave's liquidationCall.
    uint256 debtToCover;
    RouteMode routeMode;
    // Least raw amount of each pool token the unwind must return; empty for none.
    uint256[] minAmounts;
    uint256 deadline;
    // Smallest keeperOut the caller accepts; keeperOut includes the returned funding.
    uint256 minPayout;
    // Most extra debt asset the call may pull to cover recovery below the floor; 0 disables the top-up.
    uint256 maxShortfall;
}
