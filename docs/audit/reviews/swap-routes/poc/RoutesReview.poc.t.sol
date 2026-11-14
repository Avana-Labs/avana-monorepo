// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV3SwapCallback} from "../../src/interfaces/external/uniswap/IUniswapV3SwapCallback.sol";
import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {PegModuleKind, PegModuleStep} from "../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {MockCLPool, MockCurvePool, MockLitePsm} from "../utils/mocks/SwapRouteMocks.sol";

/// Look-alike pool: right token0/token1, not from any factory; takes the whole input in the callback and pays `out`.
contract FakeCLPool {
    address public immutable token0;
    address public immutable token1;
    uint256 public payOut;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setPayOut(uint256 p) external {
        payOut = p;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata)
        external
        returns (int256, int256)
    {
        address tout = zeroForOne ? token1 : token0;
        if (payOut != 0) {
            (bool ok,) = tout.call(abi.encodeWithSignature("transfer(address,uint256)", recipient, payOut));
            require(ok);
        }
        (int256 a0, int256 a1) = zeroForOne ? (amountSpecified, int256(0)) : (int256(0), amountSpecified);
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(a0, a1, "");
        return (a0, a1);
    }
}

contract RoutesReviewPoC is SwapRouteFixture {
    // M-1: USDT with its transfer fee switched on. REQ-ROUTE-008 says the route "settles at the reduced amount", but a
    // concentrated-liquidity hop pays `owed` in the callback and the pool receives owed - fee, so the pool's IIA
    // balance check reverts. Every route whose USDT enters a Uniswap v3 / Slipstream hop fails (input or intermediate).
    function test_PoC_M1_feeOnTransferInputRevertsOnClHop() public {
        (DexPathRoute route,) = _usdtUsdcRoute();
        usdt.setFeeBps(10);
        usdt.mint(address(swapper), 6_211_300_000);
        vm.expectRevert(bytes("IIA"));
        swapper.swapUnderLock(route, 6_211_300_000, 6000e6);
    }

    function test_PoC_M1_feeOnTransferIntermediateRevertsOnClHop() public {
        MockCurvePool p1 = _curvePool(dai, usdt, 1, 1e12);
        MockCLPool p2 = _clPool(usdt, usdc, 1, 1);
        DexPathRoute route = new DexPathRoute(
            _config(address(dai), address(usdc)),
            _hops2(_curveHop(address(p1), address(usdt), 0, 1), _clHop(address(p2), address(usdc)))
        );
        usdt.setFeeBps(10);
        dai.mint(address(swapper), 1000e18);
        vm.expectRevert(bytes("IIA"));
        swapper.swapUnderLock(route, 1000e18, 900e6);
    }

    // L-1: no factory provenance. Any contract reporting the right token0/token1 passes REQ-ROUTE-045; the look-alike
    // pool takes the whole input in the callback and pays only `minOut`, and the swap succeeds.
    function test_PoC_L1_lookalikePoolPassesConstructorAndKeepsSlack() public {
        FakeCLPool fake = new FakeCLPool(address(usdt), address(usdc));
        usdc.mint(address(fake), 1e30);
        DexPathRoute route =
            new DexPathRoute(_config(address(usdt), address(usdc)), _hops1(_clHop(address(fake), address(usdc))));
        fake.setPayOut(950e6); // fair value 1,000 USDC, minOut 950 USDC
        uint256 out = _swap(route, 1000e6, 950e6);
        assertEq(out, 950e6);
        assertEq(usdt.balanceOf(address(fake)), 1000e6, "fake pool kept the whole input");
    }

    // I-1: REQ-ROUTE-045 says the constructor reverts InvalidRouteConfig; a codeless pool or an out-of-range Curve
    // index reverts with empty data / a panic instead.
    function test_PoC_I1_constructorRevertReasonNotInvalidRouteConfig() public {
        try new DexPathRoute(_config(address(usdt), address(usdc)), _hops1(_clHop(address(0xBEEF), address(usdc)))) {
            fail();
        } catch (bytes memory reason) {
            assertEq(reason.length, 0, "empty revert, not InvalidRouteConfig");
        }
        MockCurvePool p = _curvePool(usdt, usdc, 1, 1);
        try new DexPathRoute(
            _config(address(usdt), address(usdc)), _hops1(_curveHop(address(p), address(usdc), 0, 5))
        ) {
            fail();
        } catch (bytes memory reason) {
            assertTrue(bytes4(reason) != ISettlementRoute.InvalidRouteConfig.selector);
        }
    }

    // I-2: a LitePSM whose gem is not TOKEN_OUT (or whose dai is not the route's DAI) deploys; it fails only at the
    // first liquidation (MinOutNotMet(0, ...)), contrary to the REQ-ROUTE-045 rationale.
    function test_PoC_I2_litePsmWithWrongGemDeploys() public {
        MockLitePsm wrong = new MockLitePsm(address(dai), address(usdt), 6);
        usdt.mint(address(wrong), 1e30);
        PegModuleRoute route = new PegModuleRoute(
            _config(address(dai), address(usdc)),
            PegModuleStep({
                kind: PegModuleKind.LitePsm, module: address(wrong), wrapper: address(0), intermediate: address(0)
            })
        );
        dai.mint(address(swapper), 1000e18);
        vm.expectRevert(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, 0, 1));
        swapper.swapUnderLock(route, 1000e18, 1);
    }
}
