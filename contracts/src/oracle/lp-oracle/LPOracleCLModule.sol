// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegrationHooks} from "../../amm/IAmmIntegrationHooks.sol";
import {IClIntegration} from "../../amm/IClIntegration.sol";
import {ClPriceMath} from "../../amm/concentrated-liquidity/ClPriceMath.sol";
import {ClUnitMath} from "../../amm/concentrated-liquidity/ClUnitMath.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {SecondSourceKind} from "../../types/SecondSourceKind.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LPOracleCLModule
/// @notice Concentrated-liquidity pricing module of the LPOracle.
/// @dev The composition reads no pool state, so the pool's spot price cannot move it.
abstract contract LPOracleCLModule is LPOracleCLPool {
    /// @notice Listing bit: the range is not usable at the pool's current tick spacing.
    uint256 internal constant CL_CHECK_RANGE = 1 << 0;
    /// @notice Listing bit: the TWAP window, tolerance or minimum observations are invalid.
    uint256 internal constant CL_CHECK_TWAP_CONFIG = 1 << 1;
    /// @notice Listing bit: the pool's observation cardinality is too low, or `slot0` cannot be read.
    uint256 internal constant CL_CHECK_CARDINALITY = 1 << 2;
    /// @notice Listing bit: `observe([twapWindow, 0])` fails.
    uint256 internal constant CL_CHECK_OBSERVE = 1 << 3;
    /// @notice Listing bit: at a shocked price vector the raw price ratio is not below `2^128`.
    uint256 internal constant CL_CHECK_SHOCK_SQRT = 1 << 4;
    /// @notice Listing bit: a `PoolTwap` second source's pool does not pair the market's tokens.
    uint256 internal constant CL_CHECK_POOL_TWAP = 1 << 5;
    /// @notice Listing bit: the integration reports a rate provider; this module has no rate-feed path.
    uint256 internal constant CL_CHECK_RATE_TOKEN = 1 << 6;
    /// @notice Listing bit: the integration's unit exponent differs from the stored one.
    uint256 internal constant CL_CHECK_UNIT_EXP = 1 << 7;
    /// @notice Smallest consistency tolerance a market may carry, ticks.
    uint16 internal constant TWAP_TOLERANCE_MIN_TICKS = 10;
    uint8 internal constant CL_MAX_TOKEN_DECIMALS = 18;

    /// @dev Decodes `abi.encode(pool, tickLower, tickUpper, unitExp)`, checks it against the pool and stores it.
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
        // At most MAX_UNIT_EXP, checked above.
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

    /// @dev Token amounts `units` vault-token units hold at the oracle sqrt price clamped to the range, floored.
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

    /// @dev Reads `slot0()` once, then compares the pool's TWAP tick with the oracle tick; deviation is in ticks.
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
        // The quotes equal the valuation prices unless a stable is above its ceiling; reuse the root then.
        uint160 sQ = quotes[0] == prices[0] && quotes[1] == prices[1] ? sV : _oracleSqrt(quotes);
        p.deviationBps = _tickDistance(meanTick, ClPriceMath.tickAtSqrtRatio(sQ));
        p.pass = p.deviationBps <= toleranceBps;
    }

    /// @dev `PoolTwap` second source: token `index` priced through a deep pool's TWAP and the other token's quote.
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

    function _isOwnPool(
        bytes32 poolRef
    ) internal view virtual override returns (bool own) {
        own = poolRef == bytes32(uint256(uint160(_cl().pool)));
    }

    /// @dev Never runs: listing checks run only delegated. Fails closed if reached.
    function _listingChecks(
        OracleConfig calldata,
        uint256[] memory
    ) internal pure virtual override returns (uint256) {
        return type(uint256).max;
    }

    /// @dev The module's listing checks; returns a bitmap of `CL_CHECK_*` failures.
    function _clListingChecks(
        ClListingInputs memory x,
        uint256[] memory quotes
    ) internal view virtual returns (uint256 failed) {
        ClLayout storage c = _cl();
        if (_rangeFails()) failed |= CL_CHECK_RANGE;
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

    function _rangeFails() internal view virtual returns (bool) {
        ClLayout storage c = _cl();
        (bool okS, int24 spacing) = _tickSpacing(c.pool);
        return !okS || spacing != c.tickSpacing || !ClPriceMath.isUsableRange(c.tickLower, c.tickUpper, spacing);
    }

    /// @dev The integration's unit exponent equals the stored one; a failed read passes only before registration.
    function _unitExpMatches() internal view returns (bool) {
        Layout storage $ = _s();
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            $.integration, CONFIG_CALL_GAS, abi.encodeCall(IClIntegration.unitExponent, ($.marketId)), 32 + 1
        );
        if (!ok) return !_bound();
        return ret.length == 32 && _wordIs(ret, 0, _cl().unitExp);
    }

    /// @dev The integration reports no rate providers; a failed read passes only before registration.
    function _noRateTokens() internal view returns (bool) {
        Layout storage $ = _s();
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            $.integration, CONFIG_CALL_GAS, abi.encodeCall(IAmmIntegrationHooks.rateProviders, ($.marketId)), 4 * 32 + 1
        );
        if (!ok) return !_bound();
        return ret.length == 4 * 32 && _wordIs(ret, 0, 32) && _wordIs(ret, 32, 2) && _wordIs(ret, 64, 0)
            && _wordIs(ret, 96, 0);
    }

    function _wordIs(
        bytes memory ret,
        uint256 offset,
        uint256 value
    ) private pure returns (bool) {
        (bool ok, uint256 word) = LPOracleCalls.wordAt(ret, offset);
        return ok && word == value;
    }

    /// @dev Whether the MarketRegistry has registered this feed, or the read fails.
    function _bound() internal view returns (bool) {
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            _s().marketRegistry, CONFIG_CALL_GAS, abi.encodeCall(IMarketRegistry.marketOfLpOracle, (address(this))), 32
        );
        (bool okW, uint256 id) = LPOracleCalls.wordAt(ret, 0);
        return !ok || !okW || id != 0;
    }

    /// @dev `getClPriceState()` from one evaluation; price fields are 0 when not `priced`.
    function _clReport(
        bool priced,
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceTicks
    ) internal view virtual returns (ClPriceStateView memory r) {
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

    function _oracleSqrt(
        uint256[] memory x
    ) internal view returns (uint160) {
        uint8[] storage decs = _s().tokenDecimals;
        return ClPriceMath.oracleSqrtPrice(x[0], x[1], decs[0], decs[1]);
    }

    /// @dev Whether the oracle sqrt price at `prices` is clamped, by its own bounds or the range.
    function _clampedAt(
        uint256[] memory prices
    ) internal view returns (bool) {
        if (prices.length != 2 || !_pricesOk(prices)) return false;
        return _clampedFrom(_oracleSqrt(prices), prices);
    }

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

    function _tickDistance(
        int24 a,
        int24 b
    ) internal pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        // |d| is at most 2 * MAX_TICK; the sign is tested first.
        // forge-lint: disable-next-line(unsafe-typecast)
        return d < 0 ? uint256(-d) : uint256(d);
    }

    /// @dev Every entry in `[1, MAX_ROUTE_ANSWER]`, the bound under which the sqrt price cannot overflow.
    function _pricesOk(
        uint256[] memory x
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < x.length; ++i) {
            if (x[i] == 0 || x[i] > LPPriceMath.MAX_ROUTE_ANSWER) return false;
        }
        return true;
    }

    /// @dev The raw price ratio stays below `2^128` with the quotes shocked by `LISTING_SHOCK_FACTOR` each way.
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

    /// @dev The deep pool of a `PoolTwap` reference; `paired` when it holds token `index` and the other market token.
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

    /// @dev Uniswap `OracleLibrary.getQuoteAtTick`, rounded down.
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
