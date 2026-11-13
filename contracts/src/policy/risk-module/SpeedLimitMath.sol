// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SpeedLimitMath
/// @notice The speed-window arithmetic of SPEC-CAP-011 to SPEC-CAP-013: the two-bucket rollover, the clamped limit on
/// the base without the window's own charges, the fit test, the next-capacity time and the USD charge of a borrow.
/// @dev Internal pure functions only, inlined into the RiskModule (no linked library). A window of length 0 (a scope
/// never written) rolls to an empty window and every limit of such a scope is 0, so it refuses every positive charge.
/// @custom:spec SPEC-CAP-011, SPEC-CAP-012, SPEC-CAP-013, REQ-RISK-096, Q-411
library SpeedLimitMath {
    /// @dev Basis points of a rate.
    uint256 internal constant BPS = 10_000;

    /// @notice The window as a check at `nowTs` sees it: empty from `start + 2 × window`, rolled once from
    /// `start + window`, unchanged before.
    /// @param w The stored window.
    /// @param window The scope's window length, seconds.
    /// @param nowTs The check's timestamp, at least `w.start`.
    /// @return r The rolled window.
    /// @custom:spec SPEC-CAP-011
    function roll(
        SpeedWindow memory w,
        uint256 window,
        uint256 nowTs
    ) internal pure returns (SpeedWindow memory r) {
        uint256 start = w.start;
        if (nowTs >= start + 2 * window) {
            // Block timestamps stay far below 2^64 seconds.
            // forge-lint: disable-next-line(unsafe-typecast)
            r.start = uint64(nowTs);
        } else if (nowTs >= start + window) {
            // start + window <= nowTs < 2^64.
            // forge-lint: disable-next-line(unsafe-typecast)
            r.start = uint64(start + window);
            r.prev = w.curr;
        } else {
            r = SpeedWindow({start: w.start, prev: w.prev, curr: w.curr});
        }
    }

    /// @notice `L = min(max, max(min, ⌊rate × sat(base − used) / 10^4⌋))`.
    /// @dev Subtracting the window's own charges keeps the limit at the value of the base before them, so a split
    /// borrow cannot raise it inside the window (SPEC-CAP-012).
    /// @param rateBps The scope's rate, bps.
    /// @param min The smallest limit.
    /// @param max The largest limit, at least `min` for a written scope.
    /// @param base The scope's base read at the check.
    /// @param charged `prev + curr` after the rollover.
    /// @return The limit L.
    /// @custom:spec SPEC-CAP-012
    function limit(
        uint256 rateBps,
        uint256 min,
        uint256 max,
        uint256 base,
        uint256 charged
    ) internal pure returns (uint256) {
        uint256 net = base > charged ? base - charged : 0;
        uint256 q = Math.mulDiv(rateBps, net, BPS);
        if (q < min) q = min;
        if (q > max) q = max;
        return q;
    }

    /// @notice Charges still counting in a rolled window.
    /// @param r The rolled window.
    /// @return used `prev + curr`.
    function used(
        SpeedWindow memory r
    ) internal pure returns (uint256) {
        return uint256(r.prev) + r.curr;
    }

    /// @notice Whether a charge `x` fits: `prev + curr + x ≤ L`, written without overflow for any `x`.
    /// @param r The rolled window.
    /// @param lim The limit L.
    /// @param x The charge.
    /// @return ok True when it fits.
    /// @custom:spec SPEC-CAP-011
    function fits(
        SpeedWindow memory r,
        uint256 lim,
        uint256 x
    ) internal pure returns (bool) {
        uint256 u = used(r);
        return u <= lim && x <= lim - u;
    }

    /// @notice The rolled window with `x` added to its current bucket, as a new struct (`r` is left unchanged).
    /// @dev Only after `fits(r, lim, x)` with `lim < 2^96`, so `curr + x ≤ lim` fits `uint96`.
    /// @param r The rolled window.
    /// @param x The charge.
    /// @return w The window to store.
    /// @custom:spec SPEC-CAP-011
    function add(
        SpeedWindow memory r,
        uint256 x
    ) internal pure returns (SpeedWindow memory w) {
        // curr + x <= prev + curr + x <= L <= max < 2^96 (REQ-PSTORE-035).
        // forge-lint: disable-next-line(unsafe-typecast)
        w = SpeedWindow({start: r.start, prev: r.prev, curr: uint96(uint256(r.curr) + x)});
    }

    /// @notice When the next charges stop counting and how much: `start + window` with `prev`, else
    /// `start + 2 × window` with `curr`, else `(0, 0)`.
    /// @param r The rolled window.
    /// @param window The scope's window length, seconds.
    /// @return at The time, or 0.
    /// @return amount The amount freed then.
    /// @custom:spec SPEC-CAP-011, REQ-RISK-097
    function moreAt(
        SpeedWindow memory r,
        uint256 window
    ) internal pure returns (uint64 at, uint256 amount) {
        if (r.prev > 0) {
            // start + window < 2^64 for any stored window of a written scope.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (uint64(uint256(r.start) + window), r.prev);
        }
        if (r.curr > 0) {
            // As above.
            // forge-lint: disable-next-line(unsafe-typecast)
            return (uint64(uint256(r.start) + 2 * window), r.curr);
        }
    }

    /// @notice The view of a rolled window under limit `lim` (REQ-RISK-097).
    /// @param r The rolled window.
    /// @param window The scope's window length, seconds.
    /// @param lim The limit L.
    /// @return v The view.
    /// @custom:spec REQ-RISK-097
    function viewOf(
        SpeedWindow memory r,
        uint256 window,
        uint256 lim
    ) internal pure returns (SpeedView memory v) {
        v.limit = lim;
        v.used = used(r);
        v.available = lim > v.used ? lim - v.used : 0;
        (v.moreAt, v.moreAmount) = moreAt(r, window);
    }

    /// @notice USD charge of a borrow: `⌈amount × price8 / 10^decimals⌉`, against the borrower (SPEC-CAP-013).
    /// @param amount Borrowed base units.
    /// @param price8 The reserve's 8-decimal USD price.
    /// @param decimals The asset's decimals.
    /// @return usd 8-decimal USD.
    /// @custom:spec SPEC-CAP-013
    function usdOf(
        uint256 amount,
        uint256 price8,
        uint8 decimals
    ) internal pure returns (uint256) {
        return Math.mulDiv(amount, price8, 10 ** decimals, Math.Rounding.Ceil);
    }
}
