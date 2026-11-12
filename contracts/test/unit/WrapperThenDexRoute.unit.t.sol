// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {WrapperThenDexRoute} from "../../src/liquidation/settlement-routes/WrapperThenDexRoute.sol";
import {DexHop} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {WrapperKind, WrapperStep} from "../../src/liquidation/settlement-routes/types/WrapperStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {MockCLPool, MockCurvePool, MockDaiUsds, MockVault4626} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WrapperThenDexRouteUnitTest
/// @notice Unit tests of the `WrapperThenDex` swap route (2.12, route type 2): an ERC-4626 redeem or the DAI/USDS
/// converter, then DEX hops; caller and Lock checks, the per-swap minimum, residues of the unwrapped token, allowances,
/// a paused wrapper, the views and the deployment checks.
contract WrapperThenDexRouteUnitTest is SwapRouteFixture {
    MockVault4626 internal susds;
    MockDaiUsds internal converter;

    function setUp() public override {
        super.setUp();
        susds = new MockVault4626(IERC20(address(usds)), "sUSDS");
        converter = new MockDaiUsds(address(usds), address(dai));
        // Share price 1.05 USDS: 1,000 USDS deposited, then 50 USDS of yield.
        usds.mint(address(this), 1000e18);
        usds.approve(address(susds), 1000e18);
        susds.deposit(1000e18, address(this));
        usds.mint(address(susds), 50e18);
    }

    function _redeemStep() internal view returns (WrapperStep memory step) {
        step = WrapperStep({kind: WrapperKind.Erc4626Redeem, wrapper: address(susds), underlying: address(usds)});
    }

    function _converterStep() internal view returns (WrapperStep memory step) {
        step = WrapperStep({kind: WrapperKind.UsdsToDai, wrapper: address(converter), underlying: address(dai)});
    }

    /// @notice sUSDS → USDS (redeem) → USDC over a Curve USDS/USDC pool at 1 USDS = 1 USDC.
    function _susdsRoute() internal returns (WrapperThenDexRoute route, MockCurvePool pool) {
        pool = _curvePool(usds, usdc, 1, 1e12);
        route = new WrapperThenDexRoute(
            _config(address(susds), address(usdc)), _redeemStep(), _hops1(_curveHop(address(pool), address(usdc), 0, 1))
        );
    }

    function _mintShares(
        uint256 shares
    ) internal {
        uint256 assets = susds.previewMint(shares);
        usds.mint(address(this), assets);
        usds.approve(address(susds), assets);
        susds.mint(shares, address(swapper));
    }

    // ─── Caller, Lock and callback (TEST-046) ───

    // TEST-046 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function test_TEST_046_accessChecks() public {
        (WrapperThenDexRoute route,) = _susdsRoute();
        vm.expectRevert(ISettlementRoute.NotLPVaultSwap.selector);
        route.swap(1e18, 1);
        _mintShares(1e18);
        vm.expectRevert(ISettlementRoute.NotLocked.selector);
        swapper.swapHeld(route, 1e18, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function testFuzz_TEST_046_callbackRevertsOutsideHop(
        address caller,
        int256 amount0,
        int256 amount1
    ) public {
        (WrapperThenDexRoute route,) = _susdsRoute();
        vm.prank(caller);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        route.uniswapV3SwapCallback(amount0, amount1, "");
    }

    // ─── Legs and the per-swap minimum (TEST-232, TEST-054) ───

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-042, REQ-ROUTE-044, INV-083
    function test_TEST_232_redeemThenHopMeetsOrRevertsOnMinimum() public {
        (WrapperThenDexRoute route,) = _susdsRoute();
        _mintShares(100e18);
        // About 105 USDC: OpenZeppelin's virtual share rounds the redeem down by a fraction of a wei.
        uint256 expected = susds.previewRedeem(100e18) / 1e12;
        assertApproxEqAbs(expected, 105e6, 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, expected, expected + 1));
        swapper.swapUnderLock(route, 100e18, expected + 1);
        assertEq(swapper.swapUnderLock(route, 100e18, expected), expected);
        assertEq(usdc.balanceOf(address(swapper)), expected);
        assertEq(IERC20(address(susds)).balanceOf(address(route)), 0);
        assertEq(usds.balanceOf(address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-003, REQ-ROUTE-005, REQ-ROUTE-043
    function test_TEST_054_viewsListWrapperAndPools() public {
        (WrapperThenDexRoute route, MockCurvePool pool) = _susdsRoute();
        assertEq(route.routeType(), 2);
        assertEq(route.tokenIn(), address(susds));
        assertEq(route.tokenOut(), address(usdc));
        address[] memory deps = route.dependencies();
        assertEq(deps.length, 2);
        assertEq(deps[0], address(susds));
        assertEq(deps[1], address(pool));
        address[] memory mid = route.intermediates();
        assertEq(mid.length, 1);
        assertEq(mid[0], address(usds));
        assertEq(route.LP_VAULT_SWAP(), address(swapper));
        assertEq(route.AAVE_ADAPTER(), address(adapter));
        assertTrue(route.supportsTokenClass(1));
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-003
    function test_TEST_054_redeemIntoTheDebtAssetNeedsNoHop() public {
        WrapperThenDexRoute route =
            this.deployWrapperThenDex(_config(address(susds), address(usds)), _redeemStep(), new DexHop[](0));
        assertEq(route.dependencies().length, 1);
        assertEq(route.intermediates().length, 0);
        _mintShares(20e18);
        uint256 expected = susds.previewRedeem(20e18);
        assertEq(swapper.swapUnderLock(route, 20e18, expected), expected);
        assertEq(usds.balanceOf(address(swapper)), expected);
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-010, REQ-ROUTE-016, INV-021
    function test_TEST_054_converterThenHopsLeavesNoAllowance() public {
        MockCLPool daiUsdc = _clPool(dai, usdc, 1, 1e12);
        MockCLPool usdcWeth = _clPool(usdc, weth, 1e12, 3000);
        WrapperThenDexRoute route = new WrapperThenDexRoute(
            _config(address(usds), address(weth)),
            _converterStep(),
            _hops2(_clHop(address(daiUsdc), address(usdc)), _clHop(address(usdcWeth), address(weth)))
        );
        assertEq(_swap(route, 3000e18, 1e18), 1e18);
        assertEq(usds.allowance(address(route), address(converter)), 0);
        address[] memory deps = route.dependencies();
        assertEq(deps.length, 3);
        assertEq(deps[0], address(converter));
        address[] memory mid = route.intermediates();
        assertEq(mid.length, 2);
        assertEq(mid[0], address(dai));
        assertEq(mid[1], address(usdc));
        assertEq(dai.balanceOf(address(route)) + usdc.balanceOf(address(route)) + usds.balanceOf(address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-034, INV-021
    function test_TEST_054_unwrappedResidueGoesBackToLPVaultSwap() public {
        MockCLPool pool = _clPool(usds, usdc, 1, 1e12);
        pool.setMaxIn(100e18);
        WrapperThenDexRoute route = new WrapperThenDexRoute(
            _config(address(susds), address(usdc)), _redeemStep(), _hops1(_clHop(address(pool), address(usdc)))
        );
        _mintShares(100e18); // redeems for about 105 USDS; the pool takes 100
        uint256 redeemed = susds.previewRedeem(100e18);
        assertEq(swapper.swapUnderLock(route, 100e18, 100e6), 100e6);
        assertEq(usds.balanceOf(address(swapper)), redeemed - 100e18, "USDS residue");
        assertEq(usds.balanceOf(address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-026
    function test_TEST_054_pausedWrapperReverts() public {
        (WrapperThenDexRoute route,) = _susdsRoute();
        _mintShares(1e18);
        susds.setPaused(true);
        vm.expectRevert(bytes("paused"));
        swapper.swapUnderLock(route, 1e18, 1);
    }

    // TEST-177 verifies: REQ-ROUTE-015, INV-021
    function test_TEST_177_zeroUnwrapRunsNoHopAndRevertsMinOut() public {
        MockCurvePool pool = _curvePool(usds, usdc, 1, 1e12);
        pool.setHalted(true); // any hop call would revert "halted"
        usds.setRevertOnZero(true);
        usdc.setRevertOnZero(true);
        // A vault whose shares redeem to 0 assets: the route skips the hops and transfers no zero residue.
        ZeroRedeemVault zero = new ZeroRedeemVault(address(usds));
        WrapperThenDexRoute route = new WrapperThenDexRoute(
            _config(address(zero), address(usdc)),
            WrapperStep({kind: WrapperKind.Erc4626Redeem, wrapper: address(zero), underlying: address(usds)}),
            _hops1(_curveHop(address(pool), address(usdc), 0, 1))
        );
        zero.mint(address(swapper), 5);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, 5, 1);
    }

    // ─── Deployment checks (TEST-054) ───

    // TEST-054 verifies: REQ-ROUTE-045
    function test_TEST_054_constructorRejectsBadSteps() public {
        MockCurvePool usdsUsdc = _curvePool(usds, usdc, 1, 1e12);
        MockCurvePool daiUsdc = _curvePool(dai, usdc, 1, 1e12);
        DexHop[] memory fromUsds = _hops1(_curveHop(address(usdsUsdc), address(usdc), 0, 1));
        DexHop[] memory fromDai = _hops1(_curveHop(address(daiUsdc), address(usdc), 0, 1));
        WrapperStep memory step;

        // ERC-4626: wrapper must be the input token, underlying its asset.
        step = _redeemStep();
        step.wrapper = address(converter);
        _expectBad(address(susds), step, fromUsds);
        step = _redeemStep();
        step.underlying = address(dai);
        _expectBad(address(susds), step, fromDai);
        // Zero wrapper; underlying equal to the input token.
        step = _converterStep();
        step.wrapper = address(0);
        _expectBad(address(usds), step, fromDai);
        step = _converterStep();
        step.underlying = address(usds);
        _expectBad(address(usds), step, fromUsds);
        // Converter equal to the input or output token.
        step = _converterStep();
        step.wrapper = address(usds);
        _expectBad(address(usds), step, fromDai);
        step = _converterStep();
        step.wrapper = address(usdc);
        _expectBad(address(usds), step, fromDai);
        // Hops that start from another token than the step's output.
        _expectBad(address(usds), _converterStep(), fromUsds);
        // A step yielding the debt asset with hops after it.
        MockCurvePool loop = _curvePool(dai, usdc, 1, 1);
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployWrapperThenDex(
            _config(address(usds), address(dai)),
            _converterStep(),
            _hops1(_curveHop(address(loop), address(usdc), 0, 1))
        );
        // The step's contract is also a hop pool.
        step = _converterStep();
        step.wrapper = address(daiUsdc);
        _expectBad(address(usds), step, fromDai);
    }

    function _expectBad(
        address tokenIn,
        WrapperStep memory step,
        DexHop[] memory hops
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployWrapperThenDex(_config(tokenIn, address(usdc)), step, hops);
    }
}

/// @notice An ERC-4626 look-alike whose shares redeem to nothing, to drive the zero-unwrap path.
contract ZeroRedeemVault {
    address public immutable asset;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(
        address asset_
    ) {
        asset = asset_;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        balanceOf[to] += amount;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function redeem(
        uint256 shares,
        address,
        address owner
    ) external returns (uint256) {
        balanceOf[owner] -= shares;
        return 0;
    }
}
