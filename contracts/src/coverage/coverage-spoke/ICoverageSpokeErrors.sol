// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICoverageSpokeErrors
/// @notice Errors of a Coverage Spoke (2.14). Role failures revert with the AccessManager's
/// `AccessManagedUnauthorized`; Hub-side failures (`SpokeHalted`, `SpokeNotActive`, `AddCapExceeded`,
/// `InsufficientLiquidity`, `InvalidAmount`) revert with the Hub's own errors.
interface ICoverageSpokeErrors {
    /// @notice A constructor address input (`hub`, `asset`, `authority`) or an allowlisted Spoke is the zero address.
    /// @custom:spec REQ-FLR-008, REQ-FLR-017
    error ZeroAddress();

    /// @notice `HUB.getAssetUnderlyingAndDecimals(assetId)` does not return the asset with its token decimals.
    /// @param assetId The rejected Hub asset ID.
    /// @custom:spec REQ-FLR-008
    error InvalidHubAsset(uint256 assetId);

    /// @notice The constructor's withdrawal delay is not `reserveWithdrawalDelay` (1,209,600 s).
    /// @param delay The rejected delay, seconds.
    /// @custom:spec REQ-FLR-008
    error InvalidWithdrawalDelay(uint256 delay);

    /// @notice `fund` or `requestWithdrawal` was called with a zero amount.
    /// @custom:spec REQ-FLR-010, REQ-FLR-023
    error ZeroAmount();

    /// @notice The Hub's balance of the asset did not rise by exactly the funded amount.
    /// @param expected The amount `fund` was called with.
    /// @param received The Hub's balance rise.
    /// @custom:spec REQ-FLR-005, REQ-FLR-010
    error TransferAmountMismatch(uint256 expected, uint256 received);

    /// @notice `coverDeficit` named a Spoke that is not on the allowlist.
    /// @param borrowSpoke The rejected Spoke.
    /// @custom:spec REQ-FLR-016, REQ-FLR-029
    error SpokeNotAllowlisted(address borrowSpoke);

    /// @notice The Spoke's deficit on the asset, or the coverage amount of SPEC-FLR-001, is zero.
    /// @param borrowSpoke The Spoke.
    /// @custom:spec REQ-FLR-018, REQ-FLR-030
    error NothingToCover(address borrowSpoke);

    /// @notice `setAllowedBorrowSpoke(spoke, true)` for a Spoke not listed on the instance's Hub asset.
    /// @param spoke The rejected Spoke.
    /// @custom:spec REQ-FLR-017
    error BorrowSpokeNotListed(address spoke);

    /// @notice A withdrawal recipient is the zero address, the Coverage Spoke itself or the Hub.
    /// @param to The rejected recipient.
    /// @custom:spec REQ-FLR-023
    error InvalidRecipient(address to);

    /// @notice The withdrawal request is not Pending.
    /// @param id Request ID.
    /// @custom:spec REQ-FLR-024, REQ-FLR-025, REQ-FLR-033
    error WithdrawalNotPending(uint256 id);

    /// @notice The withdrawal request is Pending but `block.timestamp < executableAt`.
    /// @param id Request ID.
    /// @param executableAt Earliest execution time, seconds.
    /// @custom:spec REQ-FLR-025, REQ-FLR-033, SPEC-FLR-003
    error WithdrawalNotReady(uint256 id, uint64 executableAt);

    /// @notice `executeWithdrawal` ran while an allowlisted Spoke has a recorded deficit on the asset; the request stays
    /// Pending until that deficit is covered or the Spoke is removed from the allowlist.
    /// @param spoke The first such Spoke in the Hub's list.
    /// @custom:spec REQ-FLR-026, REQ-FLR-045, SPEC-FLR-003
    error DeficitOutstanding(address spoke);
}
