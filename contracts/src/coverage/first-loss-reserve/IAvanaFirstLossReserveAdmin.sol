// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaFirstLossReserveAdmin
/// @notice First-Loss Reserve functions only the Aave DAO calls, through `RESERVE_ADMIN_ROLE`.
interface IAvanaFirstLossReserveAdmin {
    event BorrowSpokeAllowlistUpdated(address indexed spoke, bool allowed);

    event FirstLossReserveMinimumUpdated(uint256 oldMinimum, uint256 newMinimum);

    /// @notice Adds `spoke` to, or removes it from, the allowlist of CDP Spokes whose deficits may be covered.
    /// @dev Adding requires `spoke` to be listed on the Hub asset; removal is immediate.
    function setAllowedBorrowSpoke(
        address spoke,
        bool allowed
    ) external;

    /// @notice Sets `firstLossReserveMinimum`; it never blocks funding, coverage or withdrawal.
    function setFirstLossReserveMinimum(
        uint256 minimum
    ) external;

    /// @notice Records a withdrawal of up to `amount` to `to`, executable after `RESERVE_WITHDRAWAL_DELAY`.
    /// @return id Request ID, starting at 1.
    function requestWithdrawal(
        uint256 amount,
        address to
    ) external returns (uint256 id);

    /// @notice Cancels a Pending request.
    function cancelWithdrawal(
        uint256 id
    ) external;

    /// @notice Executes a Pending request once due, withdrawing `min(amount, fundedBalance())` to the recipient.
    /// @dev Reverts `DeficitOutstanding` while an allowlisted Spoke has a deficit on the asset.
    function executeWithdrawal(
        uint256 id
    ) external returns (uint256 withdrawn);
}
