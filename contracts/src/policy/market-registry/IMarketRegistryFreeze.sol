// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryFreeze
/// @notice The address freeze: a set of wallets that cannot start new activity.
/// @dev Exits and liquidation never read the set. The protected set cannot be frozen.
interface IMarketRegistryFreeze {
    /// @notice Freezes an address for new activity.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`. Reverts `FreezeLimitReached` past the per-day limit.
    function freezeAddress(
        address account
    ) external;

    /// @notice Unfreezes an address.
    /// @dev `APPLICATION_ADMIN` only.
    function unfreezeAddress(
        address account
    ) external;

    /// @notice Whether an address is frozen. Never reverts.
    function isFrozenAddress(
        address account
    ) external view returns (bool frozen);

    /// @notice Freezes a caller made in the 24 one-hour buckets ending with the current one.
    /// @return count Freezes counted toward `MAX_ADDRESS_FREEZES_PER_DAY`.
    function freezesInWindow(
        address caller
    ) external view returns (uint256 count);

    /// @notice Most freezes one caller can make in the 24 one-hour buckets ending with the current hour.
    function MAX_ADDRESS_FREEZES_PER_DAY() external view returns (uint256 limit);
}
