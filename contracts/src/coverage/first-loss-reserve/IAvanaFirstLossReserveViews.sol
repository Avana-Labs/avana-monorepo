// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Withdrawal} from "./types/Withdrawal.sol";

/// @title IAvanaFirstLossReserveViews
/// @notice Views of a First-Loss Reserve beyond those Avana contracts read (`IAvanaFirstLossReserve`): the withdrawal delay, the
/// allowlist, the withdrawal queue and the reporting totals. Monitoring, the DAO's payloads and the deployment check
/// read them.
/// @custom:spec REQ-FLR-008, REQ-FLR-017, REQ-FLR-023
interface IAvanaFirstLossReserveViews {
    /// @notice Delay between a withdrawal request and its earliest execution.
    /// @return delay Seconds (`reserveWithdrawalDelay`, 1,209,600).
    /// @custom:spec REQ-FLR-008, SPEC-FLR-003
    function RESERVE_WITHDRAWAL_DELAY() external view returns (uint256 delay);

    /// @notice Whether `spoke`'s deficits on the asset may be covered.
    /// @param spoke The CDP Spoke.
    /// @return allowed Allowlist entry.
    /// @custom:spec REQ-FLR-016, REQ-FLR-017
    function allowedBorrowSpoke(
        address spoke
    ) external view returns (bool allowed);

    /// @notice The instance's Hub added shares, `HUB.getSpokeAddedShares(ASSET_ID, address(this))`.
    /// @return shares Hub added shares.
    /// @custom:spec REQ-FLR-001
    function fundedShares() external view returns (uint256 shares);

    /// @notice A withdrawal request; an ID never requested has status `None`.
    /// @param id Request ID.
    /// @return withdrawal The request.
    /// @custom:spec REQ-FLR-023
    function getWithdrawal(
        uint256 id
    ) external view returns (Withdrawal memory withdrawal);

    /// @notice The ID the next request gets.
    /// @return id Request ID, starting at 1.
    /// @custom:spec REQ-FLR-023
    function nextWithdrawalId() external view returns (uint256 id);

    /// @notice Cumulative amount added through `fund`.
    /// @return amount Asset base units.
    /// @custom:spec REQ-FLR-010
    function totalFunded() external view returns (uint256 amount);

    /// @notice Cumulative deficit eliminated through `coverDeficit`.
    /// @return amount Asset base units.
    /// @custom:spec REQ-FLR-018
    function totalCovered() external view returns (uint256 amount);

    /// @notice Cumulative amount withdrawn through `executeWithdrawal`.
    /// @return amount Asset base units.
    /// @custom:spec REQ-FLR-025
    function totalWithdrawn() external view returns (uint256 amount);
}
