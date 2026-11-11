// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IClPoolObservations
/// @notice The pool reads every concentrated-liquidity LPVault makes that have one layout on Uniswap v3 and Aerodrome
/// Slipstream pools: in-range liquidity and the observation buffer.
/// @dev `slot0` differs between the two (7 fields on Uniswap v3, 6 on Slipstream) and is decoded by each integration
/// with its own external interface (`REQ-AMM-V3-003`).
/// @custom:spec REQ-AMM-V3-006, REQ-AMM-CORE-013, Q-371
interface IClPoolObservations {
    /// @notice In-range liquidity of the pool.
    function liquidity() external view returns (uint128);

    /// @notice Tick and seconds-per-liquidity cumulatives at each `secondsAgos`; reverts when a requested time is older
    /// than the oldest observation.
    function observe(
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
