// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits, SpeedLimit} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreSpeedRules
/// @notice Bounds and change directions of the speed limits.
/// @dev Fields compare on a looseness scale where larger is looser; a never-written window (0) is the tightest.
library ParameterStoreSpeedRules {
    /// @dev Shortest window, seconds (one hour).
    uint32 internal constant SPEED_WINDOW_MIN = 3600;
    /// @dev Longest window, seconds (seven days).
    uint32 internal constant SPEED_WINDOW_MAX = 604_800;
    uint16 internal constant SPEED_RATE_MAX = 10_000;

    /// @notice Whether a market value is within bounds.
    function validMarket(
        MarketSpeedLimits memory v
    ) internal pure returns (bool) {
        return _validWindow(v.window) && v.borrowRateBps <= SPEED_RATE_MAX && v.pledgeRateBps <= SPEED_RATE_MAX
            && v.borrowMinUsd <= v.borrowMaxUsd && v.pledgeMinUsd <= v.pledgeMaxUsd;
    }

    /// @notice Whether a (Hub, asset) value is within bounds.
    function validDebt(
        SpeedLimit memory v
    ) internal pure returns (bool) {
        return _validWindow(v.window) && v.rateBps <= SPEED_RATE_MAX && v.min <= v.max;
    }

    /// @notice How `b` compares with `a`, field by field, for market values.
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
