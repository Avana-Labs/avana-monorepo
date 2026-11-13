// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "./types/MarketSpeedLimits.sol";
import {SpeedLimit} from "./types/SpeedLimit.sol";

/// @title ParameterStoreSpeedRules
/// @notice Bounds and change directions of the speed limits (REQ-PSTORE-035, REQ-PSTORE-036).
/// @dev Internal pure functions, inlined into the tighten and loosen logic contracts. Each value is compared field by
/// field on a "looseness" scale where larger is looser: a rate, minimum or maximum as stored, and a window as
/// `2^32 − window`, with a never-written window (0) at looseness 0, the tightest of all, so every valid first value is a
/// loosening and no tightening of a never-written scope exists.
/// @custom:spec REQ-PSTORE-035, REQ-PSTORE-036, REQ-CONFIG-049, Q-411
library ParameterStoreSpeedRules {
    /// @dev Shortest window, seconds (one hour).
    uint32 internal constant SPEED_WINDOW_MIN = 3600;
    /// @dev Longest window, seconds (seven days).
    uint32 internal constant SPEED_WINDOW_MAX = 604_800;
    /// @dev Largest rate, bps.
    uint16 internal constant SPEED_RATE_MAX = 10_000;

    /// @notice Whether a market value is within the bounds of REQ-PSTORE-035.
    /// @param v The value.
    /// @return ok True when within bounds.
    /// @custom:spec REQ-PSTORE-035
    function validMarket(
        MarketSpeedLimits memory v
    ) internal pure returns (bool) {
        return _validWindow(v.window) && v.borrowRateBps <= SPEED_RATE_MAX && v.pledgeRateBps <= SPEED_RATE_MAX
            && v.borrowMinUsd <= v.borrowMaxUsd && v.pledgeMinUsd <= v.pledgeMaxUsd;
    }

    /// @notice Whether a (Hub, asset) value is within the bounds of REQ-PSTORE-035.
    /// @param v The value.
    /// @return ok True when within bounds.
    /// @custom:spec REQ-PSTORE-035
    function validDebt(
        SpeedLimit memory v
    ) internal pure returns (bool) {
        return _validWindow(v.window) && v.rateBps <= SPEED_RATE_MAX && v.min <= v.max;
    }

    /// @notice How `b` compares with `a`, field by field, for market values.
    /// @param a The reference value.
    /// @param b The compared value.
    /// @return noLooser True when no field of `b` is looser than `a`'s.
    /// @return stricter True when some field of `b` is strictly tighter than `a`'s.
    /// @custom:spec REQ-PSTORE-036
    function compareMarket(
        MarketSpeedLimits memory a,
        MarketSpeedLimits memory b
    ) internal pure returns (bool noLooser, bool stricter) {
        uint256[7] memory x = [
            _windowLooseness(a.window),
            a.borrowRateBps,
            a.pledgeRateBps,
            a.borrowMinUsd,
            a.borrowMaxUsd,
            a.pledgeMinUsd,
            a.pledgeMaxUsd
        ];
        uint256[7] memory y = [
            _windowLooseness(b.window),
            b.borrowRateBps,
            b.pledgeRateBps,
            b.borrowMinUsd,
            b.borrowMaxUsd,
            b.pledgeMinUsd,
            b.pledgeMaxUsd
        ];
        noLooser = true;
        for (uint256 i = 0; i < 7; ++i) {
            if (y[i] > x[i]) noLooser = false;
            if (y[i] < x[i]) stricter = true;
        }
    }

    /// @notice How `b` compares with `a`, field by field, for (Hub, asset) values.
    /// @param a The reference value.
    /// @param b The compared value.
    /// @return noLooser True when no field of `b` is looser than `a`'s.
    /// @return stricter True when some field of `b` is strictly tighter than `a`'s.
    /// @custom:spec REQ-PSTORE-036
    function compareDebt(
        SpeedLimit memory a,
        SpeedLimit memory b
    ) internal pure returns (bool noLooser, bool stricter) {
        uint256[4] memory x = [_windowLooseness(a.window), a.rateBps, a.min, a.max];
        uint256[4] memory y = [_windowLooseness(b.window), b.rateBps, b.min, b.max];
        noLooser = true;
        for (uint256 i = 0; i < 4; ++i) {
            if (y[i] > x[i]) noLooser = false;
            if (y[i] < x[i]) stricter = true;
        }
    }

    /// @dev A window within `[SPEED_WINDOW_MIN, SPEED_WINDOW_MAX]`.
    function _validWindow(
        uint32 window
    ) private pure returns (bool) {
        return window >= SPEED_WINDOW_MIN && window <= SPEED_WINDOW_MAX;
    }

    /// @dev Looseness of a window: shorter is looser; a never-written window (0) is the tightest.
    function _windowLooseness(
        uint32 window
    ) private pure returns (uint256) {
        return window == 0 ? 0 : (uint256(1) << 32) - window;
    }
}
