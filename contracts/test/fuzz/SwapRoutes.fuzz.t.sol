// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {PegModuleKind, PegModuleStep} from "../../src/liquidation/settlement-routes/types/PegModuleStep.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {MockCLPool, MockCurvePool, MockLitePsm} from "../utils/mocks/SwapRouteMocks.sol";

/// @title SwapRoutesFuzzTest
/// @notice Stateless fuzzing of a whole `swap` call: for any input, pool rates, pool depth, transfer fee and minimum,
/// the call either delivers at least `minOut` (measured at LPVaultSwap) and returns exactly what LPVaultSwap received,
/// or reverts; LPVaultSwap never loses more input than `amountIn`; the route ends with its starting balances and no
/// allowance; residues come back to LPVaultSwap.
contract SwapRoutesFuzzTest is SwapRouteFixture {
    // TEST-054 verifies: REQ-ROUTE-008, REQ-ROUTE-009, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-042, INV-021, INV-034
    function testFuzz_TEST_054_dexPathConservesAndMeetsMinimum(
        uint128 amountIn,
        uint64 rate1,
        uint64 rate2,
        uint128 depth1,
        uint128 depth2,
        uint16 feeBps,
        uint128 minOut,
        uint32 donation
    ) public {
        amountIn = uint128(bound(amountIn, 1, 1e30));
        // Curve hop first (it accepts a fee-taking input), then a concentrated-liquidity hop with a depth limit.
        MockCurvePool p1 = _curvePool(cbeth, weth, bound(rate1, 0, 2e6), 1e6);
        MockCLPool p2 = _clPool(weth, usdc, bound(rate2, 0, 5e9), 1e18);
        p2.setMaxIn(bound(depth2, 1, type(uint128).max));
        DexPathRoute route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_curveHop(address(p1), address(weth), 0, 1), _clHop(address(p2), address(usdc)))
        );
        depth1; // the Curve mock has no depth limit
        cbeth.setFeeBps(bound(feeBps, 0, 50));
        cbeth.mint(address(route), donation);
        weth.mint(address(route), donation);
        usdc.mint(address(route), donation);
        cbeth.mint(address(swapper), amountIn);

        uint256 inBefore = cbeth.balanceOf(address(swapper));
        uint256 outBefore = usdc.balanceOf(address(swapper));
        try swapper.swapUnderLock(route, amountIn, minOut) returns (uint256 out) {
            assertEq(out, usdc.balanceOf(address(swapper)) - outBefore, "return equals LPVaultSwap delta");
            assertGe(out, minOut, "below minOut");
            assertLe(inBefore - cbeth.balanceOf(address(swapper)), amountIn, "took more than amountIn");
        } catch (bytes memory reason) {
            bytes4 sel = bytes4(reason);
            assertTrue(
                sel == ISettlementRoute.MinOutNotMet.selector || sel == ISettlementRoute.TransferMismatch.selector
                    || (sel == ISettlementRoute.ZeroMinOut.selector && minOut == 0),
                "unexpected revert"
            );
        }
        assertEq(cbeth.balanceOf(address(route)), donation, "route cbETH changed");
        assertEq(weth.balanceOf(address(route)), donation, "route WETH changed");
        assertEq(usdc.balanceOf(address(route)), donation, "route USDC changed");
        assertEq(cbeth.allowance(address(route), address(p1)), 0);
        assertEq(cbeth.allowance(address(swapper), address(route)), 0);
    }

    // TEST-054 verifies: REQ-ROUTE-012, REQ-ROUTE-015, REQ-ROUTE-016, INV-021
    function testFuzz_TEST_054_litePsmSpendsAtMostTheDaiAndReturnsTheRest(
        uint128 daiIn,
        uint64 tout
    ) public {
        daiIn = uint128(bound(daiIn, 1, 1e30));
        MockLitePsm psm = new MockLitePsm(address(dai), address(usdc), 6);
        usdc.mint(address(psm), 1e30);
        psm.setTout(bound(tout, 0, 1e17));
        PegModuleRoute route = new PegModuleRoute(
            _config(address(dai), address(usdc)),
            PegModuleStep({
                kind: PegModuleKind.LitePsm, module: address(psm), wrapper: address(0), intermediate: address(0)
            })
        );
        dai.mint(address(swapper), daiIn);
        try swapper.swapUnderLock(route, daiIn, 1) returns (uint256 out) {
            assertEq(usdc.balanceOf(address(swapper)), out);
            assertEq(dai.balanceOf(address(swapper)) + psm.lastDaiIn(), daiIn, "DAI conserved");
            // One more gem unit would cost more than the DAI held.
            uint256 c = 1e12;
            uint256 next = (out + 1) * c;
            assertGt(next + next * psm.tout() / 1e18, daiIn);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ISettlementRoute.MinOutNotMet.selector);
            assertLt(daiIn, 1e12 + 1e12 * psm.tout() / 1e18 + 1, "reverted although one unit was affordable");
        }
        assertEq(dai.balanceOf(address(route)), 0);
        assertEq(dai.allowance(address(route), address(psm)), 0);
    }
}
