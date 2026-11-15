// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title SpeedLimitMath
/// @notice The speed-window arithmetic of SPEC-CAP-011 to SPEC-CAP-013: the two-bucket rollover, the window-start base,
/// the clamped limit on it, the fit test, the net credit of a repay or a withdrawal, the next-capacity time and the USD
/// charge of a borrow.
/// @dev Internal pure functions only, inlined into the RiskModule (no linked library). A window of length 0 (a scope
/// never written) rolls to an empty window and every limit of such a scope is 0, so it refuses every positive charge.
/// @custom:spec SPEC-CAP-011, SPEC-CAP-012, SPEC-CAP-013, REQ-RISK-096, Q-411
library SpeedLimitMath {
    /// @dev Basis points of a rate.
    uint256 internal constant BPS = 10_000;

    /// @notice The window as a check at `nowTs` sees it: empty from `start + 2 × window`, rolled once from
    /// `start + window`, unchanged before. Only an unchanged window keeps the stored base and `opened` flag.
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
            r = SpeedWindow({start: w.start, prev: w.prev, curr: w.curr, base: w.base, opened: w.opened});
        }
    }

    /// @notice The base the limit is computed on (SPEC-CAP-012): the stored window-start base while the current bucket
    /// is the one a charge opened, otherwise `sat(liveBase − prev)`, the base read now less the bucket before.
    /// @dev Fixing the base when the bucket opens keeps the limit unchanged by everything that moves the base inside the
    /// bucket: a borrow or pledge cannot raise it, and a repay or withdrawal cannot lower it. Subtracting `prev` takes
    /// out the bucket before, whose net charges are already in the base read at the opening. Example: base $4,000,000
    /// at the opening, `prev` $100,000, so the stored base is $3,900,000 and stays so for the whole bucket.
    /// @param stored The stored window.
    /// @param r The rolled window.
    /// @param liveBase The scope's base read at the check.
    /// @return base The window-start base.
    /// @custom:spec SPEC-CAP-012
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
    /// @param rateBps The scope's rate, bps.
    /// @param min The smallest limit.
    /// @param max The largest limit, at least `min` for a written scope.
    /// @param base The window-start base (`windowBase`).
    /// @return The limit L.
    /// @custom:spec SPEC-CAP-012
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

    /// @notice The rolled window with `x` added to its current bucket and the window-start base recorded, as a new
    /// struct (`r` is left unchanged).
    /// @dev Only after `fits(r, lim, x)` with `lim < 2^96`, so `curr + x ≤ lim` fits `uint96`.
    /// @param r The rolled window.
    /// @param x The charge.
    /// @param base The window-start base the check used (`windowBase`).
    /// @return w The window to store.
    /// @custom:spec SPEC-CAP-011, SPEC-CAP-012
    function add(
        SpeedWindow memory r,
        uint256 x,
        uint256 base
    ) internal pure returns (SpeedWindow memory w) {
        // curr + x <= prev + curr + x <= L <= max < 2^96 (REQ-PSTORE-035).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 curr = uint96(uint256(r.curr) + x);
        // A base above 2^248 - 1 limits like 2^248 - 1: every limit's max fits uint96.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint248 b = base > type(uint248).max ? type(uint248).max : uint248(base);
        w = SpeedWindow({start: r.start, prev: r.prev, curr: curr, base: b, opened: true});
    }

    /// @notice The stored window after a credit of `x` at `nowTs` (a repay or a withdrawal): taken from the current
    /// bucket first, then from the bucket before while it still counts, each floored at zero; unchanged when nothing
    /// in the window counts any more. The bucket frame and the base stay as stored, so a credit reads no base.
    /// @dev Works on the stored frame: from `start + window` the stored `curr` is the rolled window's `prev` and the
    /// stored `prev` no longer counts. Example: window 6 h, stored `start = s`, `prev = 40`, `curr = 100`; a credit of
    /// 120 at `s + 1 h` leaves `curr = 0`, `prev = 20`; the same credit at `s + 7 h` leaves `curr = 0`, `prev = 40`.
    /// @param w The stored window.
    /// @param window The scope's window length, seconds.
    /// @param nowTs The credit's timestamp.
    /// @param x The credit.
    /// @return r The window to store.
    /// @custom:spec SPEC-CAP-011, REQ-RISK-092, REQ-RISK-093
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
