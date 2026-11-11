// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {MockCLPool, MockCurvePool} from "../utils/mocks/SwapRouteMocks.sol";
import {DexPathRouteHandler} from "./handlers/DexPathRouteHandler.sol";

/// @title DexPathRouteInvariantTest
/// @notice REQ-ROUTE-016 and REQ-ROUTE-014 over random sequences on a two-hop route: after every call the route holds
/// exactly what was donated to it (every call ends with no change in its balance of any token, so a residue or an
/// output never stays and a donation never counts), it has no allowance outstanding to either pool, every successful
/// swap returned exactly LPVaultSwap's measured rise of the debt asset, and no swap moved more of LPVaultSwap's input
/// than it asked for (a reverted swap moved none).
contract DexPathRouteInvariantTest is SwapRouteFixture {
    DexPathRouteHandler internal handler;
    DexPathRoute internal route;
    MockCLPool internal p1;
    MockCurvePool internal p2;

    function setUp() public override {
        super.setUp();
        p1 = _clPool(cbeth, weth, 1, 1);
        p2 = _curvePool(weth, usdc, 3000e6, 1e18);
        route = new DexPathRoute(
            _config(address(cbeth), address(usdc)),
            _hops2(_clHop(address(p1), address(weth)), _curveHop(address(p2), address(usdc), 0, 1))
        );
        handler = new DexPathRouteHandler(route, swapper, p1, p2, cbeth, weth, usdc);
        targetContract(address(handler));
    }

    // TEST-054 verifies: REQ-ROUTE-016, REQ-ROUTE-015, INV-021
    // Sources: 2.12 REQ-ROUTE-016 (no change in the route's balance of any token over a call)
    function invariant_TEST_054_routeHoldsOnlyDonations() public view {
        assertEq(cbeth.balanceOf(address(route)), handler.donated(address(cbeth)), "cbETH");
        assertEq(weth.balanceOf(address(route)), handler.donated(address(weth)), "WETH");
        assertEq(usdc.balanceOf(address(route)), handler.donated(address(usdc)), "USDC");
    }

    // TEST-054 verifies: REQ-ROUTE-010, REQ-ROUTE-016
    // Sources: 2.12 REQ-ROUTE-010 (allowance reset to 0 after each leg)
    function invariant_TEST_054_noAllowanceOutstanding() public view {
        assertEq(cbeth.allowance(address(route), address(p1)), 0);
        assertEq(weth.allowance(address(route), address(p2)), 0);
        assertEq(cbeth.allowance(address(swapper), address(route)), 0, "LPVaultSwap's allowance reset");
    }

    // TEST-232 verifies: REQ-ROUTE-009, REQ-ROUTE-014, REQ-ROUTE-008
    // Sources: 2.12 REQ-ROUTE-014 (the returned out is LPVaultSwap's balance rise)
    function invariant_TEST_232_outputIsTheMeasuredRise() public view {
        assertEq(handler.outMismatches(), 0, "returned output differs from the rise");
        assertEq(handler.inputMismatches(), 0, "input moved beyond the request");
    }
}
