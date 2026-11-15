// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../amm/concentrated-liquidity/ClPriceMath.sol";
import {ClUnitMath} from "../../amm/concentrated-liquidity/ClUnitMath.sol";
import {IUniswapV4Integration} from "../../amm/uniswap-v4/IUniswapV4Integration.sol";
import {UniswapV4State} from "../../amm/uniswap-v4/UniswapV4State.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleCalls} from "./LPOracleCalls.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";

/// @title LPOracleV4Module
/// @notice The Uniswap v4 pricing module of the LPOracle: the concentrated-liquidity module with the v4 market, read
/// guard and consistency check. Composition is the same as Uniswap v3, at the oracle square-root price clamped to the
/// range (`SPEC-AMM-V4-001`). The pool hook reads the PoolManager's lock through `exttload` (`REQ-AMM-V4-003`) and its
/// `slot0` through `extsload`, and the consistency check is the larger of the spot gate and the reference Uniswap v3
/// pool's TWAP deviation (`REQ-AMM-V4-005`, `SPEC-AMM-V4-002`). The per-block quote-change cap is the core's
/// (`REQ-AMM-CORE-014`); uncollected fees never enter the price.
/// @dev The concentrated-liquidity layout keeps the range, spacing, square-root bounds and unit exponent; its `pool`
/// is the reference pool, so the inherited cardinality, `observe`, listing and report reads go to it. The v4 pool lives
/// in the ERC-7201 namespace `avana.storage.LPOracleV4`. Every PoolManager read is a gas-guarded static call
/// (`SPEC-ORC-023`) whose short or failed answer is a failed read, never a revert.
/// @custom:spec REQ-AMM-V4-003, REQ-AMM-V4-005, REQ-AMM-V4-007, SPEC-AMM-V4-001, SPEC-AMM-V4-002, REQ-ORACLE-103, REQ-ORACLE-104, REQ-ORACLE-105
abstract contract LPOracleV4Module is LPOracleCLModule {
    /// @notice The v4 pool of the market.
    /// @custom:storage-location erc7201:avana.storage.LPOracleV4
    struct V4Layout {
        address poolManager;
        bytes32 poolId;
        // The reference pool orders the two tokens the other way from the v4 pool.
        bool referenceReversed;
    }

    /// @notice Listing bit: the v4 pool is unreadable or uninitialized.
    uint256 internal constant V4_CHECK_POOL = 1 << 8;
    /// @notice Listing bit: the integration's reference pool of the market is not the module's (`REQ-AMM-V4-007`).
    uint256 internal constant V4_CHECK_REFERENCE = 1 << 9;

    /// @dev keccak256(abi.encode(uint256(keccak256("avana.storage.LPOracleV4")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 private constant _V4_SLOT = 0xe8667b9ac72eb16e19c1ef126cfd84d293b85d6b77c13d77a23b929b113ec400;
    /// @dev Bytes of the market encoding: `abi.encode(poolManager, key, tickLower, tickUpper, unitExp, referencePool)`.
    uint256 private constant _MARKET_LENGTH = 10 * 32;
    /// @dev Largest tick spacing of a v4 pool.
    int256 private constant _MAX_SPACING = type(int16).max;

    /// @dev The chain's wrapped native token, which stands for a native-ETH `currency0`.
    address internal immutable _WRAPPED_NATIVE;

    /// @notice Fixes the wrapped native token; reverts `MarketMismatch(0)` for address(0).
    constructor(
        address wrappedNative
    ) {
        if (wrappedNative == address(0)) revert MarketMismatch(0);
        _WRAPPED_NATIVE = wrappedNative;
    }

    /// @notice The wrapped native token a native-ETH leg is priced as.
    function WRAPPED_NATIVE() external view returns (address weth) {
        weth = _WRAPPED_NATIVE;
    }

    function _v4() internal pure returns (V4Layout storage v) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            v.slot := _V4_SLOT
        }
    }

    // ─── Market (REQ-ORACLE-058) ───

    /// @dev `market = abi.encode(poolManager, UniswapV4PoolKey key, tickLower, tickUpper, unitExp, referencePool)`. The
    /// key must be hookless, its currencies the market's tokens (native ETH as `WRAPPED_NATIVE`), the pool initialized,
    /// the range usable at its spacing, and the reference pool must pair the two tokens in either order. Every word is
    /// range-checked, so a malformed encoding returns false and never reverts.
    /// @custom:spec REQ-ORACLE-058, REQ-AMM-V4-001, REQ-AMM-V4-007
    function _initMarket(
        bytes calldata market,
        address[] memory tokens
    ) internal virtual override returns (bool ok) {
        if (market.length != _MARKET_LENGTH || tokens.length != 2) return false;
        uint8[] storage decs = _s().tokenDecimals;
        if (decs[0] > CL_MAX_TOKEN_DECIMALS || decs[1] > CL_MAX_TOKEN_DECIMALS) return false;
        MarketWords memory w;
        if (!_parse(market, tokens, w)) return false;
        bool same;
        (ok, same) = _pairs(w.ref, tokens);
        if (!ok) return false;
        V4Layout storage v = _v4();
        (v.poolManager, v.poolId, v.referenceReversed) = (w.manager, keccak256(market[32:192]), !same);
        (bool okP, uint160 sqrtPriceX96,) = _pmSlot0();
        if (!okP || sqrtPriceX96 == 0) return false;
        ClLayout storage c = _cl();
        (c.pool, c.tickLower, c.tickUpper, c.tickSpacing) = (w.ref, w.lower, w.upper, w.spacing);
        (c.sqrtLower, c.sqrtUpper) = (ClPriceMath.sqrtRatioAtTick(w.lower), ClPriceMath.sqrtRatioAtTick(w.upper));
        c.unitExp = w.unitExp;
    }

    /// @dev The checked words of a v4 market encoding.
    struct MarketWords {
        address manager;
        address ref;
        int24 spacing;
        int24 lower;
        int24 upper;
        uint8 unitExp;
    }

    /// @dev Reads and range-checks every word of `market` into `w` (`_parseAddresses`, `_parseTicks`).
    function _parse(
        bytes calldata market,
        address[] memory tokens,
        MarketWords memory w
    ) private view returns (bool) {
        return _parseAddresses(market, tokens, w) && _parseTicks(market, w);
    }

    /// @dev Addresses within 160 bits, no hook, code at the PoolManager and the reference pool, and currencies equal to
    /// `tokens` (native ETH as `WRAPPED_NATIVE`).
    function _parseAddresses(
        bytes calldata market,
        address[] memory tokens,
        MarketWords memory w
    ) private view returns (bool) {
        bool okA;
        bool okR;
        (okA, w.manager) = _addr(market, 0);
        (okR, w.ref) = _addr(market, 9);
        (bool ok0, address c0) = _addr(market, 1);
        (bool ok1, address c1) = _addr(market, 2);
        (bool okH, address hooks) = _addr(market, 5);
        if (!okA || !okR || !ok0 || !ok1 || !okH || hooks != address(0)) return false;
        if (w.manager.code.length == 0 || w.ref.code.length == 0) return false;
        return (c0 == address(0) ? _WRAPPED_NATIVE : c0) == tokens[0] && c1 == tokens[1];
    }

    /// @dev Fee within 24 bits, ticks and spacing within `int24`, spacing in `[1, 32767]`, `unitExp <= MAX_UNIT_EXP`
    /// and the range usable at the spacing.
    function _parseTicks(
        bytes calldata market,
        MarketWords memory w
    ) private pure returns (bool) {
        if (uint256(bytes32(market[96:128])) > type(uint24).max) return false;
        bool okS;
        bool okL;
        bool okU;
        (okS, w.spacing) = _int24(market, 4);
        (okL, w.lower) = _int24(market, 6);
        (okU, w.upper) = _int24(market, 7);
        uint256 unitExp = uint256(bytes32(market[256:288]));
        if (!okS || !okL || !okU || w.spacing < 1 || w.spacing > _MAX_SPACING || unitExp > ClUnitMath.MAX_UNIT_EXP) {
            return false;
        }
        // At most MAX_UNIT_EXP = 18, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        w.unitExp = uint8(unitExp);
        return ClPriceMath.isUsableRange(w.lower, w.upper, w.spacing);
    }

    /// @dev Whether the reference pool's `token0`/`token1` are the market's two tokens; `same` when in the same order.
    function _pairs(
        address ref,
        address[] memory tokens
    ) private view returns (bool ok, bool same) {
        (bool okT0, address r0) = _poolAddress(ref, abi.encodeCall(IUniswapV3Pool.token0, ()), CONFIG_CALL_GAS);
        (bool okT1, address r1) = _poolAddress(ref, abi.encodeCall(IUniswapV3Pool.token1, ()), CONFIG_CALL_GAS);
        same = r0 == tokens[0] && r1 == tokens[1];
        ok = okT0 && okT1 && (same || (r0 == tokens[1] && r1 == tokens[0]));
    }

    // ─── Pricing hooks ───

    /// @dev `REQ-AMM-V4-003`: `locked` while the PoolManager is unlocked; `readOk` false for a failed `exttload` or
    /// `extsload`, or an uninitialized pool. Then `SPEC-AMM-V4-002` on the uncapped quotes: unavailable for a zero
    /// window, a reference cardinality below `SPEC-ORC-022`, a failed `observe` or a quote outside
    /// `[1, MAX_ROUTE_ANSWER]`.
    /// @custom:spec REQ-AMM-V4-003, REQ-AMM-V4-005, SPEC-AMM-V4-002, SPEC-ORC-022, REQ-ORACLE-104
    function _poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) internal view virtual override returns (PoolCheck memory p) {
        (bool okL, bool unlocked) = _pmUnlocked();
        (bool okS, uint160 sqrtPriceX96, int24 spot) = _pmSlot0();
        p.readOk = okL && okS && sqrtPriceX96 != 0;
        p.locked = p.readOk && unlocked;
        if (!p.readOk || p.locked || prices.length != 2 || !_pricesOk(prices)) return p;
        uint160 sV = _oracleSqrt(prices);
        p.clamped = _clampedFrom(sV, prices);
        if (quotes.length != 2 || !_pricesOk(quotes)) return p;
        int24 twap;
        (p.available, twap) = _referenceTick(window);
        if (!p.available) return p;
        uint160 sQ = quotes[0] == prices[0] && quotes[1] == prices[1] ? sV : _oracleSqrt(quotes);
        int24 tickRef = ClPriceMath.tickAtSqrtRatio(sQ);
        uint256 a = _tickDistance(spot, tickRef);
        uint256 b = _tickDistance(twap, tickRef);
        p.deviationBps = a > b ? a : b;
        p.pass = p.deviationBps <= toleranceBps;
    }

    /// @dev True when `poolRef` is the market's `PoolId` (`REQ-ORACLE-100`); a `PoolTwap` source naming the reference
    /// pool is allowed.
    function _isOwnPool(
        bytes32 poolRef
    ) internal view virtual override returns (bool own) {
        own = poolRef == _v4().poolId;
    }

    /// @dev The range is checked at the v4 pool's spacing fixed by its key.
    function _rangeFails() internal view virtual override returns (bool) {
        ClLayout storage c = _cl();
        return !ClPriceMath.isUsableRange(c.tickLower, c.tickUpper, c.tickSpacing);
    }

    /// @dev The concentrated-liquidity checks on the reference pool, plus `V4_CHECK_POOL` and `V4_CHECK_REFERENCE`.
    /// @custom:spec REQ-ORACLE-105, REQ-AMM-V4-007
    function _clListingChecks(
        ClListingInputs memory x,
        uint256[] memory quotes
    ) internal view virtual override returns (uint256 failed) {
        failed = super._clListingChecks(x, quotes);
        (bool okP, uint160 sqrtPriceX96,) = _pmSlot0();
        if (!okP || sqrtPriceX96 == 0) failed |= V4_CHECK_POOL;
        if (!_referenceMatches()) failed |= V4_CHECK_REFERENCE;
    }

    /// @dev The report of `getClPriceState()` with the reference pool's mean tick in the v4 pool's token order and the
    /// deviation of `SPEC-AMM-V4-002`.
    /// @custom:spec REQ-ORACLE-104, SPEC-AMM-V4-002
    function _clReport(
        bool priced,
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceTicks
    ) internal view virtual override returns (ClPriceStateView memory r) {
        r = super._clReport(priced, quotes, prices, window, toleranceTicks);
        (bool ok, int24 twap) = _referenceTick(window);
        if (!priced || !ok || quotes.length != 2 || !_pricesOk(quotes)) return r;
        r.meanTick = twap;
        r.tickRef = ClPriceMath.tickAtSqrtRatio(_oracleSqrt(quotes));
        (bool okS,, int24 spot) = _pmSlot0();
        uint256 a = okS ? _tickDistance(spot, r.tickRef) : 0;
        uint256 b = _tickDistance(twap, r.tickRef);
        // The distance of two ticks in [MIN_TICK, MAX_TICK] is below 2^21.
        // forge-lint: disable-next-line(unsafe-typecast)
        r.tickDeviation = uint24(a > b ? a : b);
    }

    // ─── Internal ───

    /// @dev The reference pool's mean tick over `window`, in the v4 pool's token order; false for a zero window, a
    /// cardinality below `SPEC-ORC-022` or a failed read.
    function _referenceTick(
        uint32 window
    ) internal view returns (bool ok, int24 tick) {
        address ref = _cl().pool;
        (bool okC, uint16 cardinality,) = _slot0(ref);
        if (!okC || cardinality < LPPriceMath.minObservations(window, _CHAIN_BLOCK_TIME)) return (false, 0);
        (ok, tick) = _meanTick(ref, window);
        if (ok && _v4().referenceReversed) tick = -tick;
    }

    /// @dev `IUniswapV4Integration.v4Market(marketId).referencePool` is this module's reference pool. Before the
    /// integration binds the market the read reverts and is not counted.
    function _referenceMatches() internal view returns (bool) {
        Layout storage $ = _s();
        (bool ok, bytes memory ret) = LPOracleCalls.staticRead(
            $.integration, CONFIG_CALL_GAS, abi.encodeCall(IUniswapV4Integration.v4Market, ($.marketId)), 6 * 32 + 1
        );
        if (!ok) return !_bound();
        (bool okW, uint256 word) = LPOracleCalls.wordAt(ret, 5 * 32);
        return ret.length == 6 * 32 && okW && word == uint256(uint160(_cl().pool));
    }

    /// @dev The PoolManager's `IS_UNLOCKED` transient slot through `exttload`.
    function _pmUnlocked() internal view returns (bool ok, bool unlocked) {
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            _v4().poolManager,
            POOL_CALL_GAS,
            abi.encodeWithSignature("exttload(bytes32)", UniswapV4State.IS_UNLOCKED_SLOT),
            33
        );
        uint256 word;
        if (ok && ret.length == 32) (ok, word) = LPOracleCalls.wordAt(ret, 0);
        else ok = false;
        unlocked = word != 0;
    }

    /// @dev The pool's `slot0` through `extsload`: square-root price and tick.
    function _pmSlot0() internal view returns (bool ok, uint160 sqrtPriceX96, int24 tick) {
        V4Layout storage v = _v4();
        bytes memory ret;
        (ok, ret) = LPOracleCalls.staticRead(
            v.poolManager,
            POOL_CALL_GAS,
            abi.encodeWithSignature("extsload(bytes32)", UniswapV4State.poolStateSlot(v.poolId)),
            33
        );
        uint256 word;
        if (ok && ret.length == 32) (ok, word) = LPOracleCalls.wordAt(ret, 0);
        else ok = false;
        // Low 160 bits, then the 24-bit two's-complement tick.
        // forge-lint: disable-next-line(unsafe-typecast)
        (sqrtPriceX96, tick) = (uint160(word), int24(int256(word >> 160)));
    }

    /// @dev Word `i` of `market` as an address, `ok` false above 160 bits.
    function _addr(
        bytes calldata market,
        uint256 i
    ) private pure returns (bool ok, address a) {
        uint256 w = uint256(bytes32(market[i * 32:i * 32 + 32]));
        ok = w <= type(uint160).max;
        // Checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        a = address(uint160(w));
    }

    /// @dev Word `i` of `market` as an `int24`, `ok` false outside its range.
    function _int24(
        bytes calldata market,
        uint256 i
    ) private pure returns (bool ok, int24 v) {
        // Two's-complement reinterpretation of an ABI word, range-checked below.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 w = int256(uint256(bytes32(market[i * 32:i * 32 + 32])));
        ok = w >= type(int24).min && w <= type(int24).max;
        // Checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        v = int24(w);
    }
}
