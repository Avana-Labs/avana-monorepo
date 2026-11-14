// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AmmConstants} from "../../types/AmmConstants.sol";
import {PriceState} from "../../types/PriceState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPPriceMath
/// @notice Pure arithmetic of the LPOracle and DebtOracle price path (2.10): leg normalisation, route values, the
/// agreement and second-source tests, the stable ceiling, the vault-token decimals, the price of one whole vault token
/// from a composition, the USD band and level, the served timestamp, the age limits, the served collateral and debt
/// prices, the feed age limit, the sequencer gate, the observation buffer and the gas guard. One function per formula.
/// @dev Internal library: no storage, no external calls, compiled into every LPOracle implementation and the DebtOracle.
/// Every function checks its own input bounds and fails closed instead of reverting, because no `try` can catch a revert
/// of code compiled into the caller: a signed answer outside `(0, 2^128)` normalises to 0 (`SPEC-ORC-001`); a malformed
/// composition or band input returns `valid = false`, which the LPOracle maps to reason bit 1 (`REQ-ORACLE-103`); a value
/// outside `[1, MAX_ROUTE_ANSWER]` never agrees (`SPEC-ORC-003`); a served price is at least 1; and a bound that would
/// overflow saturates at `type(uint256).max`. Every division of a collateral price rounds down (`REQ-ORACLE-012`); the one
/// rounding of a debt price, the stress rise, rounds up. The concentrated-liquidity composition and sqrt-price math and
/// the price-state machine are not here: the pricing module supplies the composition that `lpPrice` values, and the
/// LPOracle core decides the state that `servedPrice` serves. Example (`SPEC-ORC-008`): USDC/USDT on `[-10, 10]`,
/// `d = 10`, `v = (99,987,000, 10^8)`, the composition `a = (5,648,563, 4,348,479)` gives
/// `lpPrice = 564,782,768 + 434,847,800 = 999,630,568` ($9.99630568).
/// @custom:spec SPEC-ORC-001, SPEC-ORC-002, SPEC-ORC-003, SPEC-ORC-004, SPEC-ORC-005, SPEC-ORC-008, SPEC-ORC-011, SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-017, SPEC-ORC-018, SPEC-ORC-019, SPEC-ORC-020, SPEC-ORC-021, SPEC-ORC-022, SPEC-ORC-023, REQ-ORACLE-012, REQ-ORACLE-103, Q-191, Q-240
library LPPriceMath {
    /// @notice Decimals of every price this library takes and returns (Aave's 8-decimal USD).
    uint8 internal constant DECIMALS = 8;
    /// @notice One USD in 8 decimals; the fixed-point unit of `SPEC-ORC-011`.
    uint256 internal constant PRICE_UNIT = 1e8;
    /// @notice Basis points in one.
    uint256 internal constant BPS = 10_000;
    /// @notice `stableCeilingUsd`: valuation ceiling of a USD-pegged stable, $1.00 (1.5, `Q-177`).
    uint256 internal constant STABLE_CEILING_USD = 1e8;
    /// @notice Largest route value the listing admits, $10,000,000,000 per whole token (1.5, `Q-191`): far above any
    /// listable token (WBTC near $10^5) and small enough that no product of the price path overflows (MATH-UO-14:
    /// `lpPrice` stays below `8 * 2^128 * 10^18 < 2^192`, `SPEC-ORC-009`'s `den << 64` below `2^184`, every accepted price
    /// fits `uint128`).
    uint256 internal constant MAX_ROUTE_ANSWER = 1e18;
    /// @notice Exclusive upper bound of a raw answer and of a composition amount (`SPEC-ORC-001`, `SPEC-ORC-008`).
    uint256 internal constant ANSWER_BOUND = 2 ** 128;
    /// @notice Range of the vault-token decimals `d` (`SPEC-ORC-005`).
    uint8 internal constant MIN_VAULT_DECIMALS = 6;
    uint8 internal constant MAX_VAULT_DECIMALS = 18;
    /// @notice Largest token decimals `lpPrice` accepts: `10^77 < 2^256 < 10^78`.
    uint8 internal constant MAX_TOKEN_DECIMALS = 77;
    /// @notice Smallest `debtStressRiseBps` (1.5); a smaller input is read as this value (`SPEC-ORC-018`).
    uint256 internal constant MIN_DEBT_STRESS_RISE_BPS = 100;
    /// @notice Gas spent between the pre-call check and the call's 63/64 rule plus the gas kept when the read returns
    /// (`SPEC-ORC-023`).
    uint256 internal constant POST_CALL_GAS = 5000;
    /// @notice Value of a bound or product that would need more than 256 bits.
    uint256 internal constant SATURATED = type(uint256).max;

    /// @notice One leg of a route in use, as `ageLimits` reads it.
    /// @dev `onAlternate` is true for a leg of a token's alternate route, which liquidation holds to its borrow age
    /// (`REQ-ORACLE-090`).
    struct LegAge {
        // Chainlink `updatedAt` of the leg's round, seconds.
        uint64 updatedAt;
        // The feed's `borrowPriceMaxAge`, seconds.
        uint32 borrowPriceMaxAge;
        // The feed's `liquidationPriceMaxAge`, seconds.
        uint32 liquidationPriceMaxAge;
        // The leg belongs to the token's alternate route.
        bool onAlternate;
    }

    // ─── Legs and routes ───

    /// @notice 8-decimal value of a signed Chainlink answer `a` with `f` decimals (`SPEC-ORC-001`).
    /// @dev 0 for `a <= 0` or `a >= 2^128`; else `a * 10^(8 - f)` if `f <= 8`, else `floor(a / 10^(f - 8))`. A result of
    /// 0 is a failure, never a price (`REQ-ORACLE-002`); the function never reverts. Example: 99,987,000 at 8 decimals,
    /// 999,870,000,000,000,000 at 18 and 999,870 at 6 all give 99,987,000; -1 gives 0.
    /// @param answer Raw `int256` answer of `latestRoundData()`.
    /// @param decimals Feed decimals `f`.
    /// @return normalized The answer in 8 decimals.
    /// @custom:spec SPEC-ORC-001, REQ-ORACLE-002, REQ-ORACLE-012
    function normalizeAnswer(
        int256 answer,
        uint8 decimals
    ) internal pure returns (uint256 normalized) {
        (bool ok, uint256 a) = _answer(answer);
        if (!ok) return 0;
        if (decimals <= DECIMALS) return a * 10 ** (DECIMALS - decimals);
        return _divPow10(a, uint256(decimals) - DECIMALS);
    }

    /// @notice Value of a one-leg route: `r = n` (`SPEC-ORC-002`).
    /// @param answer Raw answer of the `TOKEN/USD` leg.
    /// @param decimals Its decimals.
    /// @return value Route value, 8-decimal USD per whole token; 0 is an invalid route.
    /// @custom:spec SPEC-ORC-002, SPEC-ORC-001
    function routeValue(
        int256 answer,
        uint8 decimals
    ) internal pure returns (uint256 value) {
        return normalizeAnswer(answer, decimals);
    }

    /// @notice Value of a two-leg route `TOKEN/X × X/USD`: `r = mulDiv(aA, aB, 10^(fA + fB - 8))` (`SPEC-ORC-002`).
    /// @dev 0 (an invalid route) unless `0 < aA, aB < 2^128` and `fA + fB >= 8`; inside those bounds `aA * aB < 2^256`,
    /// so the floor never reverts. Exponents above 77 divide in two exact steps, `floor(floor(x / 10^77) / 10^k) =
    /// floor(x / 10^(77 + k))`. Example: USDT/ETH 333,300,000,000,000 (18 decimals) × ETH/USD 300,000,000,000
    /// (8 decimals) = 99,990,000.
    /// @param answerA Raw answer of leg A (token in `X`).
    /// @param decimalsA Its decimals `fA`.
    /// @param answerB Raw answer of leg B (`X/USD`).
    /// @param decimalsB Its decimals `fB`.
    /// @return value Route value, 8-decimal USD per whole token; 0 is an invalid route.
    /// @custom:spec SPEC-ORC-002, REQ-ORACLE-012, REQ-ORACLE-049
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

    /// @notice Timestamp of a two-leg route: the older leg (`SPEC-ORC-002`).
    /// @custom:spec SPEC-ORC-002
    function routeTimestamp(
        uint64 updatedAtA,
        uint64 updatedAtB
    ) internal pure returns (uint64 updatedAt) {
        return updatedAtA < updatedAtB ? updatedAtA : updatedAtB;
    }

    /// @notice Age limit of a leg: `feedMaxAge = feedHeartbeat + heartbeatMargin` (`SPEC-ORC-019`).
    /// @dev The margin is the feed's own (`uint16` in the feed record, at most 3,600 s). Example: a USDT/USD heartbeat
    /// of 86,400 s with the 1,800 s margin gives 88,200 s.
    /// @custom:spec SPEC-ORC-019, REQ-ORACLE-054
    function feedMaxAge(
        uint32 heartbeat,
        uint32 heartbeatMargin
    ) internal pure returns (uint64 maxAge) {
        return uint64(heartbeat) + heartbeatMargin;
    }

    // ─── Agreement and the stable ceiling ───

    /// @notice Primary-versus-alternate agreement: `|p - b| * 10^4 <= T * min(p, b)` (`SPEC-ORC-003`).
    /// @dev Exact integer comparison, symmetric in `p` and `b`. False when either value is 0 or above
    /// `MAX_ROUTE_ANSWER`, so an input outside the listing bounds disagrees instead of overflowing. Example: `T = 225`,
    /// `p = 100,010,000`: `b = 99,900,000` agrees, `b = 97,500,000` disagrees.
    /// @custom:spec SPEC-ORC-003, REQ-ORACLE-008, ATTACK-054, Q-184
    function routesAgree(
        uint256 primary,
        uint256 alternate,
        uint16 toleranceBps
    ) internal pure returns (bool agree) {
        return _withinTolerance(primary, alternate, toleranceBps);
    }

    /// @notice Second-source confirmation: readable and valid, and `|q - s| * 10^4 <= S * min(q, s)` (`SPEC-ORC-020`).
    /// @dev Same exact, symmetric, bounded test as `routesAgree` on the uncapped quote. Example: `S = 100`,
    /// `q = 100,020,000`: `s = 99,400,000` is confirmed, `s = 98,900,000` is not.
    /// @param sourceValid The second source was read and passed its own validity rules.
    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100
    function secondSourceAgrees(
        bool sourceValid,
        uint256 quote,
        uint256 secondSource,
        uint16 toleranceBps
    ) internal pure returns (bool confirmed) {
        return sourceValid && _withinTolerance(quote, secondSource, toleranceBps);
    }

    /// @notice Informational deviation `floor(|x - y| * 10^4 / min(x, y))` in bps (`REQ-ORACLE-042`).
    /// @dev `type(uint256).max` when either value is 0 (unreadable) or when `|x - y| * 10^4` needs more than 256 bits,
    /// so an `Invalid` route's unbounded value never makes a view revert. Never used for a decision.
    /// @custom:spec REQ-ORACLE-042
    function deviationBps(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256 bps) {
        (uint256 lo, uint256 hi) = x < y ? (x, y) : (y, x);
        if (lo == 0 || hi - lo > SATURATED / BPS) return SATURATED;
        return ((hi - lo) * BPS) / lo;
    }

    /// @notice Valuation price: `min(q, stableCeilingUsd)` for a USD-pegged stable, else `q` (`SPEC-ORC-004`).
    /// @dev Example: GHO at 100,300,000 is valued at 100,000,000; USDC at 99,987,000 passes unchanged.
    /// @custom:spec SPEC-ORC-004, REQ-ORACLE-009
    function valuationPrice(
        uint256 quote,
        bool isUsdStable
    ) internal pure returns (uint256 price) {
        return isUsdStable && quote > STABLE_CEILING_USD ? STABLE_CEILING_USD : quote;
    }

    // ─── Composition value ───

    /// @notice Price of one whole vault token from the composition `a = composition(10^d, v)` (`SPEC-ORC-008`).
    /// @dev `a'_i = a_i - 1` if `a_i >= 1`, else 0; `price8 = max(1, sum_i floor(a'_i * v_i / 10^(d_i)))`. Every term
    /// rounds down, so the price never exceeds the value of the holdings at the oracle prices, and it is at least 1.
    /// The shortfall against the exact value is at most two raw units of each token plus one price unit per token. For a
    /// low-decimals, high-price token (WBTC: one raw unit is $0.001 at $100,000) priced per whole vault token worth $1
    /// to $10 (`SPEC-ORC-005`), that is up to ~2e-3 relative. It is kept, not tightened: it only ever understates the
    /// collateral (never in the borrower's favour against lenders), it is below the 50 bps deviation threshold of the
    /// feeds the price already tolerates, and it falls as the vault token appreciates (TEST-070 WBTC case).
    /// `valid` is false, with `price8 = 0`, unless the three vectors have one length `n` in `[2, MAX_POOL_TOKENS]`,
    /// every `a_i < 2^128`, every `d_i <= 77` and every `v_i` in `[1, MAX_ROUTE_ANSWER]`: a malformed module read
    /// (`REQ-ORACLE-103`), never a revert or a dropped token. Inside the bounds every term is below `2^188` and the
    /// sum of at most eight terms below `2^191` (MATH-UO-75a).
    /// @param amounts Composition `a_i` in raw token units, floored by the pricing module.
    /// @param prices Valuation prices `v_i`, 8 decimals.
    /// @param tokenDecimals Token decimals `d_i`.
    /// @return valid The inputs are within the bounds.
    /// @return price8 USD value of `10^d` vault-token units, 8 decimals, at least 1 when valid.
    /// @custom:spec SPEC-ORC-008, REQ-ORACLE-011, REQ-ORACLE-012, REQ-ORACLE-013, REQ-ORACLE-103, INV-055
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

    /// @notice Vault-token decimals: the smallest `d` in `[6, 18]` with `price8(10^d) >= 10^8` (`SPEC-ORC-005`).
    /// @dev Calls the pricing module's `composition(units, prices)` once per candidate, from 6 up, and returns at the
    /// first that passes; `found` is false when none does or when a composition is malformed (`lpPrice` not valid), and
    /// the listing reverts. Example: full-range DAI/USDC at $1 gives 12; USDC/USDT on `[-10, 10]` at (0.99987, 1) gives
    /// 10, because `d = 9` is worth $0.9996.
    /// @param composition The pricing module's composition at the listing valuation prices.
    /// @param prices Listing valuation prices `v`, 8 decimals.
    /// @param tokenDecimals Token decimals in pool order.
    /// @custom:spec SPEC-ORC-005, REQ-ORACLE-047, REQ-ORACLE-103
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

    // ─── USD band and level ───

    /// @notice USD band: `usdBandLow^⊗n <= ⊗ q_i` and `⊗ v_i <= usdBandHigh^⊗n` (`SPEC-ORC-011`).
    /// @dev `x ⊗ y = floor(x * y / 10^8)`, left to right in pool order; `⊗` is not associative, so another order can
    /// flip the test exactly at an edge. The lower bound is tested on the uncapped quotes and the upper bound on the
    /// capped valuation prices. `valid` is false, with `inBand = false`, unless both vectors have one length `n` in
    /// `[2, MAX_POOL_TOKENS]` and every entry is in `[1, MAX_ROUTE_ANSWER]` (`REQ-ORACLE-103`). `usdBandLow = 0` and
    /// `usdBandHigh = type(uint256).max` always pass. Example (band 90,000,000 / 102,000,000): GHO at 104,700,000 with
    /// USDC at 10^8 is in band (`104,700,000 >= 81,000,000`, capped `10^8 <= 104,040,000`); both tokens at 89,000,000
    /// give 79,210,000 and fail.
    /// @custom:spec SPEC-ORC-011, REQ-ORACLE-009, REQ-ORACLE-015, REQ-ORACLE-103
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

    /// @notice USD level `max{L : L^⊗n <= ⊗ q_i}` that `getPriceState().usdLevel` reports (`SPEC-ORC-011`).
    /// @dev `usdBandLow <= usdLevel` holds exactly when `usdBandLow^⊗n <= ⊗ q_i`, because `L ↦ L^⊗n` is non-decreasing.
    /// Binary search from `min q` (whose power is at most the product) up to `max q + 1`, doubled until its power exceeds
    /// the product; about `log2(max q - min q)` steps of `n` fixed-point products. 0 when the quotes are malformed;
    /// `type(uint256).max` when their product saturates (eight quotes near `MAX_ROUTE_ANSWER`).
    /// Example: `(99,987,000, 100,010,000)` gives 99,998,499; `(81,000,001, 10^8)` gives 90,000,001.
    /// @custom:spec SPEC-ORC-011, REQ-ORACLE-042
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
        // A product that saturated exceeds every power that does not, so every band level passes (`inUsdBand` compares
        // with the same saturated product): the level is reported as saturated too, and the search below, which could
        // otherwise double `hi` past 256 bits, never runs on it.
        if (product == SATURATED) return SATURATED;
        // Invariant: lo^⊗n <= product < hi^⊗n. The product is below 2^256 and hi^⊗n >= hi for hi >= 10^8, so the
        // doubling stops before hi reaches 2^256.
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

    /// @notice `x_0 ⊗ x_1 ⊗ … ⊗ x_(n-1)`, left to right; `10^8` for an empty vector (`SPEC-ORC-011`).
    /// @dev Exact below the listing bounds (two values `<= MAX_ROUTE_ANSWER` stay below `10^28`; eight can reach `10^88` and saturate); a product of 256 bits
    /// or more saturates at `type(uint256).max` and stays there for every later factor, so the function never reverts.
    /// @custom:spec SPEC-ORC-011
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

    /// @notice `b^⊗n`: `b` multiplied by itself `n` times with `⊗`, saturating as `fixedPointProduct` (`SPEC-ORC-011`).
    /// @dev Callers pass `n <= MAX_POOL_TOKENS`.
    /// @custom:spec SPEC-ORC-011
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

    // ─── Served price and its age ───

    /// @notice Source timestamp of the served price (`SPEC-ORC-012`).
    /// @dev Not failed: `min_i t_i`, the oldest input of the routes whose values are used, and 0 (an age every check
    /// refuses) when no timestamp is given. Failed: the accepted price's timestamp, so re-reading never refreshes it.
    /// @param tokenTimestamps `t_i` of each token's route in use.
    /// @custom:spec SPEC-ORC-012, REQ-ORACLE-021, REQ-ORACLE-066
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

    /// @notice Age limits of the served price for borrow and liquidation (`SPEC-ORC-015`).
    /// @dev `deadline = min over legs of (updatedAt + limit)`, with the liquidation limit of an alternate leg
    /// `min(liquidationPriceMaxAge, borrowPriceMaxAge)`; each limit is `deadline - servedUpdatedAt`, where
    /// `servedUpdatedAt` is the oldest leg in use (`SPEC-ORC-012`), so neither subtraction underflows and each limit is
    /// at most the oldest leg's own limit. Both are 0 when the market is failed or no leg is given. Example: USDC/USD at
    /// 1,762,600,000 (84,600) with USDT/ETH at 1,762,640,000 (88,200) × ETH/USD at 1,762,645,000 (5,400) on the
    /// alternate: both limits are 50,400.
    /// @param legs Every leg of every route in use.
    /// @custom:spec SPEC-ORC-015, REQ-ORACLE-043, REQ-ORACLE-090
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

    /// @notice Served collateral price by state (`SPEC-ORC-017`).
    /// @dev Expired: 1. Cached: `A`. Some token disagreeing (`pauseActive ∨ disagreementExpired`) and not failed:
    /// `min(lower, fresh)`, because the floored `lower` can exceed the floored `fresh` by a few units. Live and Drifting
    /// otherwise: `fresh`. The accepted price `A` is served only while Cached: it bounds borrowing (the RiskModule values
    /// new debt and pledge bookings at `min(fresh, A)`), never liquidation, so a rally after the last accepted price can
    /// never make an account liquidatable, while a fall still can. The result is at least 1 for any inputs and at most
    /// `fresh` in every state but Cached and Expired. Example: `A = 199,980,000`, `lower = 197,483,855`, `fresh =
    /// 219,999,600` serves 197,483,855 during a disagreement, 219,999,600 while Drifting on a consistency deviation,
    /// 199,980,000 when Cached and 1 when Expired.
    /// @param state Price state of the market.
    /// @param disagreeing Some token disagrees.
    /// @param fresh `price8(v)` of the current evaluation.
    /// @param lower `price8(w)` at each token's lower route, capped.
    /// @param accepted The accepted price `A`.
    /// @custom:spec SPEC-ORC-017, REQ-ORACLE-020, REQ-ORACLE-060, REQ-ORACLE-085, REQ-ORACLE-086, INV-087
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

    /// @notice Served debt price by state (`SPEC-ORC-018`).
    /// @dev Live: `q`. Drifting (the routes disagree): `max(p, b, A)`; the DebtOracle passes the lower route as both
    /// `p` and `b`, so it serves the median `max(min(p, b), A)` (ORACLE-06). Cached: `A`. Expired:
    /// `ceil(A * (10^4 + δ) / 10^4)`, rounding up against the borrower, with `δ` below 100 read as 100 and a product of
    /// 256 bits or more saturating at `type(uint256).max`. No stable ceiling. The route values round down by less than
    /// one unit (exact for a feed with 8 or fewer decimals). The result is at least 1 for any inputs and at least `A` in
    /// every state but Live. Example: `A = 99,990,000`, `δ = 500`: Expired serves 104,989,500; `A = 99,987,001` serves
    /// 104,986,352.
    /// @param stressRiseBps `debtStressRiseBps(asset)`, in `[100, 5,000]`.
    /// @custom:spec SPEC-ORC-018, REQ-ORACLE-093, INV-087
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

    // ─── Sequencer, observation buffer and gas guard ───

    /// @notice L2 sequencer gate (`SPEC-ORC-021`).
    /// @dev `up = (answer == 0) ∧ (startedAt != 0) ∧ (startedAt <= now)`; `down = (answer == 1)`; any other answer, or a
    /// read that reverted or did not decode, is `unknown`; `inGrace = up ∧ now - startedAt < gracePeriod`;
    /// `ready = up ∧ now - startedAt >= gracePeriod`. With no feed, `ready` is true and the other four are false.
    /// Example: restart at 1,010,000 with a 3,600 s grace period: in grace to 1,013,599, ready from 1,013,600.
    /// @param hasFeed The chain's `sequencer.feed != address(0)`.
    /// @param readOk The `latestRoundData()` read succeeded and decoded.
    /// @custom:spec SPEC-ORC-021, REQ-ORACLE-099
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

    /// @notice Observation buffer a pool needs for a window `W`: `ceil(W / CHAIN_BLOCK_TIME) + 1` (`SPEC-ORC-022`).
    /// @dev A block time of 0 gives `type(uint256).max`, which no cardinality reaches, so the listing check fails closed.
    /// Example: `W = 1,800` needs 151 observations on Ethereum (12 s) and 901 on Base (2 s).
    /// @param blockTime The chain's minimum block interval, seconds.
    /// @custom:spec SPEC-ORC-022, REQ-ORACLE-055, REQ-ORACLE-105
    function minObservations(
        uint256 window,
        uint256 blockTime
    ) internal pure returns (uint256 observations) {
        if (blockTime == 0) return SATURATED;
        uint256 k = Math.ceilDiv(window, blockTime);
        return k == SATURATED ? SATURATED : k + 1;
    }

    /// @notice Gas required before an external read with explicit gas `G`: `ceil(64 * G / 63) + POST_CALL_GAS`
    /// (`SPEC-ORC-023`).
    /// @dev With that much left, the EVM forwards the full `G`. A `G` with `64 * G` above 256 bits gives
    /// `type(uint256).max`. Example: `G = 50,000` needs 55,794.
    /// @custom:spec SPEC-ORC-023, REQ-ORACLE-039, REQ-ORACLE-102
    function gasForCall(
        uint256 callGas
    ) internal pure returns (uint256 required) {
        if (callGas > SATURATED / 64) return SATURATED;
        return Math.ceilDiv(64 * callGas, 63) + POST_CALL_GAS;
    }

    /// @notice One read's term of `POKE_MIN_GAS_FLOOR >= max(W_poke, max_k(u_k + ceil(64 * G_k / 63) + POST_CALL_GAS))`
    /// (`SPEC-ORC-023`): `u_k + ceil(64 * G_k / 63) + POST_CALL_GAS`, with `u_k` the gas used before read `k`.
    /// @dev An entry gas of at least the term leaves read `k` its pre-call bound; with `u_k = W_poke` and `G_k = G_max`
    /// it is the single-term bound that needs no per-read measurement. A sum of 256 bits or more gives
    /// `type(uint256).max`. Example: the binding read of the two-token worst-case poke, a feed read at `u = 718,836`,
    /// gives 774,630; `W_poke = 450,000` with `G = 100,000` gives 556,588.
    /// @custom:spec SPEC-ORC-023, REQ-ORACLE-038
    function pokeMinGasFloor(
        uint256 usedBefore,
        uint256 callGas
    ) internal pure returns (uint256 floor) {
        uint256 callBound = gasForCall(callGas);
        if (usedBefore > SATURATED - callBound) return SATURATED;
        return usedBefore + callBound;
    }

    // ─── Private helpers ───

    /// @dev `(true, a)` for a signed answer `0 < a < 2^128`, else `(false, 0)`.
    function _answer(
        int256 answer
    ) private pure returns (bool ok, uint256 value) {
        if (answer <= 0) return (false, 0);
        value = SafeCast.toUint256(answer);
        if (value >= ANSWER_BOUND) return (false, 0);
        return (true, value);
    }

    /// @dev `1 <= x <= MAX_ROUTE_ANSWER`.
    function _isRouteValue(
        uint256 x
    ) private pure returns (bool) {
        return x != 0 && x <= MAX_ROUTE_ANSWER;
    }

    /// @dev `MIN_POOL_TOKENS <= n <= MAX_POOL_TOKENS`.
    function _tokenCountOk(
        uint256 n
    ) private pure returns (bool) {
        return n >= AmmConstants.MIN_POOL_TOKENS && n <= AmmConstants.MAX_POOL_TOKENS;
    }

    /// @dev Both values in `[1, MAX_ROUTE_ANSWER]` and `|x - y| * 10^4 <= t * min(x, y)`.
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

    /// @dev `x ⊗ y = floor(x * y / 10^8)`; `type(uint256).max` when either factor is saturated or `x * y` needs more
    /// than 256 bits. A genuine floor is below `2^256 / 10^8`, so the saturated value is unambiguous.
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
