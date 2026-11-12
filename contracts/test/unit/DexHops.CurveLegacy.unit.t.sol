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
import {MockCLPool, MockCurvePool, MockLegacyCurvePool, MockVault4626} from "../utils/mocks/SwapRouteMocks.sol";

/// @notice The oldest legacy Curve pools expose `coins(int128)`; they answer no `coins(uint256)` read.
contract Int128CoinsPool {
    address[] internal _coins;

    constructor(
        address[] memory coins_
    ) {
        _coins = coins_;
    }

    function coins(
        int128 i
    ) external view returns (address) {
        return _coins[uint256(int256(i))];
    }
}

/// @title DexHopsCurveLegacyUnitTest
/// @notice The legacy Curve hop (2.12 `REQ-ROUTE-046`): a pinned pool, its `coins(uint256)` checked against the hop's
/// indices at construction, `exchange(i, j, dx, 0)` measured by balance delta whether the pool returns nothing, the
/// amount or a wrong amount, a fee-switch input accepted like any Curve hop, and the route's own minimum after the hop.
contract DexHopsCurveLegacyUnitTest is SwapRouteFixture {
    /// @notice A 3pool-shaped [USDC, USDT] legacy pool (USDT at index 1 here) and its pinned list.
    function _pinned3(
        PayoutToken input
    ) internal returns (MockLegacyCurvePool pool, address[] memory pinned) {
        pool = _legacyPool(usdc, input, 1, 1);
        pinned = new address[](1);
        pinned[0] = address(pool);
    }

    function _route(
        address[] memory pinned,
        DexHop memory hop
    ) internal returns (DexPathRoute) {
        return new DexPathRoute(_configPinned(address(usdt), address(usdc), pinned), _hops1(hop));
    }

    function _expectRefused(
        RouteConfig memory config,
        DexHop[] memory hops
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployDexPath(config, hops);
    }

    // ─── Execution: return value never used ───

    /// @notice USDT -> USDC through the pinned legacy pool: 6,211.3 USDT become 6,211.3 USDC at 1:1 whether `exchange`
    /// returns nothing (the 3pool), the amount, or ten times the amount; the output is LPVaultSwap's balance rise, the
    /// pool is sent `min_dy = 0` and the exact input, and no allowance is left.
    // TEST-054 verifies: REQ-ROUTE-046, REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-015, REQ-ROUTE-016
    function test_TEST_054_legacyHopMeasuresOutputWhateverItReturns() public {
        (MockLegacyCurvePool pool, address[] memory pinned) = _pinned3(usdt);
        DexPathRoute route = _route(pinned, _legacyHop(address(pool), address(usdc), 1, 0));
        MockLegacyCurvePool.ReturnMode[3] memory modes = [
            MockLegacyCurvePool.ReturnMode.Nothing,
            MockLegacyCurvePool.ReturnMode.Amount,
            MockLegacyCurvePool.ReturnMode.Lie
        ];
        for (uint256 m = 0; m < 3; ++m) {
            pool.setReturnMode(modes[m]);
            uint256 before = usdc.balanceOf(address(swapper));
            uint256 out = _swap(route, 6_211_300_000, 6_145_112_406);
            assertEq(out, 6_211_300_000, "output measured, not returned");
            assertEq(usdc.balanceOf(address(swapper)) - before, out);
            assertEq(pool.lastMinDy(), 0, "min_dy is 0");
            assertEq(pool.lastDx(), 6_211_300_000, "the whole input");
        }
        assertEq(pool.exchangeCalls(), 3);
        assertEq(usdt.allowance(address(route), address(pool)), 0, "no allowance left");
        assertEq(usdt.balanceOf(address(route)), 0);
        assertEq(usdc.balanceOf(address(route)), 0);
        assertEq(route.exactAmountInputs().length, 0, "a Curve hop measures what it receives");
        assertEq(route.dependencies()[0], address(pool));
    }

    /// @notice The route's own minimum binds after the hop: a pool returning 0.99 per unit fails `minOut` one unit
    /// above its output with `MinOutNotMet`, never the pool's own minimum error.
    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-042, REQ-ROUTE-046
    function test_TEST_232_legacyHopMinimumIsTheRoutes() public {
        (MockLegacyCurvePool pool, address[] memory pinned) = _pinned3(usdt);
        pool.setRate(99, 100);
        DexPathRoute route = _route(pinned, _legacyHop(address(pool), address(usdc), 1, 0));
        usdt.mint(address(swapper), 1_000_000);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 990_000, 990_001));
        swapper.swapUnderLock(route, 1_000_000, 990_001);
        assertEq(_swap(route, 1_000_000, 990_000), 990_000);
    }

    // ─── Deployment checks ───

    /// @notice A legacy hop on a pool missing from the pinned list is refused, with an empty list, with another pool
    /// pinned, and when the pool is only known to the StableSwap-NG factory. A list of nine pools is refused before any
    /// hop; eight, with the pool among them, is accepted.
    // TEST-054 verifies: REQ-ROUTE-046, REQ-ROUTE-045
    function test_TEST_054_legacyHopNeedsAPinnedPool() public {
        (MockLegacyCurvePool pool,) = _pinned3(usdt);
        DexHop[] memory hops = _hops1(_legacyHop(address(pool), address(usdc), 1, 0));
        _expectRefused(_configPinned(address(usdt), address(usdc), new address[](0)), hops);
        MockLegacyCurvePool other = _legacyPool(usdc, usdt, 1, 1);
        _expectRefused(_configPinned(address(usdt), address(usdc), _list2(address(other), address(0xBEEF))), hops);
        // Known to the NG factory is not pinned.
        curveFactory.registerCurve(address(pool), _list2(address(usdc), address(usdt)));
        _expectRefused(_config(address(usdt), address(usdc)), hops);
        // Nine pinned pools: refused before any hop is read.
        address[] memory nine = new address[](9);
        for (uint256 k = 0; k < 9; ++k) {
            nine[k] = address(pool);
        }
        _expectRefused(_configPinned(address(usdt), address(usdc), nine), hops);
        // Eight, the bound, with the pool among them: accepted.
        address[] memory eight = new address[](8);
        eight[7] = address(pool);
        new DexPathRoute(_configPinned(address(usdt), address(usdc), eight), hops);
    }

    /// @notice The kinds do not stand in for each other: a pinned legacy pool named as a StableSwap-NG hop needs the NG
    /// factory to report it, and an NG pool named as a legacy hop needs to be pinned.
    // TEST-054 verifies: REQ-ROUTE-046, REQ-ROUTE-045
    function test_TEST_054_legacyAndNgKindsKeepTheirOwnProvenance() public {
        (MockLegacyCurvePool legacy, address[] memory pinned) = _pinned3(usdt);
        _expectRefused(
            _configPinned(address(usdt), address(usdc), pinned), _hops1(_curveHop(address(legacy), address(usdc), 1, 0))
        );
        MockCurvePool ng = _curvePool(usdt, usdc, 1, 1);
        _expectRefused(
            _configPinned(address(usdt), address(usdc), pinned), _hops1(_legacyHop(address(ng), address(usdc), 0, 1))
        );
        // Each under its own kind is accepted.
        new DexPathRoute(
            _configPinned(address(usdt), address(usdc), pinned), _hops1(_curveHop(address(ng), address(usdc), 0, 1))
        );
        new DexPathRoute(
            _configPinned(address(usdt), address(usdc), pinned),
            _hops1(_legacyHop(address(legacy), address(usdc), 1, 0))
        );
    }

    /// @notice Wrong indices are refused against the pool's `coins(uint256)`: swapped, equal, negative, out of range,
    /// and a pool that only answers `coins(int128)` (the oldest pools).
    // TEST-054 verifies: REQ-ROUTE-046, REQ-ROUTE-045
    function test_TEST_054_legacyHopIndicesCheckedAgainstCoins() public {
        (MockLegacyCurvePool pool, address[] memory pinned) = _pinned3(usdt);
        RouteConfig memory c = _configPinned(address(usdt), address(usdc), pinned);
        _expectRefused(c, _hops1(_legacyHop(address(pool), address(usdc), 0, 1)));
        _expectRefused(c, _hops1(_legacyHop(address(pool), address(usdc), 1, 1)));
        _expectRefused(c, _hops1(_legacyHop(address(pool), address(usdc), -1, 0)));
        _expectRefused(c, _hops1(_legacyHop(address(pool), address(usdc), 1, -1)));
        _expectRefused(c, _hops1(_legacyHop(address(pool), address(usdc), 2, 0)));
        _expectRefused(c, _hops1(_legacyHop(address(pool), address(usdc), 1, 3)));
        Int128CoinsPool oldest = new Int128CoinsPool(_list2(address(usdc), address(usdt)));
        pinned[0] = address(oldest);
        _expectRefused(
            _configPinned(address(usdt), address(usdc), pinned),
            _hops1(_legacyHop(address(oldest), address(usdc), 1, 0))
        );
    }

    // ─── Transfer fees (REQ-ROUTE-008) ───

    /// @notice A token that answers the fee-switch probe may enter a legacy Curve hop, as any Curve hop: the route is
    /// built with the fee off, lists no exact-amount input, and with a 10 bps fee on swaps what it received. 1,000,000
    /// units sent: the route receives 999,000, the pool receives 998,001 and pays 998,001 USDC. The same token as the
    /// input of a concentrated-liquidity hop after the legacy hop is still refused.
    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-046, REQ-ROUTE-003
    function test_TEST_221_feeSwitchTokenThroughLegacyCurve() public {
        PayoutToken t = PayoutToken(address(tether));
        (MockLegacyCurvePool pool, address[] memory pinned) = _pinned3(t);
        DexPathRoute route = new DexPathRoute(
            _configPinned(address(tether), address(usdc), pinned),
            _hops1(_legacyHop(address(pool), address(usdc), 1, 0))
        );
        assertEq(route.exactAmountInputs().length, 0);
        tether.setFeeBps(10);
        tether.mint(address(swapper), 1_000_000);
        assertEq(swapper.swapUnderLock(route, 1_000_000, 998_001), 998_001, "the fee is a cost inside the leg");
        assertEq(pool.lastDx(), 999_000, "the hop swaps what the route received");
        // DAI -> USDT (legacy) -> USDC (concentrated): the fee-switch token would pay a concentrated pool.
        MockLegacyCurvePool daiTether = _legacyPool(dai, t, 1, 1e12);
        MockCLPool clOut = _clPool(t, usdc, 1, 1);
        address[] memory two = _list2(address(pool), address(daiTether));
        _expectRefusedPath(
            _configPinned(address(dai), address(usdc), two),
            _hops2(_legacyHop(address(daiTether), address(tether), 0, 1), _clHop(address(clOut), address(usdc)))
        );
    }

    /// @notice As a later hop of a `WrapperThenDex` route: sUSDS-like shares redeem to USDT, which a pinned legacy pool
    /// swaps to USDC.
    // TEST-054 verifies: REQ-ROUTE-046, REQ-ROUTE-002
    function test_TEST_054_legacyHopAfterAWrapper() public {
        MockVault4626 vault = new MockVault4626(usdt, "sUSDT");
        usdt.mint(address(this), 2_000_000);
        usdt.approve(address(vault), 2_000_000);
        vault.deposit(2_000_000, address(swapper));
        (MockLegacyCurvePool pool, address[] memory pinned) = _pinned3(usdt);
        RouteConfig memory c = _configPinned(address(vault), address(usdc), pinned);
        WrapperThenDexRoute route = new WrapperThenDexRoute(
            c,
            WrapperStep({kind: WrapperKind.Erc4626Redeem, wrapper: address(vault), underlying: address(usdt)}),
            _hops1(_legacyHop(address(pool), address(usdc), 1, 0))
        );
        assertEq(swapper.swapUnderLock(route, 2_000_000, 2_000_000), 2_000_000);
        assertEq(pool.lastMinDy(), 0);
    }

    /// @notice For every amount, rate and return mode, the legacy hop pays LPVaultSwap exactly `amount × num / den`,
    /// reverts `MinOutNotMet` below `minOut`, and leaves the route with no balance and no allowance.
    // TEST-054 verifies: REQ-ROUTE-009, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-046
    function testFuzz_TEST_054_legacyHopConservesAndMeetsMinimum(
        uint128 amountIn,
        uint64 num,
        uint128 minOut,
        uint8 mode
    ) public {
        amountIn = uint128(bound(amountIn, 1, 1e30));
        num = uint64(bound(num, 0, 2e6));
        (MockLegacyCurvePool pool, address[] memory pinned) = _pinned3(usdt);
        pool.setRate(num, 1e6);
        pool.setReturnMode(MockLegacyCurvePool.ReturnMode(mode % 3));
        DexPathRoute route = _route(pinned, _legacyHop(address(pool), address(usdc), 1, 0));
        usdt.mint(address(swapper), amountIn);
        uint256 expected = uint256(amountIn) * num / 1e6;
        uint256 before = usdc.balanceOf(address(swapper));
        try swapper.swapUnderLock(route, amountIn, minOut) returns (uint256 out) {
            assertEq(out, expected);
            assertGe(out, minOut);
            assertEq(usdc.balanceOf(address(swapper)) - before, out);
        } catch (bytes memory reason) {
            if (minOut == 0) {
                assertEq(bytes4(reason), ISettlementRoute.ZeroMinOut.selector);
            } else {
                assertEq(reason, abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, expected, minOut));
            }
        }
        assertEq(usdt.balanceOf(address(route)), 0);
        assertEq(usdc.balanceOf(address(route)), 0);
        assertEq(usdt.allowance(address(route), address(pool)), 0);
    }

    function _expectRefusedPath(
        RouteConfig memory config,
        DexHop[] memory hops
    ) internal {
        _expectRefused(config, hops);
    }
}
