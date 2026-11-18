// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceStateView} from "./LPOracleTypes.sol";

/// @title ILPOracleCL
/// @notice Concentrated-liquidity extension of the LPOracle for Uniswap v3 or Slipstream markets.
interface ILPOracleCL {
    /// @notice Concentrated-liquidity detail of the current evaluation.
    /// @dev Never reverts except `InsufficientGas`.
    function getClPriceState() external view returns (ClPriceStateView memory report);

    /// @notice The module contract the logic contracts delegate their pricing hooks to.
    function MODULE_LOGIC() external view returns (address moduleLogic);
}
