// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketDynamicCap} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreCapRules
/// @notice Bounds and change directions of a market's dynamic borrow cap terms.
/// @dev Fields compare on a looseness scale where larger is looser; a never-written interval (0) is the tightest.
library ParameterStoreCapRules {
    /// @dev Shortest interval, seconds (one hour).
    uint32 internal constant CAP_INTERVAL_MIN = 3600;
    /// @dev Longest interval, seconds (seven days).
    uint32 internal constant CAP_INTERVAL_MAX = 604_800;
    uint16 internal constant CAP_ALPHA_MAX = 10_000;

    /// @notice Whether a value is within bounds.
    function valid(
        MarketDynamicCap memory v
    ) internal pure returns (bool) {
        return v.capInterval >= CAP_INTERVAL_MIN && v.capInterval <= CAP_INTERVAL_MAX && v.capAlphaBps <= CAP_ALPHA_MAX
            && v.capBufferMin <= v.capBufferMax;
    }

    /// @notice How `b` compares with `a`, field by field.
    function compare(
        MarketDynamicCap memory a,
        MarketDynamicCap memory b
    ) internal pure returns (bool noLooser, bool stricter) {
        uint256[4] memory x = [_intervalLooseness(a.capInterval), a.capAlphaBps, a.capBufferMin, a.capBufferMax];
        uint256[4] memory y = [_intervalLooseness(b.capInterval), b.capAlphaBps, b.capBufferMin, b.capBufferMax];
        noLooser = true;
        for (uint256 i = 0; i < 4; ++i) {
            if (y[i] > x[i]) noLooser = false;
            if (y[i] < x[i]) stricter = true;
        }
    }

    /// @dev Looseness of an interval: shorter is looser; a never-written interval (0) is the tightest.
    function _intervalLooseness(
        uint32 interval
    ) private pure returns (uint256) {
        return interval == 0 ? 0 : (uint256(1) << 32) - interval;
    }
}
