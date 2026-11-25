// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveV4PriceFeed
/// @notice Price source shape an Aave V4 oracle accepts for a reserve; Avana's LPOracle and DebtOracle implement it.
/// @dev ABI-equal to the pinned Aave V4 `IPriceFeed` (`a3ef63e`).
interface IAaveV4PriceFeed {
    /// @notice Number of decimals of `latestAnswer`.
    /// @dev The Aave V4 oracle requires it to equal its own `decimals()` when the source is set.
    function decimals() external view returns (uint8);

    /// @notice Human-readable name of the feed.
    function description() external view returns (string memory);

    /// @notice Current price with `decimals` decimals.
    /// @dev The Aave V4 oracle reads it on every price request and rejects a value of zero or below.
    function latestAnswer() external view returns (int256);
}
