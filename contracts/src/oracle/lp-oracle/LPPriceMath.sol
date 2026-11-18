// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AmmConstants} from "../../types/AmmConstants.sol";
import {PriceState} from "../../types/OracleTypes.sol";
import {DebtPriceView} from "../debt-oracle/types/DebtPriceView.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPPriceMath
/// @notice Pure arithmetic of the LPOracle and DebtOracle price path.
/// @dev Fails closed (0 or `valid = false`) instead of reverting; collateral prices round down, debt stress up.
library LPPriceMath {
    /// @notice `timestamp − updatedAt`, 0 for a timestamp in the future.
    function age(
        uint256 updatedAt
    ) internal view returns (uint256) {
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    /// @notice Borrow-side age rule: not in the future and `age ≤ maxAge`.
    function borrowFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge;
    }

    /// @notice Liquidation-side age rule: `age ≤ maxAge`, with a future timestamp counted as age 0.
    function liquidationFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return age(updatedAt) <= maxAge;
    }

    /// @notice The RiskModule's debt-price rule: Live, `borrowAllowed`, and the served timestamp within `maxAge`.
    function debtBorrowable(
        DebtPriceView memory v,
        uint256 maxAge
    ) internal view returns (bool) {
        return v.state == PriceState.Live && v.borrowAllowed && borrowFresh(v.servedUpdatedAt, maxAge);
    }

    uint8 internal constant DECIMALS = 8;
    uint256 internal constant PRICE_UNIT = 1e8;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant STABLE_CEILING_USD = 1e8;
    /// @notice Largest route value the listing admits; small enough that no price-path product overflows.
    uint256 internal constant MAX_ROUTE_ANSWER = 1e18;
    /// @notice Exclusive upper bound of a raw answer and of a composition amount.
    uint256 internal constant ANSWER_BOUND = 2 ** 128;
    uint8 internal constant MIN_VAULT_DECIMALS = 6;
    uint8 internal constant MAX_VAULT_DECIMALS = 18;
    /// @notice Largest token decimals `lpPrice` accepts: `10^77 < 2^256 < 10^78`.
    uint8 internal constant MAX_TOKEN_DECIMALS = 77;
    /// @notice Smallest `debtStressRiseBps`; a smaller input is read as this value.
    uint256 internal constant MIN_DEBT_STRESS_RISE_BPS = 100;
    /// @notice Gas spent around an external read beyond the gas forwarded to it.
    uint256 internal constant POST_CALL_GAS = 5000;
    /// @notice Value of a bound or product that would need more than 256 bits.
    uint256 internal constant SATURATED = type(uint256).max;

    struct LegAge {
        uint64 updatedAt;
        uint32 borrowPriceMaxAge;
        uint32 liquidationPriceMaxAge;
        // On the alternate route: liquidation holds it to its borrow age.
        bool onAlternate;
    }

    /// @notice 8-decimal value of a signed Chainlink answer with `decimals` decimals, rounded down.
    /// @dev 0 (a failure, never a price) for `answer <= 0` or `answer >= 2^128`.
    function normalizeAnswer(
        int256 answer,
        uint8 decimals
    ) internal pure returns (uint256 normalized) {
        (bool ok, uint256 a) = _answer(answer);
        if (!ok) return 0;
        if (decimals <= DECIMALS) return a * 10 ** (DECIMALS - decimals);
        return _divPow10(a, uint256(decimals) - DECIMALS);
    }

    function routeValue(
        int256 answer,
        uint8 decimals
    ) internal pure returns (uint256 value) {
        return normalizeAnswer(answer, decimals);
    }

    /// @notice Value of a two-leg route `TOKEN/X × X/USD`, 8-decimal USD per whole token; 0 is an invalid route.
    /// @dev 0 unless both answers are in `(0, 2^128)` and `fA + fB >= 8`, so `aA * aB` never overflows.
    function routeValue(
        int256 answerA,
        uint8 decimalsA,
        int256 answerB,
        uint8 decimalsB
    ) internal pure returns (uint256 value) {
        (bool okA, uint256 a) = _answer(answerA);
        (bool okB, uint256 b) = _answer(answerB);
        uint256 sum = uint256(decimalsA) + decimalsB;
        if (!okA || !okB || sum < DECIMALS) return 0;
        uint256 k = sum - DECIMALS;
        if (k <= MAX_TOKEN_DECIMALS) return Math.mulDiv(a, b, 10 ** k);
        return _divPow10(Math.mulDiv(a, b, 10 ** MAX_TOKEN_DECIMALS), k - MAX_TOKEN_DECIMALS);
    }

    function routeTimestamp(
        uint64 updatedAtA,
        uint64 updatedAtB
    ) internal pure returns (uint64 updatedAt) {
        return updatedAtA < updatedAtB ? updatedAtA : updatedAtB;
    }

    function feedMaxAge(
        uint32 heartbeat,
        uint32 heartbeatMargin
    ) internal pure returns (uint64 maxAge) {
        return uint64(heartbeat) + heartbeatMargin;
    }

    /// @notice Primary-versus-alternate agreement: `|p - b| * 10^4 <= T * min(p, b)`.
    /// @dev False when either value is outside `[1, MAX_ROUTE_ANSWER]`.
    function routesAgree(
        uint256 primary,
        uint256 alternate,
        uint16 toleranceBps
    ) internal pure returns (bool agree) {
        return _withinTolerance(primary, alternate, toleranceBps);
    }

    function secondSourceAgrees(
        bool sourceValid,
        uint256 quote,
        uint256 secondSource,
        uint16 toleranceBps
    ) internal pure returns (bool confirmed) {
        return sourceValid && _withinTolerance(quote, secondSource, toleranceBps);
    }

    /// @notice Informational deviation `floor(|x - y| * 10^4 / min(x, y))` in bps; never used for a decision.
    /// @dev Saturates when either value is 0 or the product overflows, so a view never reverts.
    function deviationBps(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256 bps) {
        (uint256 lo, uint256 hi) = x < y ? (x, y) : (y, x);
        if (lo == 0 || hi - lo > SATURATED / BPS) return SATURATED;
        return ((hi - lo) * BPS) / lo;
    }

    function valuationPrice(
        uint256 quote,
        bool isUsdStable
    ) internal pure returns (uint256 price) {
        return isUsdStable && quote > STABLE_CEILING_USD ? STABLE_CEILING_USD : quote;
    }

    /// @notice Price of one whole vault token from its composition: `max(1, sum_i floor((a_i - 1) * v_i / 10^d_i))`.
    /// @dev Rounds down, so the price never exceeds the holdings' value. `valid = false` for malformed inputs.
    function lpPrice(
        uint256[] memory amounts,
        uint256[] memory prices,
        uint8[] memory tokenDecimals
    ) internal pure returns (bool valid, uint256 price8) {
        uint256 n = amounts.length;
        if (!_tokenCountOk(n) || prices.length != n || tokenDecimals.length != n) return (false, 0);
        for (uint256 i = 0; i < n; ++i) {
            uint256 a = amounts[i];
            uint8 d = tokenDecimals[i];
            if (a >= ANSWER_BOUND || !_isRouteValue(prices[i]) || d > MAX_TOKEN_DECIMALS) return (false, 0);
            if (a > 1) price8 += Math.mulDiv(a - 1, prices[i], 10 ** d);
        }
        return (true, price8 == 0 ? 1 : price8);
    }

    /// @notice Vault-token decimals: the smallest `d` in `[6, 18]` whose whole token is worth at least $1.
    function vaultDecimals(
        function(uint256, uint256[] memory) internal view returns (uint256[] memory) composition,
        uint256[] memory prices,
        uint8[] memory tokenDecimals
    ) internal view returns (bool found, uint8 d) {
        for (d = MIN_VAULT_DECIMALS; d <= MAX_VAULT_DECIMALS; ++d) {
            (bool valid, uint256 price8) = lpPrice(composition(10 ** d, prices), prices, tokenDecimals);
            if (!valid) return (false, 0);
            if (price8 >= PRICE_UNIT) return (true, d);
        }
        return (false, 0);
    }

    /// @notice USD band: `bandLow^⊗n <= ⊗ quotes` and `⊗ valuationPrices <= bandHigh^⊗n`.
    /// @dev `x ⊗ y = floor(x * y / 10^8)`, left to right in pool order.
    function inUsdBand(
        uint256[] memory quotes,
        uint256[] memory valuationPrices,
        uint256 bandLow,
        uint256 bandHigh
    ) internal pure returns (bool valid, bool inBand) {
        uint256 n = quotes.length;
        if (!_tokenCountOk(n) || valuationPrices.length != n) return (false, false);
        for (uint256 i = 0; i < n; ++i) {
            if (!_isRouteValue(quotes[i]) || !_isRouteValue(valuationPrices[i])) return (false, false);
        }
        inBand = fixedPointPower(bandLow, n) <= fixedPointProduct(quotes)
            && fixedPointProduct(valuationPrices) <= fixedPointPower(bandHigh, n);
        return (true, inBand);
    }

    /// @notice USD level `max{L : L^⊗n <= ⊗ quotes}`, found by binary search; 0 for malformed quotes.
    function usdLevel(
        uint256[] memory quotes
    ) internal pure returns (uint256 level) {
        uint256 n = quotes.length;
        if (!_tokenCountOk(n)) return 0;
        uint256 lo = SATURATED;
        uint256 hi = 0;
        for (uint256 i = 0; i < n; ++i) {
            uint256 q = quotes[i];
            if (!_isRouteValue(q)) return 0;
            lo = Math.min(lo, q);
            hi = Math.max(hi, q);
        }
        uint256 product = fixedPointProduct(quotes);
        // A saturated product passes every band level; return early so the doubling below cannot overflow.
        if (product == SATURATED) return SATURATED;
        // Invariant: lo^⊗n <= product < hi^⊗n; the doubling stops before hi reaches 2^256.
        ++hi;
        while (fixedPointPower(hi, n) <= product) {
            hi *= 2;
        }
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (fixedPointPower(mid, n) <= product) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    /// @notice `x_0 ⊗ x_1 ⊗ … ⊗ x_(n-1)`, left to right, saturating; `10^8` for an empty vector.
    function fixedPointProduct(
        uint256[] memory xs
    ) internal pure returns (uint256 product) {
        uint256 n = xs.length;
        if (n == 0) return PRICE_UNIT;
        product = xs[0];
        for (uint256 i = 1; i < n; ++i) {
            product = _fixedMul(product, xs[i]);
        }
    }

    /// @notice `b^⊗n`, saturating as `fixedPointProduct`.
    /// @dev Callers pass `n <= MAX_POOL_TOKENS`.
    function fixedPointPower(
        uint256 b,
        uint256 n
    ) internal pure returns (uint256 power) {
        if (n == 0) return PRICE_UNIT;
        power = b;
        for (uint256 i = 1; i < n; ++i) {
            power = _fixedMul(power, b);
        }
    }

    function servedTimestamp(
        uint64[] memory tokenTimestamps,
        bool failed,
        uint64 acceptedUpdatedAt
    ) internal pure returns (uint64 servedUpdatedAt) {
        if (failed) return acceptedUpdatedAt;
        uint256 n = tokenTimestamps.length;
        if (n == 0) return 0;
        servedUpdatedAt = type(uint64).max;
        for (uint256 i = 0; i < n; ++i) {
            if (tokenTimestamps[i] < servedUpdatedAt) servedUpdatedAt = tokenTimestamps[i];
        }
    }

    /// @notice Borrow and liquidation age limits of the served price; both 0 when failed.
    function ageLimits(
        LegAge[] memory legs,
        bool failed
    ) internal pure returns (uint32 borrowMaxAge, uint32 liquidationMaxAge) {
        uint256 n = legs.length;
        if (failed || n == 0) return (0, 0);
        uint256 served = type(uint256).max;
        uint256 borrowDeadline = type(uint256).max;
        uint256 liquidationDeadline = type(uint256).max;
        for (uint256 i = 0; i < n; ++i) {
            LegAge memory leg = legs[i];
            uint256 liquidationAge = leg.liquidationPriceMaxAge;
            if (leg.onAlternate && leg.borrowPriceMaxAge < liquidationAge) liquidationAge = leg.borrowPriceMaxAge;
            served = Math.min(served, leg.updatedAt);
            borrowDeadline = Math.min(borrowDeadline, uint256(leg.updatedAt) + leg.borrowPriceMaxAge);
            liquidationDeadline = Math.min(liquidationDeadline, uint256(leg.updatedAt) + liquidationAge);
        }
        // Both deadlines are at most the oldest leg's updatedAt plus a uint32 limit, so each difference fits 32 bits.
        borrowMaxAge = SafeCast.toUint32(borrowDeadline - served);
        liquidationMaxAge = SafeCast.toUint32(liquidationDeadline - served);
    }

    /// @notice Served collateral price: 1 when Expired, accepted when Cached, else fresh (lower if disagreeing).
    /// @param lower `price8(w)` at each token's lower route, capped.
    function servedPrice(
        PriceState state,
        bool disagreeing,
        uint256 fresh,
        uint256 lower,
        uint256 accepted
    ) internal pure returns (uint256 served) {
        if (state == PriceState.Expired) return 1;
        if (state == PriceState.Cached) served = accepted;
        else if (disagreeing) served = Math.min(lower, fresh);
        else served = fresh;
        if (served == 0) served = 1;
    }

    /// @notice Served debt price by state; at least the accepted price unless Live.
    /// @dev The Expired stress price rounds up, against the borrower.
    function debtServedPrice(
        PriceState state,
        uint256 quote,
        uint256 primary,
        uint256 alternate,
        uint256 accepted,
        uint256 stressRiseBps
    ) internal pure returns (uint256 served) {
        if (state == PriceState.Expired) served = _stressPrice(accepted, stressRiseBps);
        else if (state == PriceState.Cached) served = accepted;
        else if (state == PriceState.Drifting) served = Math.max(Math.max(primary, alternate), accepted);
        else served = quote;
        if (served == 0) served = 1;
    }

    /// @notice L2 sequencer gate; with no feed, only `ready` is true.
    function sequencerStatus(
        bool hasFeed,
        bool readOk,
        int256 answer,
        uint256 startedAt,
        uint256 nowTs,
        uint256 gracePeriod
    ) internal pure returns (bool up, bool down, bool unknown, bool inGrace, bool ready) {
        if (!hasFeed) return (false, false, false, false, true);
        up = readOk && answer == 0 && startedAt != 0 && startedAt <= nowTs;
        down = readOk && answer == 1;
        unknown = !up && !down;
        inGrace = up && nowTs - startedAt < gracePeriod;
        ready = up && !inGrace;
    }

    /// @notice Observation buffer a pool needs for a window: `ceil(window / blockTime) + 1`.
    /// @dev A block time of 0 saturates, so the listing check fails closed.
    function minObservations(
        uint256 window,
        uint256 blockTime
    ) internal pure returns (uint256 observations) {
        if (blockTime == 0) return SATURATED;
        uint256 k = Math.ceilDiv(window, blockTime);
        return k == SATURATED ? SATURATED : k + 1;
    }

    /// @notice Gas required before an external read so the EVM forwards all of `callGas`.
    function gasForCall(
        uint256 callGas
    ) internal pure returns (uint256 required) {
        if (callGas > SATURATED / 64) return SATURATED;
        return Math.ceilDiv(64 * callGas, 63) + POST_CALL_GAS;
    }

    /// @notice One read's term of the `POKE_MIN_GAS_FLOOR` bound: `usedBefore + gasForCall(callGas)`, saturating.
    function pokeMinGasFloor(
        uint256 usedBefore,
        uint256 callGas
    ) internal pure returns (uint256 floor) {
        uint256 callBound = gasForCall(callGas);
        if (usedBefore > SATURATED - callBound) return SATURATED;
        return usedBefore + callBound;
    }

    function _answer(
        int256 answer
    ) private pure returns (bool ok, uint256 value) {
        if (answer <= 0) return (false, 0);
        value = SafeCast.toUint256(answer);
        if (value >= ANSWER_BOUND) return (false, 0);
        return (true, value);
    }

    function _isRouteValue(
        uint256 x
    ) private pure returns (bool) {
        return x != 0 && x <= MAX_ROUTE_ANSWER;
    }

    function _tokenCountOk(
        uint256 n
    ) private pure returns (bool) {
        return n >= AmmConstants.MIN_POOL_TOKENS && n <= AmmConstants.MAX_POOL_TOKENS;
    }

    function _withinTolerance(
        uint256 x,
        uint256 y,
        uint16 toleranceBps
    ) private pure returns (bool) {
        if (!_isRouteValue(x) || !_isRouteValue(y)) return false;
        (uint256 lo, uint256 hi) = x < y ? (x, y) : (y, x);
        return (hi - lo) * BPS <= uint256(toleranceBps) * lo;
    }

    /// @dev `floor(x / 10^e)`; 0 for `e > 77`, where `10^e > x` for every `x < 2^256`.
    function _divPow10(
        uint256 x,
        uint256 e
    ) private pure returns (uint256) {
        return e > MAX_TOKEN_DECIMALS ? 0 : x / 10 ** e;
    }

    function _fixedMul(
        uint256 x,
        uint256 y
    ) private pure returns (uint256) {
        if (x == SATURATED || y == SATURATED) return SATURATED;
        (bool ok, uint256 p) = Math.tryMul(x, y);
        return ok ? p / PRICE_UNIT : SATURATED;
    }

    /// @dev `ceil(A * (10^4 + max(δ, 100)) / 10^4)`, saturating at `type(uint256).max`.
    function _stressPrice(
        uint256 accepted,
        uint256 stressRiseBps
    ) private pure returns (uint256) {
        uint256 rise = Math.max(stressRiseBps, MIN_DEBT_STRESS_RISE_BPS);
        (bool okAdd, uint256 factor) = Math.tryAdd(BPS, rise);
        if (!okAdd) return SATURATED;
        (bool okMul, uint256 product) = Math.tryMul(accepted, factor);
        return okMul ? Math.ceilDiv(product, BPS) : SATURATED;
    }
}
