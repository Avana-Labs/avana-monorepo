// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {WrapperThenDexRoute} from "../../../src/liquidation/settlement-routes/WrapperThenDexRoute.sol";
import {DexHop, HopKind} from "../../../src/liquidation/settlement-routes/types/DexHop.sol";
import {PegModuleStep} from "../../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {RouteConfig} from "../../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {WrapperStep} from "../../../src/liquidation/settlement-routes/types/WrapperStep.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../AvanaTest.sol";
import {LockMember} from "../mocks/LockMember.sol";
import {PayoutToken} from "../mocks/PayoutToken.sol";
import {
    FeeSwitchToken,
    MockCLPool,
    MockCurvePool,
    MockLegacyCurvePool,
    MockPoolFactory,
    MockRouteCaller
} from "../mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SwapRouteFixture
/// @notice Shared setup of the swap-route suites (2.12): the real Lock with a mock LPVaultSwap (`MockRouteCaller`,
/// a stand-in in these tests) and a `LockMember` AaveAdapter, the tokens of the 2.12 examples as `PayoutToken`s,
/// the chain's pinned pool factories (one `MockPoolFactory` per family; `_clPool` and `_curvePool` register their pools),
/// and builders for route configurations and hops.
/// @dev `usdt` answers no fee-switch probe, so the suites can route it through any pool; `tether` is the USDT stand-in
/// that answers USDT's `basisPointsRate()`, for the transfer-fee rules of REQ-ROUTE-008.
abstract contract SwapRouteFixture is AvanaTest {
    /// @notice Token classes: bit 1 stable, bit 2 correlated, bit 3 volatile.
    uint8 internal constant STABLE = 1 << 1;
    uint8 internal constant CORRELATED = 1 << 2;
    uint8 internal constant VOLATILE = 1 << 3;

    Lock internal lock;
    MockRouteCaller internal swapper;
    LockMember internal adapter;

    PayoutToken internal usdc;
    PayoutToken internal usdt;
    PayoutToken internal weth;
    PayoutToken internal cbeth;
    PayoutToken internal gho;
    PayoutToken internal dai;
    PayoutToken internal usds;
    FeeSwitchToken internal tether;
    MockPoolFactory internal v3Factory;
    MockPoolFactory internal slipFactory;
    MockPoolFactory internal curveFactory;

    function setUp() public virtual {
        swapper = new MockRouteCaller();
        adapter = new LockMember();
        lock = new Lock(address(adapter), address(swapper));
        swapper.setLock(lock);
        adapter.setLock(lock);
        usdc = new PayoutToken("USDC", 6);
        usdt = new PayoutToken("USDT", 6);
        weth = new PayoutToken("WETH", 18);
        cbeth = new PayoutToken("cbETH", 18);
        gho = new PayoutToken("GHO", 18);
        dai = new PayoutToken("DAI", 18);
        usds = new PayoutToken("USDS", 18);
        tether = new FeeSwitchToken("USDT", 6);
        v3Factory = new MockPoolFactory();
        slipFactory = new MockPoolFactory();
        curveFactory = new MockPoolFactory();
    }

    function _config(
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteConfig memory config) {
        config = RouteConfig({
            lpVaultSwap: address(swapper),
            lock: address(lock),
            aaveAdapter: address(adapter),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tokenClassMask: STABLE,
            uniswapV3Factory: address(v3Factory),
            slipstreamFactory: address(slipFactory),
            curveFactory: address(curveFactory),
            curveLegacyPools: new address[](0)
        });
    }

    /// @notice A funded concentrated-liquidity pool of `a`/`b` at `num / den` (output per input, in base units).
    function _clPool(
        PayoutToken a,
        PayoutToken b,
        uint256 num,
        uint256 den
    ) internal returns (MockCLPool pool) {
        pool = new MockCLPool(address(a), address(b));
        pool.setRate(num, den);
        a.mint(address(pool), 1e40);
        b.mint(address(pool), 1e40);
        v3Factory.register(address(pool));
    }

    /// @notice A funded concentrated-liquidity pool of `a`/`b` registered with the Slipstream factory only.
    function _slipPool(
        PayoutToken a,
        PayoutToken b,
        uint256 num,
        uint256 den
    ) internal returns (MockCLPool pool) {
        pool = new MockCLPool(address(a), address(b));
        pool.setRate(num, den);
        a.mint(address(pool), 1e40);
        b.mint(address(pool), 1e40);
        slipFactory.register(address(pool));
    }

    /// @notice A funded two-coin Curve pool `[a, b]` at `num / den`.
    function _curvePool(
        PayoutToken a,
        PayoutToken b,
        uint256 num,
        uint256 den
    ) internal returns (MockCurvePool pool) {
        address[] memory coins = new address[](2);
        coins[0] = address(a);
        coins[1] = address(b);
        pool = new MockCurvePool(coins);
        pool.setRate(num, den);
        a.mint(address(pool), 1e40);
        b.mint(address(pool), 1e40);
        curveFactory.registerCurve(address(pool), coins);
    }

    /// @notice A funded two-coin legacy Curve pool `[a, b]` at `num / den`; not pinned until a configuration lists it.
    function _legacyPool(
        PayoutToken a,
        PayoutToken b,
        uint256 num,
        uint256 den
    ) internal returns (MockLegacyCurvePool pool) {
        address[] memory coins = new address[](2);
        coins[0] = address(a);
        coins[1] = address(b);
        pool = new MockLegacyCurvePool(coins);
        pool.setRate(num, den);
        a.mint(address(pool), 1e40);
        b.mint(address(pool), 1e40);
    }

    /// @notice `_config(tokenIn, tokenOut)` with `pinned` as the chain's pinned legacy Curve pools.
    function _configPinned(
        address tokenIn,
        address tokenOut,
        address[] memory pinned
    ) internal view returns (RouteConfig memory config) {
        config = _config(tokenIn, tokenOut);
        config.curveLegacyPools = pinned;
    }

    function _legacyHop(
        address pool,
        address tokenOut,
        int128 i,
        int128 j
    ) internal pure returns (DexHop memory hop) {
        hop = DexHop({kind: HopKind.CurveLegacy, pool: pool, tokenOut: tokenOut, i: i, j: j});
    }

    function _clHop(
        address pool,
        address tokenOut
    ) internal pure returns (DexHop memory hop) {
        hop = DexHop({kind: HopKind.ConcentratedLiquidity, pool: pool, tokenOut: tokenOut, i: 0, j: 0});
    }

    function _curveHop(
        address pool,
        address tokenOut,
        int128 i,
        int128 j
    ) internal pure returns (DexHop memory hop) {
        hop = DexHop({kind: HopKind.CurveStableSwap, pool: pool, tokenOut: tokenOut, i: i, j: j});
    }

    function _hops1(
        DexHop memory a
    ) internal pure returns (DexHop[] memory hops) {
        hops = new DexHop[](1);
        hops[0] = a;
    }

    function _hops2(
        DexHop memory a,
        DexHop memory b
    ) internal pure returns (DexHop[] memory hops) {
        hops = new DexHop[](2);
        hops[0] = a;
        hops[1] = b;
    }

    function _hops3(
        DexHop memory a,
        DexHop memory b,
        DexHop memory c
    ) internal pure returns (DexHop[] memory hops) {
        hops = new DexHop[](3);
        hops[0] = a;
        hops[1] = b;
        hops[2] = c;
    }

    /// @notice Deploys a `DexPathRoute` through an external call, so `vm.expectRevert` applies to this call. With
    /// `dynamic_test_linking`, a `new` of a source contract runs as a `deployCode` cheatcode, which `expectRevert` does
    /// not count as the next call: a refused `new` then reverts the whole test, which the pending `expectRevert` accepts,
    /// and every statement after it is skipped.
    function deployDexPath(
        RouteConfig memory config,
        DexHop[] memory hops
    ) external returns (DexPathRoute) {
        return new DexPathRoute(config, hops);
    }

    /// @notice Deploys a `WrapperThenDexRoute` through an external call (see `deployDexPath`).
    function deployWrapperThenDex(
        RouteConfig memory config,
        WrapperStep memory step,
        DexHop[] memory hops
    ) external returns (WrapperThenDexRoute) {
        return new WrapperThenDexRoute(config, step, hops);
    }

    /// @notice Deploys a `PegModuleRoute` through an external call (see `deployDexPath`).
    function deployPegModule(
        RouteConfig memory config,
        PegModuleStep memory step
    ) external returns (PegModuleRoute) {
        return new PegModuleRoute(config, step);
    }

    /// @notice A one-hop USDT → USDC route over a fresh 1:1 concentrated-liquidity pool.
    function _usdtUsdcRoute() internal returns (DexPathRoute route, MockCLPool pool) {
        pool = _clPool(usdt, usdc, 1, 1);
        route = new DexPathRoute(_config(address(usdt), address(usdc)), _hops1(_clHop(address(pool), address(usdc))));
    }

    /// @notice LPVaultSwap's production call: fund the mock caller and swap under the Lock.
    function _swap(
        ISettlementRoute route,
        uint256 amountIn,
        uint256 minOut
    ) internal returns (uint256 out) {
        PayoutToken(route.tokenIn()).mint(address(swapper), amountIn);
        out = swapper.swapUnderLock(route, amountIn, minOut);
    }

    /// @notice The route ends with no allowance to any of `spenders` for any of `tokens`.
    function _assertNoAllowance(
        address route,
        address[] memory tokens,
        address[] memory spenders
    ) internal view {
        for (uint256 t = 0; t < tokens.length; ++t) {
            for (uint256 s = 0; s < spenders.length; ++s) {
                assertEq(IERC20(tokens[t]).allowance(route, spenders[s]), 0, "allowance left");
            }
        }
    }

    function _list2(
        address a,
        address b
    ) internal pure returns (address[] memory list) {
        list = new address[](2);
        list[0] = a;
        list[1] = b;
    }

    function _list3(
        address a,
        address b,
        address c
    ) internal pure returns (address[] memory list) {
        list = new address[](3);
        list[0] = a;
        list[1] = b;
        list[2] = c;
    }
}
