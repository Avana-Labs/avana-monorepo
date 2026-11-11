// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {WrapperThenDexRoute} from "../../src/liquidation/settlement-routes/WrapperThenDexRoute.sol";
import {DexHop} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {WrapperKind, WrapperStep} from "../../src/liquidation/settlement-routes/types/WrapperStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {MockCLPool, MockCurvePool, MockDaiUsds} from "../utils/mocks/SwapRouteMocks.sol";

/// @notice A Curve StableSwap-NG factory stand-in that answers `get_coin_indices` with set values, to show the route
/// compares every word of the answer.
contract SetCurveFactory {
    int128 public i;
    int128 public j;
    bool public underlying;

    function set(
        int128 i_,
        int128 j_,
        bool underlying_
    ) external {
        (i, j, underlying) = (i_, j_, underlying_);
    }

    function get_coin_indices(
        address,
        address,
        address
    ) external view returns (int128, int128, bool) {
        return (i, j, underlying);
    }
}

/// @notice A concentrated-liquidity pool look-alike whose `fee()` does not fit `uint24` and whose `tickSpacing()` is
/// set by the test: the route must not truncate either before asking a factory.
contract WidePool {
    address public immutable token0;
    address public immutable token1;
    uint256 public fee = 1 << 24;
    int256 public tickSpacing = 1;

    constructor(
        address a,
        address b
    ) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setTickSpacing(
        int256 s
    ) external {
        tickSpacing = s;
    }
}

/// @title DexHopsUnitTest
/// @notice The hop machinery shared by `DexPathRoute` and `WrapperThenDexRoute` (`DexHops`): the deployment checks of
/// each hop family (indices, the transfer-fee probe on a concentrated-liquidity input, pool provenance through each
/// pinned factory and its fallback, every word of the Curve factory's answer, a pool repeated across hops), and the
/// swap of each hop kind and direction: Curve forward and reverse and through a three-coin pool, a Slipstream-only
/// pool, a hop whose output is zero ending the path, and `exactAmountInputs` of mixed paths.
contract DexHopsUnitTest is SwapRouteFixture {
    // ─── Concentrated-liquidity hops (REQ-ROUTE-045, REQ-ROUTE-008) ───

    // TEST-054 verifies: REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (a Uniswap v3 or Slipstream hop carries no Curve indices)
    /// @notice A concentrated-liquidity hop with `j = 1`, `i = -1` or both set is refused; with both 0 it is accepted.
    function test_TEST_054_concentratedHopCarriesNoIndices() public {
        MockCLPool pool = _clPool(usdt, usdc, 1, 1);
        DexHop memory hop = _clHop(address(pool), address(usdc));
        hop.j = 1;
        _expectBad(address(usdt), _hops1(hop));
        hop.j = 0;
        hop.i = -1;
        _expectBad(address(usdt), _hops1(hop));
        hop.i = 3;
        hop.j = 3;
        _expectBad(address(usdt), _hops1(hop));
        hop.i = 0;
        hop.j = 0;
        DexPathRoute ok = new DexPathRoute(_config(address(usdt), address(usdc)), _hops1(hop));
        assertEq(ok.exactAmountInputs()[0], address(usdt), "a concentrated-liquidity input pays the exact amount");
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-045, REQ-ROUTE-003
    // Sources: 2.12 REQ-ROUTE-008 example (USDT through a Uniswap v3 pool is refused at deployment, through Curve it is
    // accepted)
    /// @notice A token answering the fee-switch probe is refused as the input of a concentrated-liquidity hop with its
    /// fee off and on, at the first hop and at a later hop; the same token is accepted as a Curve input and as a
    /// concentrated-liquidity output, and a route through Curve swaps it with the fee on.
    function test_TEST_221_feeSwitchTokenNeverPaysAConcentratedPool() public {
        PayoutToken t = PayoutToken(address(tether));
        MockCLPool clIn = _clPool(t, usdc, 1, 1);
        _expectBad(address(tether), _hops1(_clHop(address(clIn), address(usdc))));
        tether.setFeeBps(10);
        _expectBad(address(tether), _hops1(_clHop(address(clIn), address(usdc))));
        // As a later hop's input: DAI → USDT (Curve) → USDC (concentrated).
        MockCurvePool daiTether = _curvePool(dai, t, 1, 1e12);
        _expectBadPath(
            address(dai),
            address(usdc),
            _hops2(_curveHop(address(daiTether), address(tether), 0, 1), _clHop(address(clIn), address(usdc)))
        );
        // Through Curve the token is accepted, and the fee is a cost inside the leg.
        MockCurvePool curveIn = _curvePool(t, usdc, 1, 1);
        DexPathRoute viaCurve = new DexPathRoute(
            _config(address(tether), address(usdc)), _hops1(_curveHop(address(curveIn), address(usdc), 0, 1))
        );
        assertEq(viaCurve.exactAmountInputs().length, 0, "Curve credits what it received");
        tether.mint(address(swapper), 1_000_000);
        uint256 out = swapper.swapUnderLock(viaCurve, 1_000_000, 999_000);
        assertEq(out, 999_000, "the leg swaps the 999,000 units the route received");
        // As a concentrated-liquidity output.
        MockCLPool clOut = _clPool(usdc, t, 1, 1);
        DexPathRoute toTether =
            new DexPathRoute(_config(address(usdc), address(tether)), _hops1(_clHop(address(clOut), address(tether))));
        assertEq(toTether.exactAmountInputs()[0], address(usdc));
    }

    // TEST-054 verifies: REQ-ROUTE-045, Q-379
    // Sources: 2.12 REQ-ROUTE-045 (the pinned factory's getPool must name the pool; a zero factory refuses its family)
    /// @notice A pool with the right tokens that no pinned factory deployed is refused; a pool known only to the
    /// Slipstream factory is accepted with or without a Uniswap v3 factory configured; with both concentrated-liquidity
    /// factories zero every concentrated hop is refused; a pool known only to Uniswap v3 is refused when the route's
    /// Uniswap v3 factory is zero.
    function test_TEST_054_poolProvenanceThroughEachFactory() public {
        MockCLPool lookAlike = new MockCLPool(address(usdt), address(usdc));
        _expectBad(address(usdt), _hops1(_clHop(address(lookAlike), address(usdc))));
        MockCLPool slip = _slipPool(usdt, usdc, 1, 1);
        new DexPathRoute(_config(address(usdt), address(usdc)), _hops1(_clHop(address(slip), address(usdc))));
        RouteConfig memory c = _config(address(usdt), address(usdc));
        c.uniswapV3Factory = address(0);
        new DexPathRoute(c, _hops1(_clHop(address(slip), address(usdc))));
        c.slipstreamFactory = address(0);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(c, _hops1(_clHop(address(slip), address(usdc))));
        MockCLPool uni = _clPool(usdt, usdc, 1, 1);
        c = _config(address(usdt), address(usdc));
        c.uniswapV3Factory = address(0);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(c, _hops1(_clHop(address(uni), address(usdc))));
    }

    // TEST-054 verifies: REQ-ROUTE-045
    /// @notice A pool whose `fee()` does not fit `uint24` is not looked up on the Uniswap v3 factory and is accepted
    /// through the Slipstream factory's tick-spacing key; a tick spacing outside `int24` is refused, never truncated.
    function test_TEST_054_wideFeeAndTickSpacingNotTruncated() public {
        WidePool pool = new WidePool(address(usdt), address(usdc));
        slipFactory.registerSpacing(address(pool), address(usdt), address(usdc), 1);
        new DexPathRoute(_config(address(usdt), address(usdc)), _hops1(_clHop(address(pool), address(usdc))));
        pool.setTickSpacing(int256(type(int24).max) + 1);
        _expectBad(address(usdt), _hops1(_clHop(address(pool), address(usdc))));
        pool.setTickSpacing(int256(type(int24).min) - 1);
        _expectBad(address(usdt), _hops1(_clHop(address(pool), address(usdc))));
    }

    // ─── Curve hops (REQ-ROUTE-045) ───

    // TEST-054 verifies: REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (get_coin_indices returns the hop's i and j with no underlying coin)
    /// @notice A Curve hop is refused with a zero Curve factory, for a pool the factory does not know, when the
    /// factory reports an underlying coin, when it reports other indices than the hop's, and for an index so large
    /// that `coins(i)` reverts.
    function test_TEST_054_curveFactoryAnswerCheckedWordByWord() public {
        MockCurvePool pool = _curvePool(usdt, usdc, 1, 1);
        DexHop[] memory hops = _hops1(_curveHop(address(pool), address(usdc), 0, 1));
        RouteConfig memory c = _config(address(usdt), address(usdc));
        c.curveFactory = address(0);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(c, hops);

        address[] memory coins = new address[](2);
        (coins[0], coins[1]) = (address(usdt), address(usdc));
        MockCurvePool unknown = new MockCurvePool(coins);
        _expectBad(address(usdt), _hops1(_curveHop(address(unknown), address(usdc), 0, 1)));

        SetCurveFactory setFactory = new SetCurveFactory();
        c = _config(address(usdt), address(usdc));
        c.curveFactory = address(setFactory);
        setFactory.set(0, 1, true);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(c, hops);
        setFactory.set(1, 0, false);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(c, hops);
        setFactory.set(0, 2, false);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(c, hops);
        setFactory.set(0, 1, false);
        DexPathRoute ok = new DexPathRoute(c, hops);
        assertEq(ok.dependencies()[0], address(pool));

        _expectBad(address(usdt), _hops1(_curveHop(address(pool), address(usdc), 0, type(int128).max)));
        _expectBad(address(usdt), _hops1(_curveHop(address(pool), address(usdc), type(int128).min, 1)));
    }

    // TEST-054 verifies: REQ-ROUTE-003, REQ-ROUTE-043, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (every pool distinct)
    /// @notice A three-coin Curve pool used for two hops of one path (USDT → DAI → USDC) is refused though every
    /// token is distinct; a hop to its own input and a hop to the zero token are refused.
    function test_TEST_054_poolRepeatedAcrossHopsRefused() public {
        MockCurvePool tri = _curvePool3(usdt, dai, usdc);
        _expectBad(
            address(usdt),
            _hops2(_curveHop(address(tri), address(dai), 0, 1), _curveHop(address(tri), address(usdc), 1, 2))
        );
        MockCLPool usdtUsdc = _clPool(usdt, usdc, 1, 1);
        _expectBad(address(usdt), _hops1(_clHop(address(usdtUsdc), address(usdt))));
        _expectBad(address(usdt), _hops1(_clHop(address(usdtUsdc), address(0))));
        // One hop through the three-coin pool is accepted.
        DexPathRoute ok = new DexPathRoute(
            _config(address(usdt), address(usdc)), _hops1(_curveHop(address(tri), address(usdc), 0, 2))
        );
        assertEq(ok.dependencies().length, 1);
    }

    // TEST-054 verifies: REQ-ROUTE-003, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (TOKEN_IN, every intermediate and TOKEN_OUT are distinct)
    /// @notice A path that returns to its input token through distinct pools (USDT → DAI → USDT → USDC, three different
    /// pools, each hop valid on its own) is refused for the repeated token alone; a wrapper route whose hops lead back
    /// to its input (USDS → DAI → USDS → USDC) is refused the same way; the same tokens without the loop are accepted.
    function test_TEST_054_repeatedTokenThroughDistinctPoolsRefused() public {
        MockCLPool usdtDai = _clPool(usdt, dai, 1e12, 1);
        MockCurvePool daiUsdt = _curvePool(dai, usdt, 1, 1e12);
        MockCLPool usdtUsdc = _clPool(usdt, usdc, 1, 1);
        _expectBad(
            address(usdt),
            _hops3(
                _clHop(address(usdtDai), address(dai)),
                _curveHop(address(daiUsdt), address(usdt), 0, 1),
                _clHop(address(usdtUsdc), address(usdc))
            )
        );
        MockDaiUsds conv = new MockDaiUsds(address(usds), address(dai));
        MockCurvePool daiUsds = _curvePool(dai, usds, 1, 1);
        MockCLPool usdsUsdc = _clPool(usds, usdc, 1, 1e12);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new WrapperThenDexRoute(
            _config(address(usds), address(usdc)),
            WrapperStep(WrapperKind.UsdsToDai, address(conv), address(dai)),
            _hops2(_curveHop(address(daiUsds), address(usds), 0, 1), _clHop(address(usdsUsdc), address(usdc)))
        );
        MockCurvePool daiUsdc = _curvePool(dai, usdc, 1, 1e12);
        DexPathRoute ok = new DexPathRoute(
            _config(address(usdt), address(usdc)),
            _hops2(_clHop(address(usdtDai), address(dai)), _curveHop(address(daiUsdc), address(usdc), 0, 1))
        );
        assertEq(ok.intermediates()[0], address(dai));
    }

    // ─── Swaps of each hop kind (REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-013) ───

    // TEST-054 verifies: REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-016
    // Sources: 2.12 REQ-ROUTE-010 (forceApprove exactly the leg's input, reset after)
    /// @notice A Curve hop runs in either coin order: input at index 1 into index 0, and index 2 into index 0 of a
    /// three-coin pool; each pays LPVaultSwap the pool's output, passes `min_dy = 0` and leaves no allowance.
    function test_TEST_054_curveHopEitherDirectionAndThreeCoins() public {
        MockCurvePool rev = _curvePool(usdc, usdt, 2, 1);
        DexPathRoute r1 = new DexPathRoute(
            _config(address(usdt), address(usdc)), _hops1(_curveHop(address(rev), address(usdc), 1, 0))
        );
        assertEq(_swap(r1, 1_000_000, 2_000_000), 2_000_000, "index 1 into index 0");
        assertEq(rev.lastMinDy(), 0, "hop minimum is 0");
        assertEq(usdt.allowance(address(r1), address(rev)), 0);
        MockCurvePool tri = _curvePool3(usdc, dai, usdt);
        tri.setRate(1, 1);
        DexPathRoute r2 = new DexPathRoute(
            _config(address(usdt), address(usdc)), _hops1(_curveHop(address(tri), address(usdc), 2, 0))
        );
        assertEq(_swap(r2, 3_000_000, 3_000_000), 3_000_000, "index 2 into index 0");
        assertEq(usdt.balanceOf(address(r2)), 0);
        assertEq(usdc.balanceOf(address(r2)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-009, REQ-ROUTE-013, REQ-ROUTE-033
    /// @notice A pool known only to the Slipstream factory swaps through the same callback rules: the pool is paid
    /// exactly its input in the callback and the output reaches LPVaultSwap.
    function test_TEST_054_slipstreamOnlyPoolSwaps() public {
        MockCLPool slip = _slipPool(weth, usdc, 3000e6, 1e18);
        DexPathRoute route =
            new DexPathRoute(_config(address(weth), address(usdc)), _hops1(_clHop(address(slip), address(usdc))));
        uint256 poolWeth = weth.balanceOf(address(slip));
        assertEq(_swap(route, 2e18, 6000e6), 6000e6);
        assertEq(weth.balanceOf(address(slip)) - poolWeth, 2e18, "paid exactly the hop's input");
        assertEq(slip.swaps(), 1);
    }

    // TEST-177 verifies: REQ-ROUTE-009, REQ-ROUTE-015, REQ-ROUTE-044
    // Sources: 2.12 REQ-ROUTE-009 (value lost on a hop lowers the final output, which the final check catches)
    /// @notice A first hop that yields nothing ends the path: the second pool is never called and the call reverts
    /// `MinOutNotMet(0, 1)`; a second hop that yields nothing reverts the same way.
    function test_TEST_177_zeroHopOutputEndsThePath() public {
        MockCLPool p1 = _clPool(cbeth, weth, 1, 1);
        MockCLPool p2 = _clPool(weth, usdc, 3000e6, 1e18);
        DexPathRoute route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _clHop(address(p2), address(usdc)))
        );
        p1.setRate(0, 1);
        cbeth.mint(address(swapper), 2e18);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, 1e18, 1);
        p1.setRate(1, 1);
        p2.setRate(0, 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, 1e18, 1);
        p2.setRate(3000e6, 1e18);
        assertEq(swapper.swapUnderLock(route, 1e18, 3000e6), 3000e6, "the path works once both pools pay");
        assertEq(p2.swaps(), 1, "the reverted calls left no swap");
    }

    // TEST-221 verifies: REQ-ROUTE-008
    // Sources: 2.12 REQ-ROUTE-008 (the route lists its concentrated-liquidity inputs in exactAmountInputs)
    /// @notice `exactAmountInputs` lists the input of each concentrated-liquidity hop in path order and no Curve input:
    /// USDT →(Curve) DAI →(CL) WETH →(CL) USDC lists DAI and WETH; USDT →(CL) DAI →(Curve) USDC lists USDT.
    function test_TEST_221_exactAmountInputsOfMixedPaths() public {
        MockCurvePool c1 = _curvePool(usdt, dai, 1e12, 1);
        MockCLPool p2 = _clPool(dai, weth, 1, 3000);
        MockCLPool p3 = _clPool(weth, usdc, 3000e6, 1e18);
        DexPathRoute a = new DexPathRoute(
            _config(address(usdt), address(usdc)),
            _hops3(
                _curveHop(address(c1), address(dai), 0, 1),
                _clHop(address(p2), address(weth)),
                _clHop(address(p3), address(usdc))
            )
        );
        address[] memory ex = a.exactAmountInputs();
        assertEq(ex.length, 2);
        assertEq(ex[0], address(dai));
        assertEq(ex[1], address(weth));
        MockCLPool q1 = _clPool(usdt, dai, 1e12, 1);
        MockCurvePool q2 = _curvePool(dai, usdc, 1, 1e12);
        DexPathRoute b = new DexPathRoute(
            _config(address(usdt), address(usdc)),
            _hops2(_clHop(address(q1), address(dai)), _curveHop(address(q2), address(usdc), 0, 1))
        );
        ex = b.exactAmountInputs();
        assertEq(ex.length, 1);
        assertEq(ex[0], address(usdt));
        assertEq(_swap(b, 5e6, 5e6), 5e6, "USDT to DAI at 1e12 per unit and back");
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-033
    // Sources: 2.12 REQ-ROUTE-013 (the callback pays at most the hop's amount, once)
    /// @notice Over a random rate and amount the pool is paid exactly the hop's input, once, and the callback context
    /// is cleared: a later direct callback from the same pool reverts `InvalidCallback`.
    function testFuzz_TEST_046_callbackPaysExactlyTheHopInput(
        uint256 amountIn,
        uint256 num
    ) public {
        amountIn = bound(amountIn, 1, 1e24);
        num = bound(num, 1, 1e6);
        MockCLPool pool = _clPool(weth, usdc, num, 1);
        DexPathRoute route =
            new DexPathRoute(_config(address(weth), address(usdc)), _hops1(_clHop(address(pool), address(usdc))));
        uint256 poolWeth = weth.balanceOf(address(pool));
        uint256 out = _swap(route, amountIn, 1);
        assertEq(out, amountIn * num, "output at the pool's rate");
        assertEq(weth.balanceOf(address(pool)) - poolWeth, amountIn, "paid exactly the input");
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        pool.poke(address(route), int256(1), int256(-1));
    }

    // ─── Helpers ───

    function _expectBad(
        address tokenIn,
        DexHop[] memory hops
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(_config(tokenIn, address(usdc)), hops);
    }

    function _expectBadPath(
        address tokenIn,
        address tokenOut,
        DexHop[] memory hops
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new DexPathRoute(_config(tokenIn, tokenOut), hops);
    }

    /// @notice A funded three-coin Curve pool `[a, b, c]` at 1:1.
    function _curvePool3(
        PayoutToken a,
        PayoutToken b,
        PayoutToken c
    ) internal returns (MockCurvePool pool) {
        address[] memory coins = new address[](3);
        (coins[0], coins[1], coins[2]) = (address(a), address(b), address(c));
        pool = new MockCurvePool(coins);
        a.mint(address(pool), 1e40);
        b.mint(address(pool), 1e40);
        c.mint(address(pool), 1e40);
        curveFactory.registerCurve(address(pool), coins);
    }
}
