// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceStateView} from "./types/ClPriceStateView.sol";

/// @title ILPOracleCL
/// @notice Concentrated-liquidity extension of the LPOracle of a Uniswap v3 or Slipstream market: the oracle sqrt price,
/// its clamp to the market's range and the tick-based consistency check.
/// @dev Implemented, next to `ILPOracle`, by the LPOracle implementation for concentrated-liquidity markets. The core
/// `ILPOracle` carries no pool, token0, token1 or tick field. The consistency check reads the pool's TWAP over
/// `twapWindow` and requires `|meanTick - tickRef| <= consistencyToleranceBps` (one tick is a price ratio of 1.0001,
/// so a tolerance of 50 ticks admits a 0.501 % gap, about 50 bps); it gates the price and never feeds it.
/// @custom:spec REQ-ORACLE-042, REQ-ORACLE-046, REQ-AMM-V3-005, REQ-AMM-SLIP-005, Q-325, Q-330
interface ILPOracleCL {
    /// @notice Returns the concentrated-liquidity detail of the current evaluation.
    /// @dev Computed by the same code as `latestAnswer()` in the same block. Never reverts except `InsufficientGas`.
    /// @return report Range, oracle and clamped sqrt prices, TWAP and reference ticks, tolerance and cardinality.
    /// @custom:spec REQ-ORACLE-042, REQ-AMM-V3-005, REQ-AMM-SLIP-005
    function getClPriceState() external view returns (ClPriceStateView memory report);
}
