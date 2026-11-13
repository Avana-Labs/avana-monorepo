// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../../parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../parameter-store/types/SpeedLimit.sol";

/// @notice What the borrow-speed check of one borrow needs, read by `RiskModuleSpeedLogic` (REQ-RISK-092).
/// @custom:spec REQ-RISK-092, SPEC-CAP-012, SPEC-CAP-013, Q-411
struct BorrowSpeedInputs {
    // The account's market, key of the market window.
    uint256 marketId;
    // keccak256(abi.encode(hub, asset)), key of the debt window.
    bytes32 debtKey;
    // The reserve's funding Hub.
    address hub;
    // The reserve's asset.
    address asset;
    // The borrow's charge in the market window, ⌈amount × price8 / 10^dec⌉ (8-decimal USD).
    uint256 amountUsd;
    // D_m: USD debt of the market's CDP Spoke over its debt reserves (8-decimal USD).
    uint256 marketBase;
    // D_ha: asset owed to the Hub by every CDP Spoke the MarketRegistry records (asset base units).
    uint256 debtBase;
    // The market's speed limits.
    MarketSpeedLimits market;
    // The (Hub, asset)'s borrow-speed limit.
    SpeedLimit debt;
}
