// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IGsm} from "../../src/interfaces/external/gho/IGsm.sol";
import {ILitePsm} from "../../src/interfaces/external/sky/ILitePsm.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {RouteMath} from "../../src/liquidation/settlement-routes/RouteMath.sol";
import {PegModuleKind, PegModuleStep} from "../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {RouteConfig} from "../../src/liquidation/settlement-routes/types/RouteConfig.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";
import {LockMember} from "../utils/mocks/LockMember.sol";
import {MockRouteCaller} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice GSM reads beyond `IGsm`: the room left under the exposure cap.
interface IForkGsm {
    function getAvailableUnderlyingExposure() external view returns (uint256);
}

/// @title PegModuleRoutesForkTest
/// @notice The peg modules of the Ethereum swap routes (2.12 `PegModule`) against the real contracts the unit tests
/// replace with `MockGsm`, `RegistryGsmMock`, `MockLitePsm`, `MockDaiUsds` and `MockPsmAndConverter`:
/// - `TEST-119`: the current GSM USDC (EXT-013) is neither seized nor frozen and has room under its exposure cap; a
///   `PegModuleRoute` built on it turns 1,000 USDC into GHO through the static aToken the GSM names, paying LPVaultSwap
///   the measured GHO and keeping no balance or allowance; the GSM USDC of the old address book reports
///   `getIsSeized() == true`, and a route on it never delivers (refused at construction or reverting), so the leg
///   moves to the next route.
/// - `TEST-120`: the Sky LitePSM USDC and the DAI/USDS converter turn 1,000,000 DAI, and 1,000,000 USDS through the
///   converter, into exactly the USDC `RouteMath.litePsmGemAmt` computes from the live `tout()`.
/// LPVaultSwap is the suites' `MockRouteCaller` and the AaveAdapter a `LockMember` around the real Lock. Forks at the
/// pinned Ethereum block when one is set, else at the latest block; skipped without `RPC_MAINNET`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract PegModuleRoutesForkTest`.
contract PegModuleRoutesForkTest is AvanaTest {
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address internal constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    /// @dev EXT-013: the current GSM USDC, and the seized one of the old address book (`AMMN-INT-02`).
    address internal constant GSM_USDC = 0x3A3868898305f04beC7FEa77BecFf04C13444112;
    address internal constant GSM_USDC_SEIZED = 0xFeeb6FE430B7523fEF2a38327241eE7153779535;
    /// @dev EXT-014: the Sky LitePSM USDC and the DAI/USDS converter.
    address internal constant LITE_PSM = 0xf6e72Db5454dd049d0788e411b06CfAF16853042;
    address internal constant DAI_USDS = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
    uint8 internal constant STABLE = 1 << 1;

    MockRouteCaller internal swapper;
    LockMember internal adapter;
    Lock internal lock;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_MAINNET", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = ForkConstants.mainnetForkBlock();
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        swapper = new MockRouteCaller();
        adapter = new LockMember();
        lock = new Lock(address(adapter), address(swapper));
        swapper.setLock(lock);
        adapter.setLock(lock);
    }

    // TEST-119 verifies: Q-062, Q-187
    function test_TEST_119_liveGsmSellsUsdcForGhoThroughItsStaticAToken() public {
        IGsm gsm = IGsm(GSM_USDC);
        assertFalse(gsm.getIsSeized(), "current GSM USDC is not seized");
        assertFalse(gsm.getIsFrozen(), "current GSM USDC is not frozen");
        assertGt(gsm.getExposureCap(), 0, "cap above 0");
        assertEq(gsm.GHO_TOKEN(), GHO);
        address wrapper = gsm.UNDERLYING_ASSET();
        PegModuleRoute route =
            new PegModuleRoute(_config(USDC, GHO), PegModuleStep(PegModuleKind.Gsm, GSM_USDC, wrapper, wrapper));

        uint256 amount = 1000e6;
        uint256 room = IForkGsm(GSM_USDC).getAvailableUnderlyingExposure();
        deal(USDC, address(swapper), amount);
        if (room < amount) {
            // Live capacity below the leg: the GSM refuses, so LPVaultSwap takes the next route.
            vm.expectRevert();
            swapper.swapUnderLock(route, amount, 1);
            return;
        }
        uint256 before = IERC20(GHO).balanceOf(address(swapper));
        uint256 out = swapper.swapUnderLock(route, amount, 990e18);
        assertEq(IERC20(GHO).balanceOf(address(swapper)) - before, out, "measured GHO output");
        assertGe(out, 990e18, "1,000 USDC sells for at least 990 GHO");
        assertLe(out, 1001e18);
        _assertRouteEmpty(address(route), USDC, wrapper, GSM_USDC);
    }

    // TEST-119 verifies: Q-062, Q-084, Q-187
    function test_TEST_119_seizedGsmNeverDeliversSoTheLegMovesOn() public {
        IGsm gsm = IGsm(GSM_USDC_SEIZED);
        assertTrue(gsm.getIsSeized(), "the old GSM USDC is seized");
        address wrapper = gsm.UNDERLYING_ASSET();
        RouteConfig memory c = _config(USDC, GHO);
        PegModuleStep memory step = PegModuleStep(PegModuleKind.Gsm, GSM_USDC_SEIZED, wrapper, wrapper);
        try this.deployPeg(c, step) returns (PegModuleRoute route) {
            deal(USDC, address(swapper), 1000e6);
            vm.expectRevert();
            swapper.swapUnderLock(route, 1000e6, 1);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ISettlementRoute.InvalidRouteConfig.selector, "refused at construction");
        }
    }

    // TEST-120 verifies: Q-062, Q-187
    function test_TEST_120_litePsmBuysUsdcWithDaiAtItsLiveFee() public {
        assertEq(ILitePsm(LITE_PSM).gem(), USDC);
        assertEq(ILitePsm(LITE_PSM).dai(), DAI);
        assertEq(ILitePsm(LITE_PSM).to18ConversionFactor(), 1e12);
        PegModuleRoute route = new PegModuleRoute(
            _config(DAI, USDC), PegModuleStep(PegModuleKind.LitePsm, LITE_PSM, address(0), address(0))
        );
        uint256 amount = 1_000_000e18;
        uint256 expected = RouteMath.litePsmGemAmt(amount, ILitePsm(LITE_PSM).tout(), 1e12);
        assertGe(expected, 999_000e6, "tout at most 0.1 %");
        deal(DAI, address(swapper), amount);
        uint256 before = IERC20(USDC).balanceOf(address(swapper));
        uint256 out = swapper.swapUnderLock(route, amount, expected);
        assertEq(out, expected, "exactly the gem amount the live tout gives");
        assertEq(IERC20(USDC).balanceOf(address(swapper)) - before, out);
        _assertRouteEmpty(address(route), DAI, address(0), LITE_PSM);
    }

    // TEST-120 verifies: Q-062, Q-187
    function test_TEST_120_usdsReachesUsdcThroughTheConverterAndTheLitePsm() public {
        PegModuleRoute route =
            new PegModuleRoute(_config(USDS, USDC), PegModuleStep(PegModuleKind.LitePsm, LITE_PSM, DAI_USDS, DAI));
        uint256 amount = 1_000_000e18;
        // The converter is 1:1, so the DAI the LitePSM spends is the USDS amount.
        uint256 expected = RouteMath.litePsmGemAmt(amount, ILitePsm(LITE_PSM).tout(), 1e12);
        deal(USDS, address(swapper), amount);
        uint256 out = swapper.swapUnderLock(route, amount, expected);
        assertEq(out, expected, "USDS -> DAI 1:1, then the LitePSM");
        _assertRouteEmpty(address(route), USDS, DAI, LITE_PSM);
        assertEq(IERC20(USDS).allowance(address(route), DAI_USDS), 0);
    }

    /// @dev An external call, so a constructor revert can be caught.
    function deployPeg(
        RouteConfig memory config,
        PegModuleStep memory step
    ) external returns (PegModuleRoute) {
        return new PegModuleRoute(config, step);
    }

    function _config(
        address tokenIn,
        address tokenOut
    ) internal view returns (RouteConfig memory c) {
        c = RouteConfig({
            lpVaultSwap: address(swapper),
            lock: address(lock),
            aaveAdapter: address(adapter),
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tokenClassMask: STABLE,
            uniswapV3Factory: address(0),
            slipstreamFactory: address(0),
            curveFactory: address(0),
            curveLegacyPools: new address[](0)
        });
    }

    function _assertRouteEmpty(
        address route,
        address tokenIn,
        address intermediate,
        address module
    ) internal view {
        assertEq(IERC20(tokenIn).balanceOf(route), 0, "no input left on the route");
        assertEq(IERC20(tokenIn).allowance(route, module), 0);
        if (intermediate != address(0)) {
            assertEq(IERC20(intermediate).balanceOf(route), 0, "no intermediate left on the route");
            assertEq(IERC20(intermediate).allowance(route, module), 0);
        }
    }
}
