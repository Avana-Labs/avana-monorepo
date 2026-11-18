// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Withdrawal} from "./types/Withdrawal.sol";

/// @title IAvanaFirstLossReserveViews
/// @notice Views of a First-Loss Reserve for monitoring, DAO payloads and the deployment check.
interface IAvanaFirstLossReserveViews {
    /// @notice Delay between a withdrawal request and its earliest execution.
    /// @return delay Seconds.
    function RESERVE_WITHDRAWAL_DELAY() external view returns (uint256 delay);

    /// @notice Whether `spoke`'s deficits on the asset may be covered.
    function allowedBorrowSpoke(
        address spoke
    ) external view returns (bool allowed);

    /// @notice The instance's Hub added shares.
    function fundedShares() external view returns (uint256 shares);

    /// @notice A withdrawal request; an ID never requested has status `None`.
    function getWithdrawal(
        uint256 id
    ) external view returns (Withdrawal memory withdrawal);

    /// @notice The ID the next request gets.
    function nextWithdrawalId() external view returns (uint256 id);

    /// @notice Cumulative amount added through `fund`.
    function totalFunded() external view returns (uint256 amount);

    /// @notice Cumulative deficit eliminated through `coverDeficit`.
    function totalCovered() external view returns (uint256 amount);

    /// @notice Cumulative amount withdrawn through `executeWithdrawal`.
    function totalWithdrawn() external view returns (uint256 amount);
}
