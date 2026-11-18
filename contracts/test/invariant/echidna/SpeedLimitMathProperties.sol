// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedLimitMath} from "../../../src/policy/risk-module/SpeedLimitMath.sol";
import {SpeedWindow} from "../../../src/policy/risk-module/types/RiskModuleTypes.sol";

/// @title SpeedLimitMathProperties
/// @notice Echidna and Medusa harness of the net-flow speed-window arithmetic (2.7 SPEC-CAP-011 to SPEC-CAP-013, Q-411):
/// one window charged and credited by random amounts at random times against a fixed limit, with a log of the last
/// charges and applied credits so the net interval bound is checked after every transaction.
/// @dev Times advance through `block.timestamp` (the fuzzers jump up to 14 days per call); each log keeps the last 32
/// entries, and the interval property is checked only while neither log has dropped an entry inside the interval
/// (credits let charges repeat without bound). The window length is the default τ.
contract SpeedLimitMathProperties {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant LIM = 1_000_000e8;
    uint256 internal constant LOG = 32;

    SpeedWindow internal w;
    uint256[LOG] internal ts;
    uint256[LOG] internal xs;
    uint256 internal n;
    uint256[LOG] internal cts;
    uint256[LOG] internal cxs;
    uint256 internal cn;

    /// @notice Charges `x` (bounded below 2L) now if it fits; logs it when it passes.
    function charge(
        uint128 x
    ) public {
        uint256 amount = uint256(x) % (2 * LIM);
        SpeedWindow memory r = SpeedLimitMath.roll(w, TAU, block.timestamp);
        assert(r.start <= block.timestamp && uint256(r.start) + TAU > block.timestamp);
        bool ok = SpeedLimitMath.fits(r, LIM, amount);
        assert(ok == (SpeedLimitMath.used(r) + amount <= LIM));
        if (!ok) return;
        w = SpeedLimitMath.add(r, amount, 0);
        ts[n % LOG] = block.timestamp;
        xs[n % LOG] = amount;
        ++n;
    }

    /// @notice Credits `x` now (a repay or a withdrawal) and logs what it took; it never adds and never goes below
    /// zero.
    function credit(
        uint128 x
    ) public {
        uint256 before = SpeedLimitMath.used(SpeedLimitMath.roll(w, TAU, block.timestamp));
        w = SpeedLimitMath.credit(w, TAU, block.timestamp, x);
        uint256 afterCredit = SpeedLimitMath.used(SpeedLimitMath.roll(w, TAU, block.timestamp));
        assert(afterCredit <= before && before - afterCredit == (x < before ? x : before));
        cts[cn % LOG] = block.timestamp;
        cxs[cn % LOG] = before - afterCredit;
        ++cn;
    }

    /// @notice The clamp: within its bounds and monotone in the window-start base.
    function clamp(
        uint16 rate,
        uint96 a,
        uint96 b,
        uint128 base
    ) public pure {
        uint256 r = uint256(rate) % 10_001;
        (uint256 lo, uint256 hi) = a <= b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 l0 = SpeedLimitMath.limit(r, lo, hi, base);
        assert(l0 >= lo && l0 <= hi);
        assert(SpeedLimitMath.limit(r, lo, hi, uint256(base) + 1) >= l0);
    }

    /// @notice The USD charge is the ceiling for 6- and 18-decimal assets.
    function usd(
        uint128 amount,
        uint64 price,
        bool eighteen
    ) public pure {
        uint8 dec = eighteen ? 18 : 6;
        uint256 c = SpeedLimitMath.usdOf(amount, price, dec);
        uint256 exact = uint256(amount) * price;
        assert(c * 10 ** dec >= exact && c * 10 ** dec < exact + 10 ** dec);
    }

    /// @notice No interval of length τ ending now holds more net charge (charges less applied credits) than the limit,
    /// among the logged entries.
    function property_noTauIntervalAboveTheLimit() public view returns (bool) {
        // A log that has dropped an entry inside the interval cannot judge it.
        if (n >= LOG && ts[n % LOG] + TAU > block.timestamp) return true;
        if (cn >= LOG && cts[cn % LOG] + TAU > block.timestamp) return true;
        uint256 s = 0;
        uint256 m = n < LOG ? n : LOG;
        for (uint256 i = 0; i < m; ++i) {
            if (ts[i] + TAU > block.timestamp) s += xs[i];
        }
        uint256 c = 0;
        m = cn < LOG ? cn : LOG;
        for (uint256 i = 0; i < m; ++i) {
            if (cts[i] + TAU > block.timestamp) c += cxs[i];
        }
        return s <= LIM + c;
    }

    /// @notice The stored window never holds more than the limit.
    function property_windowWithinTheLimit() public view returns (bool) {
        return uint256(w.prev) + w.curr <= LIM;
    }
}
