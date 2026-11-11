// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {MockCLPool} from "../utils/mocks/SwapRouteMocks.sol";

/// @title DexPathRouteCallbacksUnitTest
/// @notice The swap callback while a two-hop concentrated-liquidity path is running (REQ-ROUTE-013, REQ-ROUTE-033): the
/// first hop's pool, a legitimate pool of the same route, calling back during the second hop is refused because the
/// stored hop names the second pool; the same pool calling back during its own hop is the payment and succeeds; a
/// stranger calling back during either hop is refused; and the route pays each pool exactly its own hop's input in
/// that hop's input token.
contract DexPathRouteCallbacksUnitTest is SwapRouteFixture {
    MockCLPool internal p1;
    MockCLPool internal p2;
    DexPathRoute internal route;

    function setUp() public override {
        super.setUp();
        p1 = _clPool(cbeth, weth, 1, 1);
        p2 = _clPool(weth, usdc, 3000e6, 1e18);
        route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _clHop(address(p2), address(usdc)))
        );
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-033, ATTACK-092
    // Sources: 2.12 REQ-ROUTE-013 (the callback reverts unless msg.sender is the pool of the hop in progress)
    /// @notice While the second hop runs, the first hop's pool calls the route's callback (from a hook on the second
    /// pool's output transfer): the callback reverts `InvalidCallback` and the whole swap reverts; without the hook the
    /// same swap pays out.
    function test_TEST_046_previousHopPoolCannotCallBackDuringTheNextHop() public {
        int256 owed = 1e18;
        // p1's input side for cbETH → WETH; the stored hop is p2's, so the sender check refuses it whatever the side.
        (int256 a0, int256 a1) = p1.token0() == address(cbeth) ? (owed, int256(-1)) : (int256(-1), owed);
        usdc.setHook(address(p1), abi.encodeCall(MockCLPool.poke, (address(route), a0, a1)));
        cbeth.mint(address(swapper), 1e18);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        swapper.swapUnderLock(route, 1e18, 1);
        usdc.setHook(address(0), "");
        assertEq(swapper.swapUnderLock(route, 1e18, 3000e6), 3000e6, "control");
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-033
    /// @notice A stranger's contract posing as a pool calls back during the first hop (from a hook on the first pool's
    /// output) and is refused; the route's balances are untouched by the attempt.
    function test_TEST_046_strangerCallbackDuringTheFirstHop() public {
        MockCLPool stranger = new MockCLPool(address(cbeth), address(weth));
        (int256 a0, int256 a1) =
            stranger.token0() == address(cbeth) ? (int256(1e18), int256(-1)) : (int256(-1), int256(1e18));
        weth.setHook(address(stranger), abi.encodeCall(MockCLPool.poke, (address(route), a0, a1)));
        cbeth.mint(address(swapper), 1e18);
        vm.expectRevert(ISettlementRoute.InvalidCallback.selector);
        swapper.swapUnderLock(route, 1e18, 1);
        assertEq(cbeth.balanceOf(address(route)), 0);
        assertEq(cbeth.balanceOf(address(swapper)), 1e18, "the input stayed with LPVaultSwap");
    }

    // TEST-046 verifies: REQ-ROUTE-013, REQ-ROUTE-010, REQ-ROUTE-016
    // Sources: 2.12 REQ-ROUTE-013 (it pays exactly the owed amount in the hop's input token, once)
    /// @notice Each pool is paid exactly its own hop's input in that hop's input token: p1 receives the cbETH and no
    /// WETH, p2 receives the WETH p1 produced and no cbETH; neither pool is paid twice and no allowance is granted.
    function testFuzz_TEST_046_eachPoolPaidItsOwnInput(
        uint256 amountIn
    ) public {
        amountIn = bound(amountIn, 1e15, 1e24);
        uint256 p1Cbeth = cbeth.balanceOf(address(p1));
        uint256 p1Weth = weth.balanceOf(address(p1));
        uint256 p2Weth = weth.balanceOf(address(p2));
        uint256 p2Cbeth = cbeth.balanceOf(address(p2));
        uint256 out = _swap(route, amountIn, 1);
        assertEq(out, amountIn * 3000e6 / 1e18, "output at p2's rate");
        assertEq(cbeth.balanceOf(address(p1)) - p1Cbeth, amountIn, "p1 paid its cbETH input");
        assertEq(p1Weth - weth.balanceOf(address(p1)), amountIn, "p1 paid out its WETH");
        assertEq(weth.balanceOf(address(p2)) - p2Weth, amountIn, "p2 paid the WETH p1 produced");
        assertEq(cbeth.balanceOf(address(p2)), p2Cbeth, "p2 never paid in cbETH");
        assertEq(p1.swaps(), 1);
        assertEq(p2.swaps(), 1);
        assertEq(cbeth.allowance(address(route), address(p1)), 0);
        assertEq(weth.allowance(address(route), address(p2)), 0);
    }
}
