// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketDynamicCap} from "../parameter-store/types/ParameterStoreTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title DynamicCapMath
/// @notice Dynamic borrow cap arithmetic: buffer, target cap, interval rollover and a borrow's USD amount.
/// @dev A never-written market (all terms 0) has buffer 0, so its cap equals its debt and it refuses every borrow.
library DynamicCapMath {
    uint256 internal constant BPS = 10_000;

    /// @notice The buffer `L = min(L_max, max(L_min, ⌊alpha × D / 10^4⌋))`.
    /// @param debt The market's debt `D`, 8-decimal USD.
    function buffer(
        MarketDynamicCap memory terms,
        uint256 debt
    ) internal pure returns (uint256 l) {
        l = Math.mulDiv(terms.capAlphaBps, debt, BPS);
        if (l < terms.capBufferMin) l = terms.capBufferMin;
        if (l > terms.capBufferMax) l = terms.capBufferMax;
    }

    /// @notice The target cap `C = D + L(D)`, saturated at `type(uint192).max`.
    function target(
        MarketDynamicCap memory terms,
        uint256 debt
    ) internal pure returns (uint192) {
        uint256 c = debt + buffer(terms, debt);
        // Saturated above, so the cast fits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return c > type(uint192).max ? type(uint192).max : uint192(c);
    }

    /// @notice Whether a borrow at `nowTs` opens a new interval.
    function opensInterval(
        uint256 intervalStart,
        uint256 capInterval,
        uint256 nowTs
    ) internal pure returns (bool) {
        return nowTs >= intervalStart + capInterval;
    }

    /// @notice USD value of a borrow, rounded up.
    /// @param amount Borrowed base units.
    /// @param price8 The reserve's 8-decimal USD price.
    function usdOf(
        uint256 amount,
        uint256 price8,
        uint8 decimals
    ) internal pure returns (uint256) {
        return Math.mulDiv(amount, price8, 10 ** decimals, Math.Rounding.Ceil);
    }
}
