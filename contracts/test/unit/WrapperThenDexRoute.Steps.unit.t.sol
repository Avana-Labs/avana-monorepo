// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {WrapperThenDexRoute} from "../../src/liquidation/settlement-routes/WrapperThenDexRoute.sol";
import {DexHop} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {WrapperKind, WrapperStep} from "../../src/liquidation/settlement-routes/types/WrapperStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {RawAnswer} from "../utils/mocks/RouteReadTargets.sol";
import {MockCLPool, MockCurvePool, MockDaiUsds, MockVault4626} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WrapperThenDexRouteStepsUnitTest
/// @notice The wrapper step in depth: deployment checks that read the wrapper (a vault whose `asset()` reverts or
/// answers a dirty word, a converter whose getters revert, a zero step output, a hop count of three and four after the
/// step), and the redeem at any share price measured as the route's balance rise and passed whole to the hops.
contract WrapperThenDexRouteStepsUnitTest is SwapRouteFixture {
    MockVault4626 internal susds;
    MockDaiUsds internal converter;

    function setUp() public override {
        super.setUp();
        susds = new MockVault4626(IERC20(address(usds)), "sUSDS");
        converter = new MockDaiUsds(address(usds), address(dai));
    }

    // TEST-054 verifies: REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (an ERC-4626 step's wrapper is TOKEN_IN and its asset() the step's output)
    /// @notice A vault input whose `asset()` reverts or answers a word with bits above 160 is refused; a zero step
    /// output is refused before any hop is read; a converter whose `usds()` or `dai()` reverts is refused.
    function test_TEST_054_wrapperReadsFailClosed() public {
        MockCurvePool usdsUsdc = _curvePool(usds, usdc, 1, 1e12);
        DexHop[] memory fromUsds = _hops1(_curveHop(address(usdsUsdc), address(usdc), 0, 1));
        RawAnswer vault = new RawAnswer();
        vault.setReverts(true);
        _expectBad(address(vault), WrapperStep(WrapperKind.Erc4626Redeem, address(vault), address(usds)), fromUsds);
        vault.setReverts(false);
        vault.set(abi.encode(uint256(uint160(address(usds))) | (uint256(1) << 200)));
        _expectBad(address(vault), WrapperStep(WrapperKind.Erc4626Redeem, address(vault), address(usds)), fromUsds);
        vault.set(abi.encode(address(usds)));
        new WrapperThenDexRoute(
            _config(address(vault), address(usdc)),
            WrapperStep(WrapperKind.Erc4626Redeem, address(vault), address(usds)),
            fromUsds
        );
        _expectBad(address(susds), WrapperStep(WrapperKind.Erc4626Redeem, address(susds), address(0)), new DexHop[](0));
        RawAnswer conv = new RawAnswer();
        conv.setReverts(true);
        MockCurvePool daiUsdc = _curvePool(dai, usdc, 1, 1e12);
        _expectBad(
            address(usds),
            WrapperStep(WrapperKind.UsdsToDai, address(conv), address(dai)),
            _hops1(_curveHop(address(daiUsdc), address(usdc), 0, 1))
        );
    }

    // TEST-054 verifies: REQ-ROUTE-045, REQ-ROUTE-002
    // Sources: 2.12 REQ-ROUTE-045 (a WrapperThenDex has up to three hops)
    /// @notice Three hops after the converter are accepted and swap end to end; a fourth is refused.
    function test_TEST_054_threeHopsAfterTheStepAndNotFour() public {
        MockCLPool p1 = _clPool(dai, usdt, 1, 1e12);
        MockCurvePool p2 = _curvePool(usdt, weth, 1e12, 3000);
        MockCLPool p3 = _clPool(weth, usdc, 3000e6, 1e18);
        DexHop[] memory three = _hops3(
            _clHop(address(p1), address(usdt)),
            _curveHop(address(p2), address(weth), 0, 1),
            _clHop(address(p3), address(usdc))
        );
        WrapperThenDexRoute route = new WrapperThenDexRoute(
            _config(address(usds), address(usdc)),
            WrapperStep(WrapperKind.UsdsToDai, address(converter), address(dai)),
            three
        );
        assertEq(route.dependencies().length, 4, "converter and three pools");
        address[] memory mid = route.intermediates();
        assertEq(mid.length, 3);
        assertEq(mid[0], address(dai));
        assertEq(mid[1], address(usdt));
        assertEq(mid[2], address(weth));
        assertEq(_swap(route, 3000e18, 3000e6), 3000e6, "USDS to USDC through DAI, USDT and WETH");
        MockCurvePool p4 = _curvePool(usdc, gho, 1e12, 1);
        DexHop[] memory four = new DexHop[](4);
        (four[0], four[1], four[2]) = (three[0], three[1], three[2]);
        four[3] = _curveHop(address(p4), address(gho), 0, 1);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new WrapperThenDexRoute(
            _config(address(usds), address(gho)),
            WrapperStep(WrapperKind.UsdsToDai, address(converter), address(dai)),
            four
        );
    }

    // TEST-054 verifies: REQ-ROUTE-008, REQ-ROUTE-015, REQ-ROUTE-016, INV-021
    // Sources: 2.12 REQ-ROUTE-008 (the assets are measured as the route's balance rise, never taken from redeem's
    // return value)
    /// @notice At any share price (yield donated to the vault) the route redeems the shares it received and hands the
    /// hop exactly the assets redeemed: the output equals `previewRedeem(shares)` at the 1:1 pool, and the route ends
    /// with no shares and no assets.
    function testFuzz_TEST_054_redeemAtAnySharePrice(
        uint256 seed,
        uint256 yield,
        uint256 shares
    ) public {
        seed = bound(seed, 1e18, 1e27);
        yield = bound(yield, 0, seed);
        usds.mint(address(this), seed);
        usds.approve(address(susds), seed);
        susds.deposit(seed, address(this));
        usds.mint(address(susds), yield);
        shares = bound(shares, 1, susds.balanceOf(address(this)));
        IERC20(address(susds)).transfer(address(swapper), shares);
        MockCurvePool pool = _curvePool(usds, gho, 1, 1);
        WrapperThenDexRoute route = new WrapperThenDexRoute(
            _config(address(susds), address(gho)),
            WrapperStep(WrapperKind.Erc4626Redeem, address(susds), address(usds)),
            _hops1(_curveHop(address(pool), address(gho), 0, 1))
        );
        uint256 expected = susds.previewRedeem(shares);
        if (expected == 0) {
            vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
            swapper.swapUnderLock(route, shares, 1);
            return;
        }
        assertEq(swapper.swapUnderLock(route, shares, expected), expected, "assets redeemed, swapped 1:1");
        assertEq(IERC20(address(susds)).balanceOf(address(route)), 0);
        assertEq(usds.balanceOf(address(route)), 0);
        assertEq(gho.balanceOf(address(swapper)), expected);
    }

    function _expectBad(
        address tokenIn,
        WrapperStep memory step,
        DexHop[] memory hops
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        new WrapperThenDexRoute(_config(tokenIn, address(usdc)), step, hops);
    }
}
