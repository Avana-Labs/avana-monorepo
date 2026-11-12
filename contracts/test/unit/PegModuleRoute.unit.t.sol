// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {PegModuleKind, PegModuleStep} from "../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {MockDaiUsds, MockGsm, MockLitePsm, MockVault4626} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PegModuleRouteUnitTest
/// @notice Unit tests of the `PegModule` swap route (2.12, route type 0): the GSM legs (static aToken deposit, sale to
/// LPVaultSwap, unsold shares back), the LitePSM legs (gem amount of REQ-ROUTE-012, optional USDS conversion, DAI
/// residue back), a frozen, seized or capped GSM, a halted LitePSM, the callback, the views and the deployment checks.
contract PegModuleRouteUnitTest is SwapRouteFixture {
    MockVault4626 internal stataUsdc;
    MockGsm internal gsm;
    MockLitePsm internal psm;
    MockDaiUsds internal converter;

    function setUp() public override {
        super.setUp();
        stataUsdc = new MockVault4626(IERC20(address(usdc)), "stataUSDC");
        gsm = new MockGsm(address(stataUsdc), address(gho));
        gsm.setRate(1e12, 1); // 1 share (6 decimals) buys 1 GHO (18 decimals)
        psm = new MockLitePsm(address(dai), address(usdc), 6);
        usdc.mint(address(psm), 1e30);
        converter = new MockDaiUsds(address(usds), address(dai));
    }

    function _gsmStep() internal view returns (PegModuleStep memory step) {
        step = PegModuleStep({
            kind: PegModuleKind.Gsm, module: address(gsm), wrapper: address(stataUsdc), intermediate: address(stataUsdc)
        });
    }

    function _psmStep() internal view returns (PegModuleStep memory step) {
        step = PegModuleStep({
            kind: PegModuleKind.LitePsm, module: address(psm), wrapper: address(0), intermediate: address(0)
        });
    }

    function _usdsPsmStep() internal view returns (PegModuleStep memory step) {
        step = PegModuleStep({
            kind: PegModuleKind.LitePsm, module: address(psm), wrapper: address(converter), intermediate: address(dai)
        });
    }

    function _gsmRoute() internal returns (PegModuleRoute route) {
        route = new PegModuleRoute(_config(address(usdc), address(gho)), _gsmStep());
    }

    function _daiRoute() internal returns (PegModuleRoute route) {
        route = new PegModuleRoute(_config(address(dai), address(usdc)), _psmStep());
    }

    // ─── Caller, Lock and callback (TEST-046) ───

    // TEST-046 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function test_TEST_046_accessChecks() public {
        PegModuleRoute route = _gsmRoute();
        vm.expectRevert(ISettlementRoute.NotLPVaultSwap.selector);
        route.swap(1e6, 1);
        usdc.mint(address(swapper), 1e6);
        vm.expectRevert(ISettlementRoute.NotLocked.selector);
        swapper.swapHeld(route, 1e6, 1);
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function testFuzz_TEST_046_callbackAlwaysReverts(
        address caller,
        int256 amount0,
        int256 amount1
    ) public {
        PegModuleRoute route = _daiRoute();
        vm.prank(caller);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        route.uniswapV3SwapCallback(amount0, amount1, "");
    }

    // ─── GSM legs (TEST-054, TEST-232) ───

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-011, REQ-ROUTE-042, REQ-ROUTE-044, INV-083
    function test_TEST_232_gsmPaysLPVaultSwapAndMinimumIsCheckedThere() public {
        PegModuleRoute route = _gsmRoute();
        assertEq(_swap(route, 1000e6, 1000e18), 1000e18);
        assertEq(gho.balanceOf(address(swapper)), 1000e18);
        assertEq(gho.balanceOf(address(route)), 0);
        gsm.setRate(999e12, 1000); // a GSM price below the minimum
        usdc.mint(address(swapper), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 999e18, 1000e18));
        swapper.swapUnderLock(route, 1000e6, 1000e18);
    }

    // TEST-054 verifies: REQ-ROUTE-010, REQ-ROUTE-011, REQ-ROUTE-015, REQ-ROUTE-016, INV-021
    function test_TEST_054_gsmUnsoldSharesGoBackAndNoAllowanceRemains() public {
        PegModuleRoute route = _gsmRoute();
        gsm.setLot(1_000_000); // sells whole units of 1 share only
        assertEq(_swap(route, 1_234_567_890, 1), 1234e18);
        assertEq(IERC20(address(stataUsdc)).balanceOf(address(swapper)), 567_890, "unsold shares");
        assertEq(IERC20(address(stataUsdc)).balanceOf(address(route)), 0);
        assertEq(usdc.balanceOf(address(route)), 0);
        _assertNoAllowance(
            address(route), _list2(address(usdc), address(stataUsdc)), _list2(address(stataUsdc), address(gsm))
        );
    }

    // TEST-054 verifies: REQ-ROUTE-011, REQ-ROUTE-026, Q-341
    function test_TEST_054_frozenSeizedOrCappedGsmReverts() public {
        PegModuleRoute route = _gsmRoute();
        usdc.mint(address(swapper), 3e6);
        gsm.setFrozen(true);
        vm.expectRevert(bytes("GSM_FROZEN"));
        swapper.swapUnderLock(route, 1e6, 1);
        gsm.setFrozen(false);
        gsm.setSeized(true);
        vm.expectRevert(bytes("GSM_SEIZED"));
        swapper.swapUnderLock(route, 1e6, 1);
        gsm.setSeized(false);
        gsm.setCap(1e6 - 1); // live capacity below the leg
        vm.expectRevert(bytes("EXOGENOUS_ASSET_EXPOSURE_TOO_HIGH"));
        swapper.swapUnderLock(route, 1e6, 1);
        stataUsdc.setPaused(true);
        gsm.setCap(type(uint128).max);
        vm.expectRevert(bytes("paused"));
        swapper.swapUnderLock(route, 1e6, 1);
    }

    // ─── LitePSM legs (TEST-054) ───

    // TEST-054 verifies: REQ-ROUTE-012, REQ-ROUTE-015, REQ-ROUTE-009
    function test_TEST_054_litePsmExampleAtZeroFee() public {
        PegModuleRoute route = _daiRoute();
        uint256 daiIn = 1000e18 + 5e11; // 1,000.0000005 DAI
        assertEq(_swap(route, daiIn, 1000e6), 1000e6);
        assertEq(usdc.balanceOf(address(swapper)), 1000e6);
        assertEq(dai.balanceOf(address(swapper)), 5e11, "DAI below one USDC unit");
        assertEq(dai.balanceOf(address(route)), 0);
        assertEq(dai.allowance(address(route), address(psm)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-012
    function test_TEST_054_litePsmExampleAtTenBps() public {
        PegModuleRoute route = _daiRoute();
        psm.setTout(1e15);
        assertEq(_swap(route, 1001e18, 1000e6), 1000e6);
        assertEq(psm.lastDaiIn(), 1001e18, "cost is all the DAI");
        assertEq(dai.balanceOf(address(swapper)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-012, REQ-ROUTE-026
    function test_TEST_054_haltedLitePsmIsNotCalledAndRevertsMinOut() public {
        PegModuleRoute route = _daiRoute();
        psm.setTout(type(uint256).max);
        dai.mint(address(swapper), 10e18);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, 10e18, 1);
        assertEq(psm.lastDaiIn(), 0, "LitePSM called");
    }

    // TEST-177 verifies: REQ-ROUTE-012, REQ-ROUTE-015, INV-021
    function test_TEST_177_daiBelowOneGemUnitIsReturnedWithoutCallingThePsm() public {
        PegModuleRoute route = _daiRoute();
        usdc.setRevertOnZero(true);
        dai.mint(address(swapper), 1e12 - 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, 1e12 - 1, 1);
        assertEq(psm.lastDaiIn(), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-010, REQ-ROUTE-012, REQ-ROUTE-016, INV-021
    function test_TEST_054_usdsThroughConverterAndLitePsm() public {
        PegModuleRoute route = new PegModuleRoute(_config(address(usds), address(usdc)), _usdsPsmStep());
        psm.setTout(1e14); // 1 bp
        uint256 out = _swap(route, 2000e18, 1);
        // gemAmt = largest g with g·1e12·(1 + 1e-4) ≤ 2,000e18 → 1,999.800019 USDC.
        assertEq(out, 1_999_800_019);
        assertEq(dai.balanceOf(address(swapper)), 2000e18 - psm.lastDaiIn(), "DAI residue");
        assertEq(usds.allowance(address(route), address(converter)), 0);
        assertEq(dai.allowance(address(route), address(psm)), 0);
        address[] memory deps = route.dependencies();
        assertEq(deps.length, 2);
        assertEq(deps[0], address(converter));
        assertEq(deps[1], address(psm));
        address[] memory mid = route.intermediates();
        assertEq(mid.length, 1);
        assertEq(mid[0], address(dai));
    }

    // ─── Views (TEST-054) ───

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-003, REQ-ROUTE-005, Q-379
    function test_TEST_054_views() public {
        PegModuleRoute gsmRoute = _gsmRoute();
        assertEq(gsmRoute.routeType(), 0);
        assertEq(gsmRoute.tokenIn(), address(usdc));
        assertEq(gsmRoute.tokenOut(), address(gho));
        address[] memory deps = gsmRoute.dependencies();
        assertEq(deps.length, 2);
        assertEq(deps[0], address(stataUsdc));
        assertEq(deps[1], address(gsm));
        address[] memory mid = gsmRoute.intermediates();
        assertEq(mid.length, 1);
        assertEq(mid[0], address(stataUsdc));
        assertEq(gsmRoute.LP_VAULT_SWAP(), address(swapper));
        assertEq(gsmRoute.AAVE_ADAPTER(), address(adapter));
        assertTrue(gsmRoute.supportsTokenClass(1));
        assertFalse(gsmRoute.supportsTokenClass(3));

        PegModuleRoute daiRoute = _daiRoute();
        deps = daiRoute.dependencies();
        assertEq(deps.length, 1);
        assertEq(deps[0], address(psm));
        assertEq(daiRoute.intermediates().length, 0);
    }

    // ─── Deployment checks (TEST-054) ───

    // TEST-054 verifies: REQ-ROUTE-045
    function test_TEST_054_constructorRejectsBadGsmLegs() public {
        PegModuleStep memory step;
        step = _gsmStep();
        step.module = address(0);
        _expectBad(address(usdc), address(gho), step);
        step = _gsmStep();
        step.wrapper = address(0);
        step.intermediate = address(0);
        _expectBad(address(usdc), address(gho), step);
        step = _gsmStep();
        step.intermediate = address(dai);
        _expectBad(address(usdc), address(gho), step);
        // Static aToken of another asset.
        _expectBad(address(usdt), address(gho), _gsmStep());
        // GSM paying another token than the output.
        _expectBad(address(usdc), address(dai), _gsmStep());
        // GSM whose underlying is another wrapper.
        MockVault4626 other = new MockVault4626(IERC20(address(usdc)), "x");
        step = _gsmStep();
        step.wrapper = address(other);
        step.intermediate = address(other);
        _expectBad(address(usdc), address(gho), step);
    }

    // TEST-054 verifies: REQ-ROUTE-045
    function test_TEST_054_constructorRejectsBadLitePsmLegs() public {
        PegModuleStep memory step;
        step = _psmStep();
        step.wrapper = address(converter); // converter without DAI
        _expectBad(address(usds), address(usdc), step);
        step = _psmStep();
        step.intermediate = address(dai); // DAI without converter
        _expectBad(address(usds), address(usdc), step);
        step = _usdsPsmStep();
        step.intermediate = address(usds); // DAI equal to the input token
        _expectBad(address(usds), address(usdc), step);
        step = _usdsPsmStep();
        step.intermediate = address(usdc); // DAI equal to the output token
        _expectBad(address(usds), address(usdc), step);
        step = _usdsPsmStep();
        step.wrapper = address(psm); // converter equal to the module
        _expectBad(address(usds), address(usdc), step);
        step = _psmStep();
        step.module = address(dai); // module equal to the input token
        _expectBad(address(dai), address(usdc), step);
        // Gem with more than 18 decimals.
        PayoutToken big = new PayoutToken("BIG", 24);
        _expectBad(address(dai), address(big), _psmStep());
    }

    function _expectBad(
        address tokenIn,
        address tokenOut,
        PegModuleStep memory step
    ) internal {
        vm.expectRevert(ISettlementRoute.InvalidRouteConfig.selector);
        this.deployPegModule(_config(tokenIn, tokenOut), step);
    }
}
