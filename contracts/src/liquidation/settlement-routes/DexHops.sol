// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICLFactory} from "../../interfaces/external/aerodrome/ICLFactory.sol";
import {ICLPool} from "../../interfaces/external/aerodrome/ICLPool.sol";
import {ICurveLegacyPool} from "../../interfaces/external/curve/ICurveLegacyPool.sol";
import {ICurveStableSwapNG} from "../../interfaces/external/curve/ICurveStableSwapNG.sol";
import {ICurveStableSwapNGFactory} from "../../interfaces/external/curve/ICurveStableSwapNGFactory.sol";
import {IUniswapV3Factory} from "../../interfaces/external/uniswap/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../../interfaces/external/uniswap/IUniswapV3Pool.sol";
import {ISettlementRoute} from "./ISettlementRoute.sol";
import {RouteReads} from "./RouteReads.sol";
import {SwapRouteBase} from "./SwapRouteBase.sol";
import {DexHop, HopKind} from "./types/DexHop.sol";
import {RouteConfig} from "./types/RouteConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DexHops
/// @notice Up to three fixed DEX hops of a swap route, each on the whole output of the one before.
/// @dev Hops run with no minimum; the route's single `minOut` check after the last leg covers every hop.
abstract contract DexHops is SwapRouteBase {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.AddressSlot;
    using TransientSlot for TransientSlot.BooleanSlot;
    using TransientSlot for TransientSlot.Uint256Slot;

    uint256 internal constant MAX_HOPS = 3;

    /// @notice Largest pinned list of legacy Curve pools a route accepts, so the constructor's search is bounded.
    uint256 internal constant MAX_CURVE_LEGACY_POOLS = 8;

    /// @dev Uniswap v3 `TickMath.MIN_SQRT_RATIO + 1` and `MAX_SQRT_RATIO - 1`, the extreme price limits.
    uint160 internal constant MIN_PRICE_LIMIT = 4_295_128_740;
    uint160 internal constant MAX_PRICE_LIMIT = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    /// @dev ERC-7201 transient base of the hop context: pool, input token, amount, direction.
    bytes32 private constant HOP_SLOT = 0x6d865b2c93e82c265bb1e2539020efdd77dadf34ac4a83a57dc0c79bbeeacf00;
    bytes32 private constant HOP_POOL_SLOT = HOP_SLOT;
    bytes32 private constant HOP_TOKEN_SLOT = bytes32(uint256(HOP_SLOT) + 1);
    bytes32 private constant HOP_AMOUNT_SLOT = bytes32(uint256(HOP_SLOT) + 2);
    bytes32 private constant HOP_ZERO_FOR_ONE_SLOT = bytes32(uint256(HOP_SLOT) + 3);

    address internal immutable _PATH_START;

    /// @dev Number of hops; 0 only for a `WrapperThenDex` whose wrapper yields the debt asset.
    uint256 internal immutable _HOP_COUNT;

    HopKind private immutable _KIND0;
    HopKind private immutable _KIND1;
    HopKind private immutable _KIND2;
    address private immutable _POOL0;
    address private immutable _POOL1;
    address private immutable _POOL2;
    address private immutable _OUT0;
    address private immutable _OUT1;
    address private immutable _OUT2;
    int128 private immutable _I0;
    int128 private immutable _I1;
    int128 private immutable _I2;
    int128 private immutable _J0;
    int128 private immutable _J1;
    int128 private immutable _J2;
    /// @dev Swap direction of a concentrated-liquidity hop.
    bool private immutable _ZFO0;
    bool private immutable _ZFO1;
    bool private immutable _ZFO2;

    /// @notice Checks the hops against their pools and fixes them.
    constructor(
        RouteConfig memory config,
        address pathStart,
        DexHop[] memory hops
    ) SwapRouteBase(config) {
        uint256 n = hops.length;
        if (n > MAX_HOPS || pathStart == address(0) || config.curveLegacyPools.length > MAX_CURVE_LEGACY_POOLS) {
            revert InvalidRouteConfig();
        }
        if ((n == 0 ? pathStart : hops[n - 1].tokenOut) != config.tokenOut) revert InvalidRouteConfig();
        bool[3] memory zfo = [false, false, false];
        bool valid = true;
        address input = pathStart;
        // The first failed hop ends the loop, so no pool after it is called; the revert follows the loop.
        for (uint256 k = 0; k < n && valid; ++k) {
            (valid, zfo[k]) = _checkHop(config, hops[k], input);
            input = hops[k].tokenOut;
        }
        if (!valid) revert InvalidRouteConfig();
        _checkDistinct(config.tokenIn, pathStart, hops);

        _PATH_START = pathStart;
        _HOP_COUNT = n;
        DexHop memory h0 = n > 0 ? hops[0] : _emptyHop();
        DexHop memory h1 = n > 1 ? hops[1] : _emptyHop();
        DexHop memory h2 = n > 2 ? hops[2] : _emptyHop();
        (_KIND0, _POOL0, _OUT0, _I0, _J0, _ZFO0) = (h0.kind, h0.pool, h0.tokenOut, h0.i, h0.j, zfo[0]);
        (_KIND1, _POOL1, _OUT1, _I1, _J1, _ZFO1) = (h1.kind, h1.pool, h1.tokenOut, h1.i, h1.j, zfo[1]);
        (_KIND2, _POOL2, _OUT2, _I2, _J2, _ZFO2) = (h2.kind, h2.pool, h2.tokenOut, h2.i, h2.j, zfo[2]);
    }

    /// @inheritdoc ISettlementRoute
    /// @dev Pays the hop's pool once, at most the hop's amount, in the hop's input token.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata
    ) external override {
        address pool = HOP_POOL_SLOT.asAddress().tload();
        if (pool == address(0) || msg.sender != pool) revert InvalidCallback();
        int256 owed = HOP_ZERO_FOR_ONE_SLOT.asBoolean().tload() ? amount0Delta : amount1Delta;
        if (owed <= 0) revert InvalidCallback();
        uint256 pay = SafeCast.toUint256(owed);
        if (pay > HOP_AMOUNT_SLOT.asUint256().tload()) revert InvalidCallback();
        // One payment per hop: a second callback in the same hop finds no pool.
        HOP_POOL_SLOT.asAddress().tstore(address(0));
        IERC20(HOP_TOKEN_SLOT.asAddress().tload()).safeTransfer(pool, pay);
    }

    /// @dev Stops early when a hop yields nothing; the final check then reverts `MinOutNotMet`.
    function _runHops(
        uint256 amount
    ) internal {
        address input = _PATH_START;
        for (uint256 k = 0; k < _HOP_COUNT && amount != 0; ++k) {
            DexHop memory hop = _hop(k);
            uint256 before = _balance(hop.tokenOut);
            if (hop.kind == HopKind.ConcentratedLiquidity) {
                _concentratedHop(hop.pool, input, amount, _zeroForOne(k));
            } else {
                _approve(input, hop.pool, amount);
                if (hop.kind == HopKind.CurveStableSwap) {
                    // The output is measured as the balance rise below, not taken from the return value.
                    // forge-lint: disable-next-line(unused-return, calls-loop)
                    ICurveStableSwapNG(hop.pool).exchange(hop.i, hop.j, amount, 0);
                } else {
                    // Declared with no return value, so legacy pools that return nothing also succeed.
                    // forge-lint: disable-next-line(calls-loop)
                    ICurveLegacyPool(hop.pool).exchange(hop.i, hop.j, amount, 0);
                }
                _approve(input, hop.pool, 0);
            }
            amount = _rise(hop.tokenOut, before);
            input = hop.tokenOut;
        }
    }

    /// @inheritdoc ISettlementRoute
    function exactAmountInputs() external view override returns (address[] memory tokens) {
        uint256 count = 0;
        address[MAX_HOPS] memory found = [address(0), address(0), address(0)];
        address input = _PATH_START;
        for (uint256 k = 0; k < _HOP_COUNT; ++k) {
            DexHop memory hop = _hop(k);
            if (hop.kind == HopKind.ConcentratedLiquidity) found[count++] = input;
            input = hop.tokenOut;
        }
        tokens = new address[](count);
        for (uint256 k = 0; k < count; ++k) {
            tokens[k] = found[k];
        }
    }

    /// @notice Every pool of the path, in hop order.
    function _hopPools() internal view returns (address[] memory pools) {
        pools = new address[](_HOP_COUNT);
        for (uint256 k = 0; k < _HOP_COUNT; ++k) {
            pools[k] = _hop(k).pool;
        }
    }

    function _hopIntermediates() internal view returns (address[] memory tokens) {
        uint256 n = _HOP_COUNT == 0 ? 0 : _HOP_COUNT - 1;
        tokens = new address[](n);
        for (uint256 k = 0; k < n; ++k) {
            tokens[k] = _hop(k).tokenOut;
        }
    }

    function _concentratedHop(
        address pool,
        address input,
        uint256 amount,
        bool zeroForOne
    ) private {
        HOP_POOL_SLOT.asAddress().tstore(pool);
        HOP_TOKEN_SLOT.asAddress().tstore(input);
        HOP_AMOUNT_SLOT.asUint256().tstore(amount);
        HOP_ZERO_FOR_ONE_SLOT.asBoolean().tstore(zeroForOne);
        int256 amountSpecified = SafeCast.toInt256(amount);
        uint160 limit = zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        // The callback bounds the payment and the output is measured as a balance rise.
        // forge-lint: disable-next-line(unused-return, calls-loop)
        IUniswapV3Pool(pool).swap(address(this), zeroForOne, amountSpecified, limit, "");
        HOP_POOL_SLOT.asAddress().tstore(address(0));
        HOP_TOKEN_SLOT.asAddress().tstore(address(0));
        HOP_AMOUNT_SLOT.asUint256().tstore(0);
        HOP_ZERO_FOR_ONE_SLOT.asBoolean().tstore(false);
    }

    function _hop(
        uint256 k
    ) private view returns (DexHop memory hop) {
        if (k == 0) return DexHop({kind: _KIND0, pool: _POOL0, tokenOut: _OUT0, i: _I0, j: _J0});
        if (k == 1) return DexHop({kind: _KIND1, pool: _POOL1, tokenOut: _OUT1, i: _I1, j: _J1});
        return DexHop({kind: _KIND2, pool: _POOL2, tokenOut: _OUT2, i: _I2, j: _J2});
    }

    function _zeroForOne(
        uint256 k
    ) private view returns (bool) {
        if (k == 0) return _ZFO0;
        if (k == 1) return _ZFO1;
        return _ZFO2;
    }

    function _checkHop(
        RouteConfig memory config,
        DexHop memory hop,
        address input
    ) private view returns (bool ok, bool zeroForOne) {
        if (hop.pool == address(0) || hop.tokenOut == address(0) || hop.tokenOut == input) return (false, false);
        if (hop.kind == HopKind.ConcentratedLiquidity) {
            if (hop.i != 0 || hop.j != 0) return (false, false);
            // The pool checks its balance after the callback, so a fee on the input would revert every hop.
            if (RouteReads.hasFeeSwitch(input)) return (false, false);
            (bool ok0, address token0) = RouteReads.addressOf(hop.pool, abi.encodeCall(IUniswapV3Pool.token0, ()));
            (bool ok1, address token1) = RouteReads.addressOf(hop.pool, abi.encodeCall(IUniswapV3Pool.token1, ()));
            if (!ok0 || !ok1) return (false, false);
            zeroForOne = token0 == input;
            ok = (zeroForOne ? token1 == hop.tokenOut : (token1 == input && token0 == hop.tokenOut))
                && _fromPinnedFactory(config, hop.pool, token0, token1);
        } else {
            ok = _checkCurveHop(config, hop, input);
        }
    }

    /// @notice Checks a Curve hop; provenance is checked first, so a pool of unknown provenance is never called.
    function _checkCurveHop(
        RouteConfig memory config,
        DexHop memory hop,
        address input
    ) private view returns (bool) {
        if (hop.i < 0 || hop.j < 0 || hop.i == hop.j) return false;
        bool legacy = hop.kind == HopKind.CurveLegacy;
        if (legacy ? !_pinnedLegacy(config.curveLegacyPools, hop.pool) : config.curveFactory == address(0)) {
            return false;
        }
        uint256 i = SafeCast.toUint256(hop.i);
        uint256 j = SafeCast.toUint256(hop.j);
        // `coins(uint256)` has the same selector on StableSwap-NG and legacy pools.
        (bool okIn, address coinIn) = RouteReads.addressOf(hop.pool, abi.encodeCall(ICurveStableSwapNG.coins, (i)));
        (bool okOut, address coinOut) = RouteReads.addressOf(hop.pool, abi.encodeCall(ICurveStableSwapNG.coins, (j)));
        if (!okIn || !okOut || coinIn != input || coinOut != hop.tokenOut) return false;
        if (legacy) return true;
        (bool okIdx, uint256[3] memory w) = RouteReads.words(
            config.curveFactory,
            abi.encodeCall(ICurveStableSwapNGFactory.get_coin_indices, (hop.pool, input, hop.tokenOut)),
            true
        );
        return okIdx && w[0] == i && w[1] == j && w[2] == 0;
    }

    function _pinnedLegacy(
        address[] memory pinned,
        address pool
    ) private pure returns (bool) {
        for (uint256 k = 0; k < pinned.length; ++k) {
            if (pinned[k] == pool) return true;
        }
        return false;
    }

    function _fromPinnedFactory(
        RouteConfig memory config,
        address pool,
        address token0,
        address token1
    ) private view returns (bool) {
        if (config.uniswapV3Factory != address(0)) {
            (bool okFee, uint256[3] memory fee) = RouteReads.words(pool, abi.encodeCall(IUniswapV3Pool.fee, ()), false);
            if (okFee && fee[0] <= type(uint24).max) {
                (bool okPool, address listed) = RouteReads.addressOf(
                    config.uniswapV3Factory,
                    abi.encodeCall(IUniswapV3Factory.getPool, (token0, token1, SafeCast.toUint24(fee[0])))
                );
                if (okPool && listed == pool) return true;
            }
        }
        if (config.slipstreamFactory != address(0)) {
            (bool okSpacing, uint256[3] memory spacing) =
                RouteReads.words(pool, abi.encodeCall(ICLPool.tickSpacing, ()), false);
            // The word of an int24 return is sign-extended; reading it as int256 restores the value.
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 s = int256(spacing[0]);
            if (okSpacing && s >= type(int24).min && s <= type(int24).max) {
                (bool okPool, address listed) = RouteReads.addressOf(
                    config.slipstreamFactory, abi.encodeCall(ICLFactory.getPool, (token0, token1, SafeCast.toInt24(s)))
                );
                if (okPool && listed == pool) return true;
            }
        }
        return false;
    }

    function _checkDistinct(
        address tokenIn_,
        address pathStart,
        DexHop[] memory hops
    ) private pure {
        uint256 n = hops.length;
        address[] memory tokens = new address[](n + 2);
        uint256 t = 0;
        tokens[t++] = tokenIn_;
        if (pathStart != tokenIn_) tokens[t++] = pathStart;
        for (uint256 k = 0; k < n; ++k) {
            tokens[t++] = hops[k].tokenOut;
        }
        bool clash = false;
        for (uint256 a = 0; a < t; ++a) {
            for (uint256 b = a + 1; b < t; ++b) {
                clash = clash || tokens[a] == tokens[b];
            }
            for (uint256 k = 0; k < n; ++k) {
                clash = clash || hops[k].pool == tokens[a];
            }
        }
        for (uint256 k = 0; k < n; ++k) {
            for (uint256 m = k + 1; m < n; ++m) {
                clash = clash || hops[k].pool == hops[m].pool;
            }
        }
        if (clash) revert InvalidRouteConfig();
    }

    function _emptyHop() private pure returns (DexHop memory hop) {
        hop = DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(0), tokenOut: address(0), i: 0, j: 0});
    }
}
