// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveV4Oracle
/// @notice Reads Avana makes on the Aave V4 oracle a CDP Spoke returns from `ORACLE()`.
/// @dev ABI checked against `src/spoke/interfaces/IPriceOracle.sol` and `src/spoke/interfaces/IAaveOracle.sol` of the
/// pinned Aave V4 dependency (`a3ef63e`).
interface IAaveV4Oracle {
    /// @notice Number of decimals of every price the oracle returns.
    /// @dev Read by the MarketRegistry when it approves a Spoke.
    function decimals() external view returns (uint8);

    /// @notice Price of reserve `reserveId` with `decimals` decimals; reverts when the source reports zero or less.
    /// @dev Summarised in the LPVaultSwap CVL spec.
    function getReservePrice(
        uint256 reserveId
    ) external view returns (uint256);

    /// @notice Price source set for reserve `reserveId`.
    /// @dev Read by the MarketRegistry debt-reserve checks and the RiskModule drift check.
    function getReserveSource(
        uint256 reserveId
    ) external view returns (address);

    /// @notice The Spoke this oracle prices for.
    /// @dev Read by the MarketRegistry when it records a CDP Spoke and its oracle.
    function spoke() external view returns (address);
}
