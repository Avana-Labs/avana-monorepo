// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaFirstLossReserveErrors
/// @notice Errors of a First-Loss Reserve. Role and Hub failures revert with the AccessManager's and Hub's own errors.
interface IAvanaFirstLossReserveErrors {
    /// @notice A constructor address input (`hub`, `asset`, `authority`) or an allowlisted Spoke is the zero address.
    error ZeroAddress();

    /// @notice `HUB.getAssetUnderlyingAndDecimals(assetId)` does not return the asset with its token decimals.
    error InvalidHubAsset(uint256 assetId);

    /// @notice The constructor's withdrawal delay is not the required `reserveWithdrawalDelay`.
    error InvalidWithdrawalDelay(uint256 delay);

    /// @notice `fund` or `requestWithdrawal` was called with a zero amount.
    error ZeroAmount();

    /// @notice The Hub's balance of the asset did not rise by exactly the funded amount.
    error TransferAmountMismatch(uint256 expected, uint256 received);

    error SpokeNotAllowlisted(address borrowSpoke);

    /// @notice The Spoke's deficit on the asset, or the computed coverage amount, is zero.
    error NothingToCover(address borrowSpoke);

    /// @notice `setAllowedBorrowSpoke(spoke, true)` for a Spoke not listed on the instance's Hub asset.
    error BorrowSpokeNotListed(address spoke);

    /// @notice A withdrawal recipient is the zero address, the First-Loss Reserve itself or the Hub.
    error InvalidRecipient(address to);

    error WithdrawalNotPending(uint256 id);

    /// @notice The withdrawal request is Pending but `block.timestamp < executableAt`.
    /// @param executableAt Earliest execution time, seconds.
    error WithdrawalNotReady(uint256 id, uint64 executableAt);

    /// @notice `executeWithdrawal` ran while an allowlisted Spoke has a recorded deficit on the asset.
    /// @param spoke The first such Spoke in the Hub's list.
    error DeficitOutstanding(address spoke);
}
