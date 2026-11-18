// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../../parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../parameter-store/types/SpeedLimit.sol";

/// @notice Inputs of the borrow-speed check of one borrow.
struct BorrowSpeedInputs {
    // keccak256(abi.encode(hub, asset)), key of the debt window.
    bytes32 debtKey;
    address hub;
    address asset;
    // The borrow's charge in the market window, rounded up (8-decimal USD).
    uint256 amountUsd;
    // USD debt of the market's CDP Spoke over its debt reserves (8-decimal USD).
    uint256 marketBase;
    // Asset owed to the Hub by every CDP Spoke the MarketRegistry records (asset base units).
    uint256 debtBase;
    MarketSpeedLimits market;
    SpeedLimit debt;
}
