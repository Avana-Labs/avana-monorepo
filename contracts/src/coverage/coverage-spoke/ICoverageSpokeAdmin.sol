// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICoverageSpokeAdmin
/// @notice Functions of a Coverage Spoke that only the Aave DAO calls, through `RESERVE_ADMIN_ROLE` in its
/// AccessManager: the allowlist of covered CDP Spokes, the minimum balance and the withdrawal lifecycle. No Avana
/// contract calls them; their withdrawal events are declared in `ICoverageSpoke`.
/// @custom:spec REQ-FLR-002, REQ-FLR-013, REQ-FLR-017, REQ-FLR-023, REQ-FLR-024, REQ-FLR-025
interface ICoverageSpokeAdmin {
    /// @notice Emitted by every successful `setAllowedBorrowSpoke`.
    /// @param spoke The CDP Spoke.
    /// @param allowed Whether its deficits on the asset may now be covered.
    /// @custom:spec REQ-FLR-017
    event BorrowSpokeAllowlistUpdated(address indexed spoke, bool allowed);

    /// @notice Emitted by every successful `setFirstLossReserveMinimum`.
    /// @param oldMinimum The previous minimum, asset base units.
    /// @param newMinimum The new minimum, asset base units.
    /// @custom:spec REQ-FLR-013
    event FirstLossReserveMinimumUpdated(uint256 oldMinimum, uint256 newMinimum);

    /// @notice Adds `spoke` to, or removes it from, the allowlist of CDP Spokes whose deficits on the asset may be
    /// covered.
    /// @dev `RESERVE_ADMIN_ROLE` only. Adding reverts `ZeroAddress` for the zero address and `BorrowSpokeNotListed`
    /// unless `HUB.isSpokeListed(ASSET_ID, spoke)`; removal takes effect at once and has no check.
    /// @param spoke The CDP Spoke.
    /// @param allowed True to add, false to remove.
    /// @custom:spec REQ-FLR-016, REQ-FLR-017
    function setAllowedBorrowSpoke(
        address spoke,
        bool allowed
    ) external;

    /// @notice Sets `firstLossReserveMinimum`, the value of the funding ARFC.
    /// @dev `RESERVE_ADMIN_ROLE` only. Any value; it never blocks funding, coverage or withdrawal.
    /// @param minimum Asset base units.
    /// @custom:spec REQ-FLR-013
    function setFirstLossReserveMinimum(
        uint256 minimum
    ) external;

    /// @notice Records a withdrawal of up to `amount` to `to`, executable after `RESERVE_WITHDRAWAL_DELAY`.
    /// @dev `RESERVE_ADMIN_ROLE` only. Reverts `ZeroAmount` and `InvalidRecipient` (zero address, this contract, the
    /// Hub). Emits `WithdrawalRequested`.
    /// @param amount Asset base units.
    /// @param to Recipient the Hub pays directly.
    /// @return id Request ID, starting at 1.
    /// @custom:spec REQ-FLR-023, SPEC-FLR-003
    function requestWithdrawal(
        uint256 amount,
        address to
    ) external returns (uint256 id);

    /// @notice Cancels a Pending request.
    /// @dev `RESERVE_ADMIN_ROLE` only. Reverts `WithdrawalNotPending`. Emits `WithdrawalCancelled`.
    /// @param id Request ID.
    /// @custom:spec REQ-FLR-024
    function cancelWithdrawal(
        uint256 id
    ) external;

    /// @notice Executes a Pending request once `block.timestamp ≥ executableAt`, withdrawing
    /// `min(amount, fundedBalance())` from the Hub straight to the request's recipient.
    /// @dev `RESERVE_ADMIN_ROLE` only. Reverts `WithdrawalNotPending`, `WithdrawalNotReady`, or
    /// `DeficitOutstanding(spoke)` while any allowlisted Spoke has a recorded deficit on the asset (coverage comes
    /// before withdrawal); the Hub reverts `InsufficientLiquidity`, `SpokeHalted`, `SpokeNotActive` or (nothing funded)
    /// `InvalidAmount`. Every revert leaves the request Pending. Emits `WithdrawalExecuted` and, below the minimum,
    /// `ReserveBelowMinimum`.
    /// @param id Request ID.
    /// @return withdrawn Asset base units withdrawn.
    /// @custom:spec REQ-FLR-014, REQ-FLR-025, REQ-FLR-033, REQ-FLR-034, SPEC-FLR-003
    function executeWithdrawal(
        uint256 id
    ) external returns (uint256 withdrawn);
}
