// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegrationHooks} from "../../amm/IAmmIntegrationHooks.sol";
import {IClIntegration} from "../../amm/IClIntegration.sol";
import {ClPriceMath} from "../../amm/concentrated-liquidity/ClPriceMath.sol";
import {ClUnitMath} from "../../amm/concentrated-liquidity/ClUnitMath.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {IMarketRegistryViews} from "../../policy/market-registry/IMarketRegistryViews.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPOracleCLModule
/// @notice The concentrated-liquidity pricing module of the LPOracle (2.10 Concentrated-liquidity pricing): the
/// composition at the oracle square-root price clamped to the market's range (`SPEC-ORC-006`, `SPEC-ORC-009`), the TWAP
/// consistency check (`SPEC-ORC-010`), the pool's reentrancy lock, the `PoolTwap` second source, the own-pool test, the
/// listing checks (`REQ-ORACLE-105`), the market check of `initialize` and the report of `getClPriceState()`
/// (`REQ-ORACLE-104`).
/// @dev Compiled into `LPOracleCL` (for `initialize`) and into `LPOracleCLModuleLogic`, the one module contract per
/// implementation that the poke, listing and view logic contracts reach by delegatecall (2.10 Upgrade rules), so every
/// hook runs in the proxy's storage. The composition reads no pool state: only the stored range and unit exponent, the
/// token decimals, `units` and the price vector, so moving the pool's spot price cannot move it (`SPEC-ORC-007`). It returns the floored
/// amounts of `LiquidityAmounts.getAmountsForLiquidity`; `LPPriceMath.lpPrice` then takes one raw unit off each
/// (`SPEC-ORC-008`), so the deduction is made once. Every hook is a view that never reverts except `InsufficientGas`.
/// Example: full-range USDC/USDT (spacing 1, both at $1, `d = 6`) composes `10^6` units to `(999,999, 999,999)`,
/// priced at `199,999,600`.
/// @custom:spec REQ-ORACLE-011, REQ-ORACLE-012, REQ-ORACLE-014, REQ-ORACLE-048, REQ-ORACLE-055, REQ-ORACLE-100, REQ-ORACLE-103, REQ-ORACLE-104, REQ-ORACLE-105, SPEC-ORC-006, SPEC-ORC-009, SPEC-ORC-010, SPEC-ORC-020, SPEC-ORC-022, REQ-AMM-V3-005, REQ-AMM-SLIP-005, REQ-AMM-CORE-004
abstract contract LPOracleCLModule is LPOracleCLPool {
    /// @notice Listing bit of the module, shifted to `MODULE_CHECKS_SHIFT` by the base: the range is misaligned,
    /// inverted or outside the usable ticks of the pool's spacing read now (`REQ-ORACLE-105`).
    uint256 internal constant CL_CHECK_RANGE = 1 << 0;
    /// @notice `twapWindow == 0`, `twapToleranceTicks < TWAP_TOLERANCE_MIN_TICKS` or `twapMinObservations` other than
    /// `SPEC-ORC-022` at the chain's block time (`REQ-ORACLE-055`).
    uint256 internal constant CL_CHECK_TWAP_CONFIG = 1 << 1;
    /// @notice The pool's observation cardinality is below `twapMinObservations`, or `slot0` cannot be read.
    uint256 internal constant CL_CHECK_CARDINALITY = 1 << 2;
    /// @notice `observe([twapWindow, 0])` fails.
    uint256 internal constant CL_CHECK_OBSERVE = 1 << 3;
    /// @notice At a shocked price vector the raw ratio is not below `2^128` (`num < 2^128 * den` fails, `SPEC-ORC-009`).
    uint256 internal constant CL_CHECK_SHOCK_SQRT = 1 << 4;
    /// @notice A `PoolTwap` second source names a pool that does not pair its token with the market's other token.
    uint256 internal constant CL_CHECK_POOL_TWAP = 1 << 5;
    /// @notice The integration reports a rate provider for a token (`REQ-AMM-CORE-004`): the concentrated-liquidity
    /// module values every token at its Chainlink USD price and has no rate-feed path, so a rate token is refused.
    uint256 internal constant CL_CHECK_RATE_TOKEN = 1 << 6;
    /// @notice The integration's unit exponent of the market (`IClIntegration.unitExponent`) is not the `k` stored at
    /// `initialize` (`SPEC-ORC-005`): the feed would price `10^d` units of another size than the vault token's.
    uint256 internal constant CL_CHECK_UNIT_EXP = 1 << 7;
    /// @notice Smallest consistency tolerance a market may carry, ticks (`twapToleranceMinTicks`, `REQ-ORACLE-055`).
    uint16 internal constant TWAP_TOLERANCE_MIN_TICKS = 10;
    /// @dev Largest token decimals the module prices: `p * 10^d` must fit with `p <= MAX_ROUTE_ANSWER`.
    uint8 internal constant CL_MAX_TOKEN_DECIMALS = 18;

    // ─── Market (REQ-ORACLE-058) ───

    /// @dev `market = abi.encode(pool, tickLower, tickUpper, unitExp)`: the pool's `token0()` and `token1()` must be
    /// `tokens` in that order, both tokens at most 18 decimals, the range usable at the pool's `tickSpacing()`
    /// (`SPEC-BACK-001`) and `unitExp` the pool's unit exponent `k <= MAX_UNIT_EXP` (`SPEC-ORC-005`: the pool's stored
    /// one, or `ClUnitMath.firstBindingExponent` at the listing prices for the pool's first market). Stores the pool,
    /// range, spacing, the range's square-root ratios and `k`; `CL_CHECK_UNIT_EXP` requires the integration's `k` to
    /// equal it once the market is bound.
    /// @custom:spec REQ-ORACLE-048, REQ-ORACLE-058, REQ-ORACLE-103, REQ-ORACLE-105
    function _initMarket(
        bytes calldata market,
        address[] memory tokens
    ) internal virtual override returns (bool ok) {
        if (market.length != 128 || tokens.length != 2) return false;
        (address pool, int24 lower, int24 upper, bool shaped) = _decodeMarket(market);
        uint256 unitExp = uint256(bytes32(market[96:128]));
        if (!shaped || unitExp > ClUnitMath.MAX_UNIT_EXP || pool.code.length == 0) return false;
        uint8[] storage decs = _s().tokenDecimals;
        if (decs[0] > CL_MAX_TOKEN_DECIMALS || decs[1] > CL_MAX_TOKEN_DECIMALS) return false;
        (bool ok0, address t0) = _poolAddress(pool, abi.encodeCall(IUniswapV3Pool.token0, ()), CONFIG_CALL_GAS);
        (bool ok1, address t1) = _poolAddress(pool, abi.encodeCall(IUniswapV3Pool.token1, ()), CONFIG_CALL_GAS);
        (bool okS, int24 spacing) = _tickSpacing(pool);
        if (!ok0 || !ok1 || !okS || t0 != tokens[0] || t1 != tokens[1]) return false;
        if (!ClPriceMath.isUsableRange(lower, upper, spacing)) return false;
        ClLayout storage c = _cl();
        (c.pool, c.tickLower, c.tickUpper, c.tickSpacing) = (pool, lower, upper, spacing);
        (c.sqrtLower, c.sqrtUpper) = (ClPriceMath.sqrtRatioAtTick(lower), ClPriceMath.sqrtRatioAtTick(upper));
        // At most MAX_UNIT_EXP = 18, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.unitExp = uint8(unitExp);
        return true;
    }

    /// @dev The first three words of `market`; `shaped` false for an address above 160 bits or a tick outside `int24`.
    function _decodeMarket(
        bytes calldata market
    ) private pure returns (address pool, int24 lower, int24 upper, bool shaped) {
        uint256 word = uint256(bytes32(market[0:32]));
        // Two's-complement reinterpretation of an ABI word, range-checked below.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 lo = int256(uint256(bytes32(market[32:64])));
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 hi = int256(uint256(bytes32(market[64:96])));
        shaped = word <= type(uint160).max && lo >= type(int24).min && lo <= type(int24).max && hi >= type(int24).min
            && hi <= type(int24).max;
        if (!shaped) return (address(0), 0, 0, false);
        // Each value was range-checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        (pool, lower, upper) = (address(uint160(word)), int24(lo), int24(hi));
    }

    // ─── Pricing hooks (REQ-ORACLE-103) ───

    /// @dev `SPEC-ORC-006`: the amounts `units` vault-token units, `units * 10^k` liquidity (`SPEC-ORC-005`), hold at
    /// `s = clamp(SPEC-ORC-009(p0, p1), s_a, s_b)`, each floored; `ok` false for a vector of another length, a price
    /// outside `[1, MAX_ROUTE_ANSWER]`, `units >= 2^128` or `units * 10^k >= 2^128`.
    /// @custom:spec SPEC-ORC-006, SPEC-ORC-009, REQ-ORACLE-011, REQ-ORACLE-012, REQ-ORACLE-103, REQ-AMM-V3-005
    function _composition(
        uint256 units,
        uint256[] memory prices
    ) internal view virtual override returns (bool ok, uint256[] memory amounts) {
        if (prices.length != 2 || units >= LPPriceMath.ANSWER_BOUND || !_pricesOk(prices)) return (false, amounts);
        ClLayout storage c = _cl();
        // units < 2^128 and 10^k <= 10^18 < 2^60, so the product cannot overflow.
        uint256 liquidity = units * 10 ** uint256(c.unitExp);
        if (liquidity >= LPPriceMath.ANSWER_BOUND) return (false, amounts);
        (uint160 sa, uint160 sb) = (c.sqrtLower, c.sqrtUpper);
        uint160 s = ClPriceMath.clamp(_oracleSqrt(prices), sa, sb);
        amounts = new uint256[](2);
        (amounts[0], amounts[1]) = ClPriceMath.amountsForLiquidity(s, sa, sb, liquidity);
        ok = true;
    }

    /// @dev `slot0()` of the market's pool, read once: `locked` while the pool is inside a swap, flash, mint, burn or
    /// collect (reason bit 17), `readOk` false for a failed or malformed read (reason bit 1); then, when the pool is
    /// readable and unlocked, `SPEC-ORC-010` on the uncapped quotes with the observation cardinality of the same read,
    /// and the clamp of `REQ-ORACLE-104` on the valuation prices. Unavailable (reason bit 5) for a zero window, a
    /// cardinality below `SPEC-ORC-022`, a failed `observe` or a quote outside `[1, MAX_ROUTE_ANSWER]`;
    /// `deviationBps` is `|meanTick - tickRef|` in ticks (one tick is about 1 bp).
    /// @custom:spec REQ-ORACLE-103, REQ-AMM-V3-003, REQ-AMM-SLIP-003, SPEC-ORC-010, SPEC-ORC-022, REQ-ORACLE-014, REQ-ORACLE-104
    function _poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) internal view virtual override returns (PoolCheck memory p) {
        bool unlocked;
        uint16 cardinality;
        (p.readOk, cardinality, unlocked) = _slot0(_cl().pool);
        p.locked = p.readOk && !unlocked;
        if (!p.readOk || p.locked || prices.length != 2 || !_pricesOk(prices)) return p;
        uint160 sV = _oracleSqrt(prices);
        p.clamped = _clampedFrom(sV, prices);
        if (quotes.length != 2 || !_pricesOk(quotes)) return p;
        if (cardinality < LPPriceMath.minObservations(window, _CHAIN_BLOCK_TIME)) return p;
        int24 meanTick;
        (p.available, meanTick) = _meanTick(_cl().pool, window);
        if (!p.available) return p;
        // The quotes equal the valuation prices unless a stable is above its ceiling: the root is then reused.
        uint160 sQ = quotes[0] == prices[0] && quotes[1] == prices[1] ? sV : _oracleSqrt(quotes);
        p.deviationBps = _tickDistance(meanTick, ClPriceMath.tickAtSqrtRatio(sQ));
        p.pass = p.deviationBps <= toleranceBps;
    }

    /// @dev `SPEC-ORC-020` `PoolTwap`: the deep pool `poolRef` must pair token `index` with the market's other token
    /// `j`; its mean tick over `twapWindow` gives the amount of token `j` one whole token `index` buys (Uniswap
    /// `OracleLibrary.getQuoteAtTick`), valued at `q_j`. `ok` false for an unreadable or mispaired pool or a buffer that
    /// does not cover the window.
    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100
    function _poolTwapPrice(
        uint256 index,
        SecondSource memory source,
        uint256[] memory quotes
    ) internal view virtual override returns (bool ok, uint256 value) {
        if (index > 1 || quotes.length != 2 || !_pricesOk(quotes)) return (false, 0);
        (bool paired, bool baseIsToken0, address pool) = _deepPool(index, source.poolRef);
        if (!paired) return (false, 0);
        int24 tick;
        (ok, tick) = _meanTick(pool, source.twapWindow);
        if (!ok) return (false, 0);
        uint8[] storage decs = _s().tokenDecimals;
        uint256 j = 1 - index;
        uint256 other = _quoteAtTick(tick, 10 ** uint256(decs[index]), baseIsToken0);
        value = Math.mulDiv(other, quotes[j], 10 ** uint256(decs[j]));
    }

    /// @dev True when `poolRef` is `bytes32(uint256(uint160(pool)))` of the market's pool (`REQ-ORACLE-100`).
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-100, REQ-ORACLE-103
    function _isOwnPool(
        bytes32 poolRef
    ) internal view virtual override returns (bool own) {
        own = poolRef == bytes32(uint256(uint160(_cl().pool)));
    }

    /// @dev The module's listing checks on `config` (`_clListingChecks`).
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-105
    function _listingChecks(
        OracleConfig calldata config,
        uint256[] memory quotes
    ) internal view virtual override returns (uint256 failedChecks) {
        failedChecks = _clListingChecks(_listingInputs(config), quotes);
    }

    /// @dev `REQ-ORACLE-105` and `REQ-ORACLE-055` on the pool and the configuration words `x`, `SPEC-ORC-009`'s lower
    /// branch at the prices `quotes` shocked by `LISTING_SHOCK_FACTOR` each way (the base passes the current quotes at
    /// listing and the listing prices once the market is registered), the `PoolTwap` pairing, the rate-token check and
    /// the unit-exponent check.
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-048, REQ-ORACLE-055, REQ-ORACLE-105, SPEC-ORC-022, REQ-AMM-CORE-004
    function _clListingChecks(
        ClListingInputs memory x,
        uint256[] memory quotes
    ) internal view returns (uint256 failed) {
        ClLayout storage c = _cl();
        (bool okS, int24 spacing) = _tickSpacing(c.pool);
        if (!okS || spacing != c.tickSpacing || !ClPriceMath.isUsableRange(c.tickLower, c.tickUpper, spacing)) {
            failed |= CL_CHECK_RANGE;
        }
        uint256 minObs = LPPriceMath.minObservations(x.twapWindow, _CHAIN_BLOCK_TIME);
        if (
            x.twapWindow == 0 || x.consistencyToleranceBps < TWAP_TOLERANCE_MIN_TICKS || x.twapMinObservations != minObs
        ) failed |= CL_CHECK_TWAP_CONFIG;
        (bool okC, uint16 cardinality,) = _slot0(c.pool);
        if (!okC || cardinality < minObs) failed |= CL_CHECK_CARDINALITY;
        (bool observed,) = _meanTick(c.pool, x.twapWindow);
        if (!observed) failed |= CL_CHECK_OBSERVE;
        if (!_shockSqrtHolds(quotes)) failed |= CL_CHECK_SHOCK_SQRT;
        for (uint256 i = 0; i < x.pairs; ++i) {
            if (x.kinds[i] != SecondSourceKind.PoolTwap) continue;
            (bool paired,,) = _deepPool(i, x.poolRefs[i]);
            if (!paired) failed |= CL_CHECK_POOL_TWAP;
        }
        if (!_noRateTokens()) failed |= CL_CHECK_RATE_TOKEN;
        if (!_unitExpMatches()) failed |= CL_CHECK_UNIT_EXP;
    }

    /// @dev `integration.unitExponent(marketId)` equals the stored `k` (`SPEC-ORC-005`). Before the integration binds the
    /// market (at `initialize`, which precedes the listing batch) the read reverts and is not counted; from the
    /// MarketRegistry's registration on, a failed or malformed read or another exponent fails the check.
    /// @custom:spec SPEC-ORC-005, REQ-ORACLE-046, REQ-ORACLE-105
    function _unitExpMatches() internal view returns (bool) {
        Layout storage $ = _s();
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            $.integration, CONFIG_CALL_GAS, abi.encodeCall(IClIntegration.unitExponent, ($.marketId)), 32 + 1
        );
        if (!ok) return !_bound();
        return ret.length == 32 && _wordIs(ret, 0, _cl().unitExp);
    }

    /// @dev `integration.rateProviders(marketId)` is two zero addresses (`REQ-AMM-CORE-004`). Before the integration
    /// binds the market (at `initialize`, which precedes the listing batch) the read reverts and is not counted; from
    /// the MarketRegistry's registration on, a failed or malformed read or any non-zero provider fails the check.
    /// @custom:spec REQ-AMM-CORE-004, REQ-ORACLE-046
    function _noRateTokens() internal view returns (bool) {
        Layout storage $ = _s();
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            $.integration, CONFIG_CALL_GAS, abi.encodeCall(IAmmIntegrationHooks.rateProviders, ($.marketId)), 4 * 32 + 1
        );
        if (!ok) return !_bound();
        return ret.length == 4 * 32 && _wordIs(ret, 0, 32) && _wordIs(ret, 32, 2) && _wordIs(ret, 64, 0)
            && _wordIs(ret, 96, 0);
    }

    /// @dev The word at byte `offset` of `ret` exists and equals `value`.
    function _wordIs(
        bytes memory ret,
        uint256 offset,
        uint256 value
    ) private pure returns (bool) {
        (bool ok, uint256 word) = LPOracleCalls.wordAt(ret, offset);
        return ok && word == value;
    }

    /// @dev Whether the MarketRegistry has registered this feed (`marketOfLpOracle != 0`), or the read fails.
    function _bound() private view returns (bool) {
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            _s().marketRegistry,
            CONFIG_CALL_GAS,
            abi.encodeCall(IMarketRegistryViews.marketOfLpOracle, (address(this))),
            32
        );
        (bool okW, uint256 id) = LPOracleCalls.wordAt(ret, 0);
        return !ok || !okW || id != 0;
    }

    // ─── Report (REQ-ORACLE-104) ───

    /// @dev `getClPriceState()` from one evaluation's quotes and valuation prices (`priced` false when the market is
    /// failed: the range, tolerance and cardinality are reported and every price field is 0).
    /// @custom:spec REQ-ORACLE-042, REQ-ORACLE-104
    function _clReport(
        bool priced,
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceTicks
    ) internal view returns (ClPriceStateView memory r) {
        ClLayout storage c = _cl();
        (r.tickLower, r.tickUpper, r.twapToleranceTicks) = (c.tickLower, c.tickUpper, toleranceTicks);
        (, r.observationCardinality,) = _slot0(c.pool);
        if (!priced || prices.length != 2 || !_pricesOk(prices)) return r;
        r.sqrtPriceOracleX96 = _oracleSqrt(prices);
        r.sqrtPriceUsedX96 = ClPriceMath.clamp(r.sqrtPriceOracleX96, c.sqrtLower, c.sqrtUpper);
        r.clamped = _clampedAt(prices);
        if (quotes.length != 2 || !_pricesOk(quotes)) return r;
        if (r.observationCardinality < LPPriceMath.minObservations(window, _CHAIN_BLOCK_TIME)) return r;
        (bool available, int24 meanTick) = _meanTick(c.pool, window);
        if (!available) return r;
        r.meanTick = meanTick;
        r.tickRef = ClPriceMath.tickAtSqrtRatio(_oracleSqrt(quotes));
        // The distance of two ticks in [MIN_TICK, MAX_TICK] is below 2^21.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.tickDeviation = uint24(_tickDistance(r.meanTick, r.tickRef));
    }

    // ─── Internal ───

    /// @dev `SPEC-ORC-009` at `x` with the stored token decimals.
    function _oracleSqrt(
        uint256[] memory x
    ) internal view returns (uint160) {
        uint8[] storage decs = _s().tokenDecimals;
        return ClPriceMath.oracleSqrtPrice(x[0], x[1], decs[0], decs[1]);
    }

    /// @dev Whether `SPEC-ORC-009` clamped at `prices` or the range clamp of `SPEC-ORC-006` changes the price.
    function _clampedAt(
        uint256[] memory prices
    ) internal view returns (bool) {
        if (prices.length != 2 || !_pricesOk(prices)) return false;
        return _clampedFrom(_oracleSqrt(prices), prices);
    }

    /// @dev `_clampedAt` with the oracle square-root price `s` of `prices` already computed: `SPEC-ORC-009` clamps only
    /// to `MIN_SQRT_RATIO` or `MAX_SQRT_RATIO - 1`, so its own test runs only at those two values.
    function _clampedFrom(
        uint160 s,
        uint256[] memory prices
    ) internal view returns (bool) {
        if (s == ClPriceMath.MIN_SQRT_RATIO || s == ClPriceMath.MAX_SQRT_RATIO - 1) {
            uint8[] storage decs = _s().tokenDecimals;
            if (ClPriceMath.oracleSqrtClamped(prices[0], prices[1], decs[0], decs[1])) return true;
        }
        ClLayout storage c = _cl();
        return s < c.sqrtLower || s > c.sqrtUpper;
    }

    /// @dev `|a - b|` of two ticks.
    function _tickDistance(
        int24 a,
        int24 b
    ) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        // |d| is at most 2 * MAX_TICK; the sign is tested first.
        // forge-lint: disable-next-line(unsafe-typecast)
        return d < 0 ? uint256(-d) : uint256(d);
    }

    /// @dev Every entry in `[1, MAX_ROUTE_ANSWER]`, the bound under which `SPEC-ORC-009` cannot overflow.
    function _pricesOk(
        uint256[] memory x
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < x.length; ++i) {
            if (x[i] == 0 || x[i] > LPPriceMath.MAX_ROUTE_ANSWER) return false;
        }
        return true;
    }

    /// @dev `num < 2^128 * den` of `SPEC-ORC-009` (the sqrt price is exact to `2^-96` relative and not clamped) with
    /// token0 raised and token1 lowered by `LISTING_SHOCK_FACTOR`, and the reverse, each shocked price kept in
    /// `[1, MAX_ROUTE_ANSWER]` (`REQ-ORACLE-105`). Tested as `num >> 128 < den`, which cannot overflow. The former
    /// `2^64` bound refused WBTC as token0 against an 18-decimal stable above about $184,467 (INTEG-04).
    function _shockSqrtHolds(
        uint256[] memory quotes
    ) internal view returns (bool) {
        if (quotes.length != 2 || !_pricesOk(quotes)) return false;
        uint8[] storage decs = _s().tokenDecimals;
        for (uint256 up = 0; up < 2; ++up) {
            uint256 p0 = up == 0 ? _raise(quotes[0]) : _lower(quotes[0]);
            uint256 p1 = up == 0 ? _lower(quotes[1]) : _raise(quotes[1]);
            uint256 num = p0 * 10 ** uint256(decs[1]);
            uint256 den = p1 * 10 ** uint256(decs[0]);
            if (num >> 128 >= den) return false;
        }
        return true;
    }

    function _raise(
        uint256 q
    ) private pure returns (uint256) {
        return Math.min(q * LISTING_SHOCK_FACTOR, LPPriceMath.MAX_ROUTE_ANSWER);
    }

    function _lower(
        uint256 q
    ) private pure returns (uint256) {
        return Math.max(q / LISTING_SHOCK_FACTOR, 1);
    }

    /// @dev The deep pool of a `PoolTwap` reference: an address-keyed pool whose `token0`/`token1` are the market's
    /// token `index` and its other token, in either order; `baseIsToken0` when token `index` is the pool's `token0`.
    function _deepPool(
        uint256 index,
        bytes32 poolRef
    ) internal view returns (bool paired, bool baseIsToken0, address pool) {
        if (uint256(poolRef) > type(uint160).max || index > 1) return (false, false, address(0));
        pool = address(uint160(uint256(poolRef)));
        if (pool.code.length == 0) return (false, false, pool);
        (bool ok0, address t0) = _poolAddress(pool, abi.encodeCall(IUniswapV3Pool.token0, ()), POOL_CALL_GAS);
        (bool ok1, address t1) = _poolAddress(pool, abi.encodeCall(IUniswapV3Pool.token1, ()), POOL_CALL_GAS);
        address[] storage tokens = _s().tokens;
        (address base, address other) = (tokens[index], tokens[1 - index]);
        paired = ok0 && ok1 && ((t0 == base && t1 == other) || (t0 == other && t1 == base));
        baseIsToken0 = t0 == base;
    }

    /// @dev Uniswap `OracleLibrary.getQuoteAtTick`: raw units of the other token `baseAmount` raw units of the base
    /// token buy at `tick` (token1 per token0 is `1.0001^tick`), rounded down.
    function _quoteAtTick(
        int24 tick,
        uint256 baseAmount,
        bool baseIsToken0
    ) internal pure returns (uint256 quote) {
        uint160 s = ClPriceMath.sqrtRatioAtTick(tick);
        if (s <= type(uint128).max) {
            uint256 ratioX192 = uint256(s) * s;
            return
                baseIsToken0
                    ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                    : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(s, s, 1 << 64);
        return
            baseIsToken0 ? Math.mulDiv(ratioX128, baseAmount, 1 << 128) : Math.mulDiv(1 << 128, baseAmount, ratioX128);
    }
}
