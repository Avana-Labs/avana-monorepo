// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../../src/oracle/lp-oracle/LPPriceMath.sol";
import {PriceState} from "../../../src/types/PriceState.sol";

/// @title LPPriceMathProperties
/// @notice Echidna and Medusa properties of the internal library LPPriceMath (2.10). Assertion entry points check each
/// formula on fuzzed inputs bounded to the listing bounds (answers below `2^128`, prices at most `MAX_ROUTE_ANSWER`,
/// amounts below `2^128`): normalisation and route values round down, the agreement and second-source tests are exact
/// and symmetric, the stable ceiling never raises a price and is monotone, the vault-token price is at least 1, never
/// above the holdings and independent of token order, the served collateral price is at least 1 and at most the
/// accepted price unless Live, the served debt price at least the accepted price unless Live, the sequencer states
/// partition, and the observation buffer and gas guard are the smallest values that work. Each entry point records its
/// last served prices, which the `property_` functions check after every transaction.
/// @dev Inputs are bounded with `%`, never with a cheatcode, and every branch is on a concrete case, so hevm can prove
/// each entry point.
contract LPPriceMathProperties {
    uint256 internal constant MAX_ROUTE = 1e12;
    uint256 internal constant AMOUNT_BOUND = 2 ** 128;

    /// @notice Number of assertion calls; written so each call is a transaction.
    uint256 public checks;
    /// @notice Last served collateral price, its accepted price and state.
    uint256 public lastServed = 1;
    uint256 public lastAccepted = 1;
    PriceState public lastState;
    /// @notice Last served debt price, its accepted price and state.
    uint256 public lastDebtServed = 1;
    uint256 public lastDebtAccepted = 1;
    PriceState public lastDebtState;

    // ─── Properties ───

    function property_constantsMatchTheSpec() external pure returns (bool) {
        return LPPriceMath.DECIMALS == 8 && LPPriceMath.STABLE_CEILING_USD == 1e8
            && LPPriceMath.MAX_ROUTE_ANSWER == 1e12 && LPPriceMath.POST_CALL_GAS == 5000
            && LPPriceMath.MIN_VAULT_DECIMALS == 6 && LPPriceMath.MAX_VAULT_DECIMALS == 18;
    }

    function property_specExamplesHold() external pure returns (bool) {
        return LPPriceMath.normalizeAnswer(999_870_000_000_000_000, 18) == 99_987_000
            && LPPriceMath.routeValue(333_300_000_000_000, 18, 300_000_000_000, 8) == 99_990_000
            && LPPriceMath.feedMaxAge(86_400, 1800) == 88_200 && LPPriceMath.minObservations(1800, 2) == 901
            && LPPriceMath.gasForCall(50_000) == 55_794 && LPPriceMath.pokeMinGasFloor(450_000, 100_000) == 556_588;
    }

    function property_servedCollateralAtLeastOne() external view returns (bool) {
        return lastServed >= 1;
    }

    function property_servedCollateralAtMostAcceptedUnlessLive() external view returns (bool) {
        return lastState == PriceState.Live || lastServed <= lastAccepted;
    }

    function property_servedDebtAtLeastAcceptedUnlessLive() external view returns (bool) {
        return lastDebtServed >= 1 && (lastDebtState == PriceState.Live || lastDebtServed >= lastDebtAccepted);
    }

    // ─── Assertion entry points ───

    /// @notice `SPEC-ORC-001`: exact at 8 or fewer decimals, otherwise rounded down by less than one unit.
    function checkNormalize(
        uint256 answer,
        uint8 decimals
    ) external {
        answer %= AMOUNT_BOUND;
        decimals %= 37;
        uint256 n = LPPriceMath.normalizeAnswer(int256(answer), decimals);
        if (decimals <= 8) {
            assert(n == answer * 10 ** (8 - decimals));
        } else {
            uint256 unit = 10 ** (decimals - 8);
            assert(n * unit <= answer && answer < (n + 1) * unit);
        }
        ++checks;
    }

    /// @notice `SPEC-ORC-001`: a signed answer outside `(0, 2^128)` normalises to 0 at every decimals, never reverting.
    function checkNormalizeSigned(
        int256 answer,
        uint8 decimals
    ) external {
        uint256 n = LPPriceMath.normalizeAnswer(answer, decimals);
        if (answer <= 0 || answer >= int256(AMOUNT_BOUND)) assert(n == 0);
        ++checks;
    }

    /// @notice `SPEC-ORC-011`: the USD level is the largest level whose fixed-point power is at most the product, and
    /// a band low passes exactly when it is at most the level.
    function checkUsdLevel(
        uint256 q0,
        uint256 q1,
        uint256 q2,
        bool three,
        uint256 low
    ) external {
        uint256 n = three ? 3 : 2;
        uint256[] memory q = new uint256[](n);
        q[0] = 1 + q0 % MAX_ROUTE;
        q[1] = 1 + q1 % MAX_ROUTE;
        if (three) q[2] = 1 + q2 % MAX_ROUTE;
        uint256 product = LPPriceMath.fixedPointProduct(q);
        uint256 level = LPPriceMath.usdLevel(q);
        assert(LPPriceMath.fixedPointPower(level, n) <= product);
        assert(LPPriceMath.fixedPointPower(level + 1, n) > product);
        low %= 2 * MAX_ROUTE;
        (bool valid, bool inBand) = LPPriceMath.inUsdBand(q, q, low, type(uint256).max);
        assert(valid && inBand == (low <= level));
        ++checks;
    }

    /// @notice `SPEC-ORC-002`: two-leg route rounds down; invalid below 8 decimals in total.
    function checkRoute(
        uint256 answerA,
        uint8 decimalsA,
        uint256 answerB,
        uint8 decimalsB
    ) external {
        answerA %= AMOUNT_BOUND;
        answerB %= AMOUNT_BOUND;
        decimalsA %= 37;
        decimalsB %= 37;
        uint256 r = LPPriceMath.routeValue(int256(answerA), decimalsA, int256(answerB), decimalsB);
        uint256 sum = uint256(decimalsA) + decimalsB;
        if (sum < 8) assert(r == 0);
        else assert(r == answerA * answerB / 10 ** (sum - 8));
        ++checks;
    }

    /// @notice `SPEC-ORC-003`, `SPEC-ORC-020`: exact, symmetric, and the second source needs validity.
    function checkAgreement(
        uint256 p,
        uint256 b,
        uint16 t,
        bool valid
    ) external {
        p %= AMOUNT_BOUND;
        b %= AMOUNT_BOUND;
        bool agree = LPPriceMath.routesAgree(p, b, t);
        assert(agree == LPPriceMath.routesAgree(b, p, t));
        uint256 diff = p > b ? p - b : b - p;
        uint256 lo = p < b ? p : b;
        assert(agree == (diff * 10_000 <= uint256(t) * lo));
        assert(LPPriceMath.secondSourceAgrees(valid, p, b, t) == (valid && agree));
        ++checks;
    }

    /// @notice `SPEC-ORC-004`: the ceiling never raises a price and is monotone.
    function checkCeiling(
        uint256 q1,
        uint256 q2,
        bool stable
    ) external {
        if (q1 > q2) (q1, q2) = (q2, q1);
        uint256 v1 = LPPriceMath.valuationPrice(q1, stable);
        uint256 v2 = LPPriceMath.valuationPrice(q2, stable);
        assert(v1 <= q1 && v1 <= v2);
        if (stable) assert(v2 <= LPPriceMath.STABLE_CEILING_USD);
        ++checks;
    }

    /// @notice `SPEC-ORC-008`: at least 1, never above the holdings, independent of token order. `pair` picks the
    /// decimals: 0 (6, 6), 1 (18, 6), otherwise (18, 18).
    function checkLpPrice(
        uint256 a0,
        uint256 a1,
        uint256 v0,
        uint256 v1,
        uint8 pair
    ) external {
        a0 %= AMOUNT_BOUND;
        a1 %= AMOUNT_BOUND;
        v0 = 1 + v0 % MAX_ROUTE;
        v1 = 1 + v1 % MAX_ROUTE;
        uint8 d0 = 18;
        uint8 d1 = 18;
        if (pair == 0) (d0, d1) = (6, 6);
        else if (pair == 1) (d0, d1) = (18, 6);
        (bool valid, uint256 price8) = LPPriceMath.lpPrice(_pair(a0, a1), _pair(v0, v1), _decimals(d0, d1));
        assert(valid);
        assert(price8 >= 1);
        uint256 exactScaled = a0 * v0 * 10 ** d1 + a1 * v1 * 10 ** d0;
        uint256 one = 10 ** (uint256(d0) + d1);
        if (exactScaled >= one) assert(price8 * one <= exactScaled);
        (, uint256 reverse) = LPPriceMath.lpPrice(_pair(a1, a0), _pair(v1, v0), _decimals(d1, d0));
        assert(price8 == reverse);
        ++checks;
    }

    /// @notice `SPEC-ORC-017`: served collateral price by state; recorded for the properties.
    function checkServed(
        uint8 stateRaw,
        bool disagreeing,
        uint256 fresh,
        uint256 lower,
        uint256 accepted
    ) external {
        PriceState state = PriceState(stateRaw % 4);
        fresh = 1 + fresh % MAX_ROUTE;
        // Unconstrained against fresh: the floored lower-route price can exceed the floored fresh price.
        lower = lower % (2 * MAX_ROUTE);
        accepted = 1 + accepted % MAX_ROUTE;
        uint256 served = LPPriceMath.servedPrice(state, disagreeing, fresh, lower, accepted);
        assert(served >= 1);
        if (state != PriceState.Live) assert(served <= accepted);
        if (state == PriceState.Expired) assert(served == 1);
        if (state != PriceState.Cached && state != PriceState.Expired) assert(served <= fresh);
        (lastServed, lastAccepted, lastState) = (served, accepted, state);
        ++checks;
    }

    /// @notice `SPEC-ORC-018`: served debt price by state; recorded for the properties.
    function checkDebtServed(
        uint8 stateRaw,
        uint256 q,
        uint256 p,
        uint256 b,
        uint256 accepted,
        uint256 rise
    ) external {
        PriceState state = PriceState(stateRaw % 4);
        q = 1 + q % MAX_ROUTE;
        p = 1 + p % MAX_ROUTE;
        b = 1 + b % MAX_ROUTE;
        accepted = 1 + accepted % MAX_ROUTE;
        rise = 100 + rise % 4901;
        uint256 served = LPPriceMath.debtServedPrice(state, q, p, b, accepted, rise);
        assert(served >= 1);
        if (state != PriceState.Live) assert(served >= accepted);
        if (state == PriceState.Expired) assert(served > accepted && served * 2 <= accepted * 3 + 2);
        (lastDebtServed, lastDebtAccepted, lastDebtState) = (served, accepted, state);
        ++checks;
    }

    /// @notice `SPEC-ORC-021`: with a feed, exactly one of up, down and unknown; up is grace or ready.
    function checkSequencer(
        bool readOk,
        int8 answer,
        uint64 startedAt,
        uint64 nowTs,
        uint32 grace
    ) external {
        (bool up, bool down, bool unknown, bool inGrace, bool ready) =
            LPPriceMath.sequencerStatus(true, readOk, answer, startedAt, nowTs, grace);
        uint256 count = (up ? 1 : 0) + (down ? 1 : 0) + (unknown ? 1 : 0);
        assert(count == 1);
        assert(up == (inGrace != ready));
        if (ready) assert(uint256(nowTs) >= uint256(startedAt) + grace);
        (up, down, unknown, inGrace, ready) =
            LPPriceMath.sequencerStatus(false, readOk, answer, startedAt, nowTs, grace);
        assert(ready && !up && !down && !unknown && !inGrace);
        ++checks;
    }

    /// @notice `SPEC-ORC-022`, `SPEC-ORC-023`: the smallest buffer that spans the window and the smallest gas bound
    /// that forwards the full call gas.
    function checkBufferAndGas(
        uint64 window,
        uint16 blockTime,
        uint32 callGas
    ) external {
        uint256 bt = 1 + uint256(blockTime) % 3600;
        uint256 k = LPPriceMath.minObservations(window, bt);
        assert((k - 1) * bt >= window);
        if (k >= 2) assert((k - 2) * bt < window);
        uint256 atCall = LPPriceMath.gasForCall(callGas) - LPPriceMath.POST_CALL_GAS;
        assert(atCall - atCall / 64 >= callGas);
        ++checks;
    }

    function _pair(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (x, y);
    }

    function _decimals(
        uint8 x,
        uint8 y
    ) internal pure returns (uint8[] memory out) {
        out = new uint8[](2);
        (out[0], out[1]) = (x, y);
    }
}
