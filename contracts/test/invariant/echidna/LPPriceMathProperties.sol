// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../../src/oracle/lp-oracle/LPPriceMath.sol";
import {PriceState} from "../../../src/types/PriceState.sol";

/// @title LPPriceMathProperties
/// @notice Echidna and Medusa properties of the internal library LPPriceMath (2.10). Assertion entry points check each
/// formula at concrete decimals, tolerances, block times and stress rises with the amounts and prices symbolic
/// (answers below `2^128`, prices up to `2^60`, just above `MAX_ROUTE_ANSWER`): normalisation and route values are the
/// exact floors of the spec, the agreement and second-source tests are the exact spec inequality in either argument
/// order, the stable ceiling never raises a price and is monotone, the vault-token price is at least 1, never above the
/// holdings and independent of token order, the served collateral price is at least 1, the accepted price exactly
/// when Cached and otherwise independent of it and at most the fresh price, the served debt price at least the
/// accepted price unless Live and the exact stress price when Expired, the sequencer states partition, and the
/// observation buffer and gas guard are the exact smallest values.
/// Each entry point records its last served prices, which the `property_` functions check after every transaction.
/// @dev hevm proves each assertion entry point: no symbolic exponent, no product of two symbolic values, every case
/// parameter a literal. The `fuzz` entry points only record their inputs over the whole range of the earlier single
/// entry points (decimals 0–36, every `uint16` tolerance, block times 1–3,600 s, rises 100–5,000 bps, any quotes);
/// the matching `property_` functions check the rounding bounds, symmetry and minimality on them after every
/// transaction, in Echidna's property mode and in Medusa.
contract LPPriceMathProperties {
    uint256 internal constant MAX_ROUTE = 1e18;
    uint256 internal constant AMOUNT_BOUND = 2 ** 128;
    /// @dev Price inputs are masked to 60 bits: `[0, 2^60)` holds every listed price (`MAX_ROUTE_ANSWER = 10^18`),
    /// and a mask, unlike `%` by a non-power of two, adds no division for the solver.
    uint256 internal constant PRICE_MASK = 2 ** 60 - 1;

    /// @notice Number of assertion calls; written so each call is a transaction.
    uint256 public checks;
    /// @notice Last served collateral price, its accepted price and state.
    uint256 public lastServed = 1;
    uint256 public lastAccepted = 1;
    PriceState public lastState;
    /// @notice Fresh and lower prices and the disagreement flag of the last served collateral price.
    uint256 public lastFresh = 1;
    uint256 public lastLower = 1;
    bool public lastDisagreeing;
    /// @notice Last served debt price, its accepted price and state.
    uint256 public lastDebtServed = 1;
    uint256 public lastDebtAccepted = 1;
    PriceState public lastDebtState;

    /// @notice Inputs of the last `fuzz` call of each formula, as the fuzzer gave them.
    uint256[2] internal _normalizeIn;
    int256 internal _signedIn;
    uint256[5] internal _lpIn;
    uint8 internal _signedDecimals;
    uint256[4] internal _routeIn;
    uint256[4] internal _agreementIn;
    uint256[5] internal _levelIn;
    uint256[3] internal _bufferIn;
    uint256[6] internal _debtIn;

    // ─── Properties ───

    function property_constantsMatchTheSpec() external pure returns (bool) {
        return LPPriceMath.DECIMALS == 8 && LPPriceMath.STABLE_CEILING_USD == 1e8
            && LPPriceMath.MAX_ROUTE_ANSWER == 1e18 && LPPriceMath.POST_CALL_GAS == 5000
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

    /// @notice `SPEC-ORC-017`: the accepted price is served exactly when Cached and enters no other state; Live and
    /// Drifting serve the fresh price, or `min(lower, fresh)` (at least 1) while some token disagrees.
    function property_servedCollateralByState() external view returns (bool) {
        if (lastState == PriceState.Expired) return lastServed == 1;
        if (lastState == PriceState.Cached) return lastServed == lastAccepted;
        uint256 expected = lastDisagreeing ? (lastLower < lastFresh ? lastLower : lastFresh) : lastFresh;
        return lastServed == (expected == 0 ? 1 : expected) && lastServed <= lastFresh;
    }

    function property_servedDebtAtLeastAcceptedUnlessLive() external view returns (bool) {
        return lastDebtServed >= 1 && (lastDebtState == PriceState.Live || lastDebtServed >= lastDebtAccepted);
    }

    /// @notice `SPEC-ORC-001` over 0–36 decimals: exact at 8 or fewer, otherwise rounded down by less than one unit.
    function property_normalizeRoundsDown() external view returns (bool) {
        uint256 answer = _normalizeIn[0] % AMOUNT_BOUND;
        uint8 decimals = uint8(_normalizeIn[1] % 37);
        uint256 n = LPPriceMath.normalizeAnswer(int256(answer), decimals);
        if (decimals <= 8) return n == answer * 10 ** (8 - decimals);
        uint256 unit = 10 ** (decimals - 8);
        return n * unit <= answer && answer < (n + 1) * unit;
    }

    /// @notice `SPEC-ORC-001` at every `uint8` decimals: a signed answer outside `(0, 2^128)` normalises to 0.
    function property_normalizeOutOfRangeIsZero() external view returns (bool) {
        int256 answer = _signedIn;
        if (answer > 0 && answer < int256(AMOUNT_BOUND)) answer = -answer;
        return LPPriceMath.normalizeAnswer(answer, _signedDecimals) == 0;
    }

    /// @notice `SPEC-ORC-002` over 0–36 decimals per leg: rounds down; invalid below 8 decimals in total.
    function property_routeRoundsDown() external view returns (bool) {
        uint256 answerA = _routeIn[0] % AMOUNT_BOUND;
        uint256 answerB = _routeIn[2] % AMOUNT_BOUND;
        uint8 decimalsA = uint8(_routeIn[1] % 37);
        uint8 decimalsB = uint8(_routeIn[3] % 37);
        uint256 r = LPPriceMath.routeValue(int256(answerA), decimalsA, int256(answerB), decimalsB);
        uint256 sum = uint256(decimalsA) + decimalsB;
        return sum < 8 ? r == 0 : r == answerA * answerB / 10 ** (sum - 8);
    }

    /// @notice `SPEC-ORC-008` at token decimals (6, 6), (18, 6) or (18, 18) with any amounts below `2^128` and prices in
    /// `[1, MAX_ROUTE_ANSWER]`: at least 1, never above the holdings, independent of token order.
    function property_lpPriceBounded() external view returns (bool) {
        uint256 a0 = _lpIn[0] % AMOUNT_BOUND;
        uint256 a1 = _lpIn[1] % AMOUNT_BOUND;
        uint256 v0 = 1 + _lpIn[2] % MAX_ROUTE;
        uint256 v1 = 1 + _lpIn[3] % MAX_ROUTE;
        uint256 pair = _lpIn[4] % 3;
        uint8 d0 = pair == 0 ? 6 : 18;
        uint8 d1 = pair == 2 ? 18 : 6;
        (bool valid, uint256 price8) = LPPriceMath.lpPrice(_pair(a0, a1), _pair(v0, v1), _decimals(d0, d1));
        uint256 exactScaled = a0 * v0 * 10 ** d1 + a1 * v1 * 10 ** d0;
        uint256 one = 10 ** (uint256(d0) + d1);
        (, uint256 reverse) = LPPriceMath.lpPrice(_pair(a1, a0), _pair(v1, v0), _decimals(d1, d0));
        return valid && price8 >= 1 && (exactScaled < one || price8 * one <= exactScaled) && price8 == reverse;
    }

    /// @notice `SPEC-ORC-003`, `SPEC-ORC-020` at every `uint16` tolerance: exact, symmetric, and the second source
    /// needs validity.
    function property_agreementExact() external view returns (bool) {
        uint256 p = _agreementIn[0] % AMOUNT_BOUND;
        uint256 b = _agreementIn[1] % AMOUNT_BOUND;
        uint16 t = uint16(_agreementIn[2]);
        bool valid = _agreementIn[3] % 2 == 1;
        bool agree = LPPriceMath.routesAgree(p, b, t);
        uint256 diff = p > b ? p - b : b - p;
        uint256 lo = p < b ? p : b;
        bool inBounds = p != 0 && p <= MAX_ROUTE && b != 0 && b <= MAX_ROUTE;
        return agree == LPPriceMath.routesAgree(b, p, t) && agree == (inBounds && diff * 10_000 <= uint256(t) * lo)
            && LPPriceMath.secondSourceAgrees(valid, p, b, t) == (valid && agree);
    }

    /// @notice `SPEC-ORC-011` on any two or three quotes in `[1, MAX_ROUTE_ANSWER]`: the level is the largest whose
    /// fixed-point power is at most the product, and a band low passes exactly when it is at most the level.
    function property_usdLevelExact() external view returns (bool) {
        bool three = _levelIn[3] % 2 == 1;
        uint256 n = three ? 3 : 2;
        uint256[] memory q = new uint256[](n);
        q[0] = 1 + _levelIn[0] % MAX_ROUTE;
        q[1] = 1 + _levelIn[1] % MAX_ROUTE;
        if (three) q[2] = 1 + _levelIn[2] % MAX_ROUTE;
        uint256 product = LPPriceMath.fixedPointProduct(q);
        uint256 level = LPPriceMath.usdLevel(q);
        uint256 low = _levelIn[4] % (2 * MAX_ROUTE);
        (bool valid, bool inBand) = LPPriceMath.inUsdBand(q, q, low, type(uint256).max);
        return LPPriceMath.fixedPointPower(level, n) <= product && LPPriceMath.fixedPointPower(level + 1, n) > product
            && valid && inBand == (low <= level);
    }

    /// @notice `SPEC-ORC-022`, `SPEC-ORC-023` at block times 1–3,600 s: the smallest buffer that spans the window and
    /// the smallest gas bound that forwards the full call gas.
    function property_bufferAndGasSmallest() external view returns (bool) {
        uint64 window = uint64(_bufferIn[0]);
        uint256 bt = 1 + _bufferIn[1] % 3600;
        uint32 callGas = uint32(_bufferIn[2]);
        uint256 k = LPPriceMath.minObservations(window, bt);
        uint256 atCall = LPPriceMath.gasForCall(callGas) - LPPriceMath.POST_CALL_GAS;
        return (k - 1) * bt >= window && (k < 2 || (k - 2) * bt < window) && atCall - atCall / 64 >= callGas;
    }

    /// @notice `SPEC-ORC-018` at every stress rise in `[100, 5000]` bps: at least 1, at least the accepted price unless
    /// Live, and when Expired above the accepted price and at most 1.5 times it plus one unit.
    function property_debtServedBounded() external view returns (bool) {
        PriceState state = PriceState(_debtIn[0] % 4);
        uint256 accepted = 1 + _debtIn[4] % MAX_ROUTE;
        uint256 served = LPPriceMath.debtServedPrice(
            state,
            1 + _debtIn[1] % MAX_ROUTE,
            1 + _debtIn[2] % MAX_ROUTE,
            1 + _debtIn[3] % MAX_ROUTE,
            accepted,
            100 + _debtIn[5] % 4901
        );
        return served >= 1 && (state == PriceState.Live || served >= accepted)
            && (state != PriceState.Expired || (served > accepted && served * 2 <= accepted * 3 + 2));
    }

    // ─── Full-range inputs for the properties ───

    function fuzzNormalize(
        uint256 answer,
        uint8 decimals
    ) external {
        _normalizeIn = [answer, uint256(decimals)];
    }

    function fuzzNormalizeSigned(
        int256 answer,
        uint8 decimals
    ) external {
        (_signedIn, _signedDecimals) = (answer, decimals);
    }

    function fuzzRoute(
        uint256 answerA,
        uint8 decimalsA,
        uint256 answerB,
        uint8 decimalsB
    ) external {
        _routeIn = [answerA, uint256(decimalsA), answerB, uint256(decimalsB)];
    }

    function fuzzLpPrice(
        uint256 a0,
        uint256 a1,
        uint256 v0,
        uint256 v1,
        uint8 pair
    ) external {
        _lpIn = [a0, a1, v0, v1, uint256(pair)];
    }

    function fuzzAgreement(
        uint256 p,
        uint256 b,
        uint16 t,
        bool valid
    ) external {
        _agreementIn = [p, b, uint256(t), valid ? 1 : 0];
    }

    function fuzzUsdLevel(
        uint256 q0,
        uint256 q1,
        uint256 q2,
        bool three,
        uint256 low
    ) external {
        _levelIn = [q0, q1, q2, three ? 1 : 0, low];
    }

    function fuzzBufferAndGas(
        uint64 window,
        uint16 blockTime,
        uint32 callGas
    ) external {
        _bufferIn = [uint256(window), uint256(blockTime), uint256(callGas)];
    }

    function fuzzDebtServed(
        uint8 stateRaw,
        uint256 q,
        uint256 p,
        uint256 b,
        uint256 accepted,
        uint256 rise
    ) external {
        _debtIn = [uint256(stateRaw), q, p, b, accepted, rise];
    }

    // ─── Assertion entry points ───

    /// @notice `SPEC-ORC-001` at each concrete feed decimals: `n = answer × 10^(8 − f)` at 8 or fewer,
    /// `n = ⌊answer / 10^(f − 8)⌋` above, and 0 at 47 or more. The cases: 0, the bounds of a listed feed (1 and 18),
    /// 6, the multiply-divide boundary (8 and 9), 36, and 47 and 255 for the zero bound.
    function checkNormalize0(
        uint256 answer
    ) external {
        _checkNormalize(answer, 0);
    }

    function checkNormalize1(
        uint256 answer
    ) external {
        _checkNormalize(answer, 1);
    }

    function checkNormalize6(
        uint256 answer
    ) external {
        _checkNormalize(answer, 6);
    }

    function checkNormalize8(
        uint256 answer
    ) external {
        _checkNormalize(answer, 8);
    }

    function checkNormalize9(
        uint256 answer
    ) external {
        _checkNormalize(answer, 9);
    }

    function checkNormalize18(
        uint256 answer
    ) external {
        _checkNormalize(answer, 18);
    }

    function checkNormalize36(
        uint256 answer
    ) external {
        _checkNormalize(answer, 36);
    }

    function checkNormalize47(
        uint256 answer
    ) external {
        _checkNormalize(answer, 47);
    }

    function checkNormalize255(
        uint256 answer
    ) external {
        _checkNormalize(answer, 255);
    }

    /// @notice `SPEC-ORC-001`: a signed answer outside `(0, 2^128)` normalises to 0. `which` picks the decimals among
    /// the cases of `checkNormalize`; an answer inside the range returns at once (the per-decimals entry points cover
    /// it), and `property_normalizeOutOfRangeIsZero` checks every `uint8` decimals.
    function checkNormalizeSigned(
        int256 answer,
        uint8 which
    ) external {
        if (answer > 0 && answer < int256(AMOUNT_BOUND)) return;
        which %= 9;
        uint256 n;
        if (which == 0) n = LPPriceMath.normalizeAnswer(answer, 0);
        else if (which == 1) n = LPPriceMath.normalizeAnswer(answer, 1);
        else if (which == 2) n = LPPriceMath.normalizeAnswer(answer, 6);
        else if (which == 3) n = LPPriceMath.normalizeAnswer(answer, 8);
        else if (which == 4) n = LPPriceMath.normalizeAnswer(answer, 9);
        else if (which == 5) n = LPPriceMath.normalizeAnswer(answer, 18);
        else if (which == 6) n = LPPriceMath.normalizeAnswer(answer, 36);
        else if (which == 7) n = LPPriceMath.normalizeAnswer(answer, 47);
        else n = LPPriceMath.normalizeAnswer(answer, 255);
        assert(n == 0);
        ++checks;
    }

    /// @notice `SPEC-ORC-002` at concrete leg decimals: `r = ⌊aA × aB / 10^(fA + fB − 8)⌋`, and 0 below 8 decimals in
    /// total. The cases: 0 + 7 (below the listing bound), 0 + 8, 8 + 8, the spec example 18 + 8, 6 + 18, the largest
    /// listed pair 18 + 18, and 36 + 36; `which` picks leg B's answer among 1, the spec example 3 × 10^11 and
    /// `2^128 − 1`.
    function checkRoute0And7(
        uint256 answerA,
        uint8 which
    ) external {
        _checkRoutes(answerA, 0, 7, which);
    }

    function checkRoute0And8(
        uint256 answerA,
        uint8 which
    ) external {
        _checkRoutes(answerA, 0, 8, which);
    }

    function checkRoute8And8(
        uint256 answerA,
        uint8 which
    ) external {
        _checkRoutes(answerA, 8, 8, which);
    }

    function checkRoute18And8(
        uint256 answerA,
        uint8 which
    ) external {
        _checkRoutes(answerA, 18, 8, which);
    }

    function checkRoute6And18(
        uint256 answerA,
        uint8 which
    ) external {
        _checkRoutes(answerA, 6, 18, which);
    }

    function checkRoute18And18(
        uint256 answerA,
        uint8 which
    ) external {
        _checkRoutes(answerA, 18, 18, which);
    }

    function checkRoute36And36(
        uint256 answerA,
        uint8 which
    ) external {
        _checkRoutes(answerA, 36, 36, which);
    }

    /// @notice `SPEC-ORC-003`, `SPEC-ORC-020` at concrete tolerances 0, 1, 120, the largest listed 500, and 65,535: in
    /// either argument order the result is `p, b ∈ [1, MAX_ROUTE_ANSWER]` and `(max − min) × 10⁴ ≤ t × min`, which
    /// is symmetric in `p` and `b`; the second source needs validity.
    function checkAgreement0(
        uint256 p,
        uint256 b,
        bool valid
    ) external {
        _checkAgreement(p, b, 0, valid);
    }

    function checkAgreement1(
        uint256 p,
        uint256 b,
        bool valid
    ) external {
        _checkAgreement(p, b, 1, valid);
    }

    function checkAgreement120(
        uint256 p,
        uint256 b,
        bool valid
    ) external {
        _checkAgreement(p, b, 120, valid);
    }

    function checkAgreement500(
        uint256 p,
        uint256 b,
        bool valid
    ) external {
        _checkAgreement(p, b, 500, valid);
    }

    function checkAgreement65535(
        uint256 p,
        uint256 b,
        bool valid
    ) external {
        _checkAgreement(p, b, 65_535, valid);
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

    /// @notice `SPEC-ORC-011` on concrete quotes with a symbolic band low: the USD level is the largest level whose
    /// fixed-point power is at most the product, and the low passes exactly when it is at most the level. `which`
    /// picks the quotes: two tokens `(0.99987, 1.0002)` or `(10^-8, 10^4)`, three tokens `(1, 0.9999, 3000)` or
    /// `(10^-8, 10^-8, 10^4)` USD.
    function checkUsdLevel(
        uint8 which,
        uint256 low
    ) external {
        low &= 2 ** 41 - 1;
        which &= 3;
        if (which == 0) _checkUsdLevel(_pair(99_987_000, 100_020_000), low);
        else if (which == 1) _checkUsdLevel(_pair(1, MAX_ROUTE), low);
        else if (which == 2) _checkUsdLevel(_triple(1e8, 99_990_000, 300_000_000_000), low);
        else _checkUsdLevel(_triple(1, 1, MAX_ROUTE), low);
    }

    /// @notice `SPEC-ORC-008` at token decimals (6, 6), (18, 6) and (18, 18): `price8 = max(1, Σ ⌊(a_i − 1) × v_i /
    /// 10^(d_i)⌋)` over the amounts above 1, the same in either token order, and invalid for an amount of `2^128`.
    /// Each amount is `1 + x` with `x < 2^128`, so `a − 1` keeps the solver's bound (an amount of 0 prices as 1 does);
    /// `which` picks the prices among (0.99987, 1), (10^-8, 10^4) and (3000, 1) USD. `property_lpPriceBounded`
    /// checks the bound form (at least 1, never above the holdings) at any prices and amounts.
    function checkLpPrice6And6(
        uint256 x0,
        uint256 x1,
        uint8 which
    ) external {
        _checkLpPrices(x0, x1, which, 6, 6);
    }

    function checkLpPrice18And6(
        uint256 x0,
        uint256 x1,
        uint8 which
    ) external {
        _checkLpPrices(x0, x1, which, 18, 6);
    }

    function checkLpPrice18And18(
        uint256 x0,
        uint256 x1,
        uint8 which
    ) external {
        _checkLpPrices(x0, x1, which, 18, 18);
    }

    /// @notice `SPEC-ORC-017`: served collateral price by state; recorded for the properties.
    function checkServed(
        uint8 stateRaw,
        bool disagreeing,
        uint256 fresh,
        uint256 lower,
        uint256 accepted
    ) external {
        PriceState state = PriceState(stateRaw & 3);
        fresh = 1 + (fresh & PRICE_MASK);
        // Unconstrained against fresh: the floored lower-route price can exceed the floored fresh price.
        lower &= 2 * PRICE_MASK + 1;
        accepted = 1 + (accepted & PRICE_MASK);
        uint256 served = LPPriceMath.servedPrice(state, disagreeing, fresh, lower, accepted);
        assert(served >= 1);
        if (state == PriceState.Cached) assert(served == accepted);
        if (state == PriceState.Expired) assert(served == 1);
        if (state != PriceState.Cached && state != PriceState.Expired) {
            assert(served <= fresh);
            // The accepted price bounds borrowing only: no state but Cached serves it.
            assert(served == LPPriceMath.servedPrice(state, disagreeing, fresh, lower, 1));
            if (!disagreeing) assert(served == fresh);
            else assert(served == (lower == 0 ? 1 : (lower < fresh ? lower : fresh)));
        }
        (lastServed, lastAccepted, lastState) = (served, accepted, state);
        (lastFresh, lastLower, lastDisagreeing) = (fresh, lower, disagreeing);
        ++checks;
    }

    /// @notice `SPEC-ORC-018` when Live, Drifting or Cached: served debt price at least 1, and at least the accepted
    /// price unless Live; recorded for the properties. The Expired state is `checkStressPrice`.
    function checkDebtServed(
        uint8 stateRaw,
        uint256 q,
        uint256 p,
        uint256 b,
        uint256 accepted
    ) external {
        PriceState state = PriceState(stateRaw % 3);
        q = 1 + (q & PRICE_MASK);
        p = 1 + (p & PRICE_MASK);
        b = 1 + (b & PRICE_MASK);
        accepted = 1 + (accepted & PRICE_MASK);
        uint256 served = LPPriceMath.debtServedPrice(state, q, p, b, accepted, 100);
        assert(served >= 1);
        if (state != PriceState.Live) assert(served >= accepted);
        (lastDebtServed, lastDebtAccepted, lastDebtState) = (served, accepted, state);
        ++checks;
    }

    /// @notice `SPEC-ORC-018` when Expired: the stress price `⌈accepted × (10^4 + rise) / 10^4⌉`, above the accepted
    /// price and at most 1.5 times it plus one unit; recorded for the properties. `rise` picks 100 (the minimum), 2,500
    /// or 5,000 bps and `price` the accepted price among 1, 0.99987 USD, `MAX_ROUTE_ANSWER` and `2^60 − 1`; the
    /// solver cannot bound the library's 256-bit ceiling division with the accepted price symbolic, so these are
    /// concrete cases, and `property_debtServedBounded` checks every rise and accepted price.
    function checkStressPrice(
        uint8 rise,
        uint8 price
    ) external {
        rise %= 3;
        price &= 3;
        uint256 r = rise == 0 ? 100 : rise == 1 ? 2500 : 5000;
        uint256 accepted = price == 0 ? 1 : price == 1 ? 99_987_000 : price == 2 ? MAX_ROUTE : PRICE_MASK;
        uint256 served = LPPriceMath.debtServedPrice(PriceState.Expired, 1, 1, 1, accepted, r);
        assert(served == ((10_000 + r) * accepted - 1) / 10_000 + 1);
        assert(served > accepted && served * 2 <= accepted * 3 + 2);
        (lastDebtServed, lastDebtAccepted, lastDebtState) = (served, accepted, PriceState.Expired);
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

    /// @notice `SPEC-ORC-022` at concrete block times 2 s (Base), 12 s (Ethereum), and 1 s and 3,600 s as bounds:
    /// `k = ⌈W / blockTime⌉ + 1`; `property_bufferAndGasSmallest` checks that `k` is the smallest buffer spanning
    /// the window at every block time.
    function checkBuffer1(
        uint64 window
    ) external {
        _checkBuffer(window, 1);
    }

    function checkBuffer2(
        uint64 window
    ) external {
        _checkBuffer(window, 2);
    }

    function checkBuffer12(
        uint64 window
    ) external {
        _checkBuffer(window, 12);
    }

    function checkBuffer3600(
        uint64 window
    ) external {
        _checkBuffer(window, 3600);
    }

    /// @notice `SPEC-ORC-023`: the smallest gas bound that forwards the full call gas.
    function checkGas(
        uint32 callGas
    ) external {
        uint256 atCall = LPPriceMath.gasForCall(callGas) - LPPriceMath.POST_CALL_GAS;
        assert(atCall - atCall / 64 >= callGas);
        ++checks;
    }

    // ─── Helpers ───

    function _checkNormalize(
        uint256 answer,
        uint8 decimals
    ) internal {
        answer %= AMOUNT_BOUND;
        uint256 n = LPPriceMath.normalizeAnswer(int256(answer), decimals);
        // The floor is the rounding-down bound itself; property_normalizeRoundsDown checks the bound form.
        if (decimals <= 8) assert(n == 10 ** (8 - decimals) * answer);
        else if (decimals < 47) assert(n == answer / 10 ** (decimals - 8));
        else assert(n == 0);
        ++checks;
    }

    function _checkRoutes(
        uint256 answerA,
        uint8 decimalsA,
        uint8 decimalsB,
        uint8 which
    ) internal {
        answerA %= AMOUNT_BOUND;
        if (which % 3 == 0) _checkRoute(answerA, decimalsA, 1, decimalsB);
        else if (which % 3 == 1) _checkRoute(answerA, decimalsA, 300_000_000_000, decimalsB);
        else _checkRoute(answerA, decimalsA, 1e18, decimalsB);
        ++checks;
    }

    function _checkRoute(
        uint256 answerA,
        uint8 decimalsA,
        uint256 answerB,
        uint8 decimalsB
    ) internal pure {
        uint256 r = LPPriceMath.routeValue(int256(answerA), decimalsA, int256(answerB), decimalsB);
        uint256 sum = uint256(decimalsA) + decimalsB;
        if (sum < 8) {
            assert(r == 0);
        } else {
            // Both answers are below 2^128, so the product fits 256 bits.
            unchecked {
                assert(r == answerB * answerA / 10 ** (sum - 8));
            }
        }
    }

    /// @dev `SPEC-ORC-003` for the arguments in this order: both in `[1, MAX_ROUTE_ANSWER]` and
    /// `(max − min) × 10⁴ ≤ t × min`.
    function _agreeFormula(
        uint256 x,
        uint256 y,
        uint16 t
    ) internal pure returns (bool) {
        (uint256 lo, uint256 hi) = x < y ? (x, y) : (y, x);
        return x != 0 && x <= MAX_ROUTE && y != 0 && y <= MAX_ROUTE && (hi - lo) * 10_000 <= t * lo;
    }

    function _checkAgreement(
        uint256 p,
        uint256 b,
        uint16 t,
        bool valid
    ) internal {
        // Inputs reach 2^128, past MAX_ROUTE, so both sides of the listing bound are covered: a value of 0 or above
        // MAX_ROUTE_ANSWER never agrees (SPEC-ORC-003).
        p %= AMOUNT_BOUND;
        b %= AMOUNT_BOUND;
        bool agree = LPPriceMath.routesAgree(p, b, t);
        assert(agree == _agreeFormula(p, b, t));
        assert(LPPriceMath.routesAgree(b, p, t) == _agreeFormula(b, p, t));
        assert(LPPriceMath.secondSourceAgrees(valid, p, b, t) == (valid && agree));
        ++checks;
    }

    function _checkUsdLevel(
        uint256[] memory q,
        uint256 low
    ) internal {
        uint256 n = q.length;
        uint256 product = LPPriceMath.fixedPointProduct(q);
        uint256 level = LPPriceMath.usdLevel(q);
        assert(LPPriceMath.fixedPointPower(level, n) <= product);
        assert(LPPriceMath.fixedPointPower(level + 1, n) > product);
        (bool valid, bool inBand) = LPPriceMath.inUsdBand(q, q, low, type(uint256).max);
        assert(valid && inBand == (low <= level));
        ++checks;
    }

    function _checkLpPrices(
        uint256 x0,
        uint256 x1,
        uint8 which,
        uint8 d0,
        uint8 d1
    ) internal {
        x0 &= AMOUNT_BOUND - 1;
        x1 &= AMOUNT_BOUND - 1;
        which %= 3;
        if (which == 0) _checkLpPrice(x0, x1, 99_987_000, 1e8, d0, d1);
        else if (which == 1) _checkLpPrice(x0, x1, 1, MAX_ROUTE, d0, d1);
        else _checkLpPrice(x0, x1, 300_000_000_000, 1e8, d0, d1);
        ++checks;
    }

    function _checkLpPrice(
        uint256 x0,
        uint256 x1,
        uint256 v0,
        uint256 v1,
        uint8 d0,
        uint8 d1
    ) internal pure {
        unchecked {
            (bool valid, uint256 price8) = LPPriceMath.lpPrice(_pair(x0 + 1, x1 + 1), _pair(v0, v1), _decimals(d0, d1));
            (bool validReverse, uint256 reverse) =
                LPPriceMath.lpPrice(_pair(x1 + 1, x0 + 1), _pair(v1, v0), _decimals(d1, d0));
            bool inRange = x0 < AMOUNT_BOUND - 1 && x1 < AMOUNT_BOUND - 1;
            assert(valid == inRange && validReverse == inRange);
            if (inRange) {
                // x_i × v_i < 2^168, so neither product nor the sum wraps.
                uint256 sum = v0 * x0 / 10 ** d0 + v1 * x1 / 10 ** d1;
                assert(price8 == (sum == 0 ? 1 : sum));
                assert(reverse == price8);
            }
        }
    }

    function _checkBuffer(
        uint64 window,
        uint256 bt
    ) internal {
        uint256 k = LPPriceMath.minObservations(window, bt);
        unchecked {
            assert(k == (window == 0 ? 1 : (uint256(window) - 1) / bt + 2));
        }
        ++checks;
    }

    function _pair(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (x, y);
    }

    function _triple(
        uint256 x,
        uint256 y,
        uint256 z
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](3);
        (out[0], out[1], out[2]) = (x, y, z);
    }

    function _decimals(
        uint8 x,
        uint8 y
    ) internal pure returns (uint8[] memory out) {
        out = new uint8[](2);
        (out[0], out[1]) = (x, y);
    }
}
