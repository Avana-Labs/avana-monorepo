// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAmmIntegrationHooks
/// @notice Hooks for the cases a single integration shape does not fit. A hook that does not apply returns its
/// neutral value.
interface IAmmIntegrationHooks {
    /// @notice Reverts `PoolLocked` while the market's pool is inside its own reentrancy lock.
    /// @dev Called before every composition read and custody action, so no read happens inside a pool callback.
    function checkReadSafe(
        uint256 marketId
    ) external view;

    /// @notice Returns the deviation, in bps, between the AMM protocol's time-weighted price over `window` and the
    /// price implied by the oracle vector.
    /// @dev Consistency check only; it never feeds the price.
    function consistencyDeviation(
        uint256 marketId,
        uint32 window,
        uint256[] calldata prices
    ) external view returns (uint256 deviationBps, bool available);

    /// @notice Returns the rate provider of each pool token, address(0) where the token has none.
    function rateProviders(
        uint256 marketId
    ) external view returns (address[] memory providers);

    /// @notice Returns the wrapped native token used in place of a native ETH pool leg, or address(0).
    /// @dev An unwind wraps native ETH before paying, so every Avana transfer is an ERC-20 transfer.
    function wrappedNative() external view returns (address weth);

    /// @notice Returns whether a Uniswap v4 hook contract is allowlisted for collateral.
    function isAllowedPoolHook(
        address hooks
    ) external view returns (bool allowed);

    /// @notice Returns the pool units against which one position unit is valued (0 for concentrated liquidity).
    function effectiveSupply(
        uint256 marketId
    ) external view returns (uint256 supply);
}
