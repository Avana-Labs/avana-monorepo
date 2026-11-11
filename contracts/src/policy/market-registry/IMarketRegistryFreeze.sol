// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryFreeze
/// @notice The address freeze: a set of wallets that cannot start new activity.
/// @dev Preserves: exits and liquidation never read the set (repay, debt-free withdrawal and removal,
/// `repayAllAndWithdraw`, fee collection, zero-credit release, `settlePending`, `burnSeized`, payout-escrow claims,
/// contract-to-contract calls and the liquidation of a frozen wallet's positions); the protected set is never frozen;
/// no keeper floor is checked, so a guardian can freeze any compromised keeper, the last one included; with 0 active
/// keepers new borrowing halts on the chain (Q-400). Readers: the AaveAdapter, the ProxyManager and LPVaultSwap, for the
/// calling wallet only, each reverting `AddressIsFrozen`.
interface IMarketRegistryFreeze {
    /// @notice Freezes an address for new activity.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` (immediate) or `APPLICATION_ADMIN` (short delay), else `Unauthorized`.
    /// Reverts `AddressAlreadyFrozen`, `ProtectedAddress` for the protected set, and `FreezeLimitReached` unless the
    /// caller made fewer than `MAX_ADDRESS_FREEZES_PER_DAY` freezes in the 24 one-hour buckets ending with the current
    /// one. Checks no keeper floor (REQ-MREG-021, Q-400). Emits `AddressFrozen`.
    /// @param account Address to freeze.
    /// @custom:spec REQ-MREG-019, REQ-MREG-020, REQ-MREG-021, Q-242, Q-262
    function freezeAddress(
        address account
    ) external;

    /// @notice Unfreezes an address.
    /// @dev `APPLICATION_ADMIN`, normal delay; only `DAO_CANCELLER_ROLE` can cancel the operation. Reverts
    /// `AddressNotFrozen` unless frozen. Emits `AddressUnfrozen`.
    /// @param account Address to unfreeze.
    /// @custom:spec REQ-MREG-022, Q-242, Q-263
    function unfreezeAddress(
        address account
    ) external;

    /// @notice Whether an address is frozen. Never reverts.
    /// @param account The address.
    /// @return frozen True when frozen.
    /// @custom:spec REQ-MREG-022, REQ-MREG-023
    function isFrozenAddress(
        address account
    ) external view returns (bool frozen);

    /// @notice Freezes a caller made in the 24 one-hour buckets `⌊t / 3,600⌋` ending with the current one (a window of
    /// 23 to 24 hours of wall-clock time).
    /// @param caller Guardian Safe or the timelock.
    /// @return count Freezes counted toward `MAX_ADDRESS_FREEZES_PER_DAY`.
    /// @custom:spec REQ-MREG-019
    function freezesInWindow(
        address caller
    ) external view returns (uint256 count);

    /// @notice Most freezes one caller can make in the 24 one-hour buckets ending with the current hour (20).
    /// @return limit The constant.
    /// @custom:spec REQ-MREG-019
    function MAX_ADDRESS_FREEZES_PER_DAY() external view returns (uint256 limit);
}
