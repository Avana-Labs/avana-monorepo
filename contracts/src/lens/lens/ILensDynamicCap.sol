// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensDynamicCap
/// @notice The per-market dynamic borrow cap view.
interface ILensDynamicCap {
    /// @notice The market's dynamic borrow cap as the next borrow would see it, with the market's debt now.
    /// @dev Reverts while the Lock is held, and `MarketNotActive` for a market without a vault token.
    /// @return cap The running interval's cap, or the cap a new interval would fix on the current debt, 8-decimal USD.
    /// @return debt The market's debt, 8-decimal USD.
    /// @return intervalStart The running interval's start, or the current time when the next borrow opens one.
    function getDynamicBorrowCap(
        uint256 marketId
    ) external view returns (uint256 cap, uint256 debt, uint64 intervalStart);
}
