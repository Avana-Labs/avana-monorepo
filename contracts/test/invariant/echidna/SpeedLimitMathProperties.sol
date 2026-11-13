// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedLimitMath} from "../../../src/policy/risk-module/SpeedLimitMath.sol";
import {SpeedWindow} from "../../../src/policy/risk-module/types/SpeedWindow.sol";

/// @title SpeedLimitMathProperties
/// @notice Echidna and Medusa harness of the speed-window arithmetic (2.7 SPEC-CAP-011 to SPEC-CAP-013, Q-411): one
/// window charged by random amounts at random times against a fixed limit, with a log of the last charges so the
/// interval bound is checked after every transaction.
/// @dev Times advance through `block.timestamp` (the fuzzers jump up to 14 days per call); the log keeps the last 32
/// passing charges, enough for any interval of τ at the charge rate the cap allows. The window length is the launch τ.
contract SpeedLimitMathProperties {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant LIM = 1_000_000e8;
    uint256 internal constant LOG = 32;

    SpeedWindow internal w;
    uint256[LOG] internal ts;
    uint256[LOG] internal xs;
    uint256 internal n;

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
        w = SpeedLimitMath.add(r, amount);
        ts[n % LOG] = block.timestamp;
        xs[n % LOG] = amount;
        ++n;
    }

    /// @notice The clamp: within its bounds, monotone, and blind to the window's own charges.
    function clamp(
        uint16 rate,
        uint96 a,
        uint96 b,
        uint128 base,
        uint96 used
    ) public pure {
        uint256 r = uint256(rate) % 10_001;
        (uint256 lo, uint256 hi) = a <= b ? (uint256(a), uint256(b)) : (uint256(b), uint256(a));
        uint256 l0 = SpeedLimitMath.limit(r, lo, hi, base, 0);
        assert(l0 >= lo && l0 <= hi);
        assert(SpeedLimitMath.limit(r, lo, hi, uint256(base) + used, used) == l0);
        assert(SpeedLimitMath.limit(r, lo, hi, uint256(base) + 1, 0) >= l0);
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

    /// @notice No interval of length τ ending now holds more than the limit, among the logged charges.
    function property_noTauIntervalAboveTheLimit() public view returns (bool) {
        uint256 s = 0;
        uint256 m = n < LOG ? n : LOG;
        for (uint256 i = 0; i < m; ++i) {
            if (ts[i] + TAU > block.timestamp) s += xs[i];
        }
        return s <= LIM;
    }

    /// @notice The stored window never holds more than the limit.
    function property_windowWithinTheLimit() public view returns (bool) {
        return uint256(w.prev) + w.curr <= LIM;
    }
}
