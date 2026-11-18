// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SpeedLimitMath
/// @notice Speed-window arithmetic: rollover, base, limit, fit test, credits and a borrow's USD charge.
/// @dev A scope never written (window length 0) has limit 0, so it refuses every positive charge.
library SpeedLimitMath {
    uint256 internal constant BPS = 10_000;

    /// @notice The window as a check at `nowTs` sees it; only an unchanged window keeps its base and `opened` flag.
    /// @param window The scope's window length, seconds.
    /// @param nowTs The check's timestamp, at least `w.start`.
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
            r = SpeedWindow({start: w.start, prev: w.prev, curr: w.curr, base: w.base, opened: w.opened});
        }
    }

    /// @notice The base the limit is computed on: the stored base while its bucket is current, else `liveBase - prev`.
    /// @dev Fixing the base when the bucket opens keeps the limit unchanged by flows inside the bucket.
    function windowBase(
        SpeedWindow memory stored,
        SpeedWindow memory r,
        uint256 liveBase
    ) internal pure returns (uint256 base) {
        if (stored.opened && stored.start == r.start) return stored.base;
        uint256 prev = r.prev;
        base = liveBase > prev ? liveBase - prev : 0;
    }

    /// @notice `L = min(max, max(min, ⌊rate × base / 10^4⌋))` on the window-start base.
    function limit(
        uint256 rateBps,
        uint256 min,
        uint256 max,
        uint256 base
    ) internal pure returns (uint256) {
        uint256 q = Math.mulDiv(rateBps, base, BPS);
        if (q < min) q = min;
        if (q > max) q = max;
        return q;
    }

    function used(
        SpeedWindow memory r
    ) internal pure returns (uint256) {
        return uint256(r.prev) + r.curr;
    }

    /// @notice Whether a charge `x` fits: `prev + curr + x ≤ L`, written without overflow for any `x`.
    function fits(
        SpeedWindow memory r,
        uint256 lim,
        uint256 x
    ) internal pure returns (bool) {
        uint256 u = used(r);
        return u <= lim && x <= lim - u;
    }

    /// @notice The rolled window with `x` added to its current bucket and the window-start base recorded.
    /// @dev Only after `fits(r, lim, x)` with `lim < 2^96`, so `curr + x ≤ lim` fits `uint96`.
    function add(
        SpeedWindow memory r,
        uint256 x,
        uint256 base
    ) internal pure returns (SpeedWindow memory w) {
        // curr + x <= prev + curr + x <= L <= max < 2^96.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 curr = uint96(uint256(r.curr) + x);
        // A base above 2^248 - 1 limits like 2^248 - 1: every limit's max fits uint96.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint248 b = base > type(uint248).max ? type(uint248).max : uint248(base);
        w = SpeedWindow({start: r.start, prev: r.prev, curr: curr, base: b, opened: true});
    }

    /// @notice The stored window after a credit of `x`: taken from `curr`, then `prev` while it counts, floored at 0.
    /// @param window The scope's window length, seconds.
    function credit(
        SpeedWindow memory w,
        uint256 window,
        uint256 nowTs,
        uint256 x
    ) internal pure returns (SpeedWindow memory r) {
        r = SpeedWindow({start: w.start, prev: w.prev, curr: w.curr, base: w.base, opened: w.opened});
        uint256 start = w.start;
        if (window == 0 || nowTs >= start + 2 * window) return r;
        uint256 c = r.curr;
        uint256 take = x < c ? x : c;
        // take <= curr < 2^96.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.curr = uint96(c - take);
        if (nowTs >= start + window) return r;
        uint256 rest = x - take;
        uint256 p = r.prev;
        // The result is below prev < 2^96, or 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.prev = uint96(rest < p ? p - rest : 0);
    }

    /// @notice When the next charges stop counting and how much, or `(0, 0)` for an empty window.
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

    /// @notice USD charge of a borrow, rounded up.
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
