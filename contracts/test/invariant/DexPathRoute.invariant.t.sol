// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {SwapRouteFixture} from "../utils/fixtures/SwapRouteFixture.sol";
import {MockCLPool, MockCurvePool} from "../utils/mocks/SwapRouteMocks.sol";
import {DexPathRouteHandler} from "./handlers/DexPathRouteHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title DexPathRouteInvariantTest
/// @notice REQ-ROUTE-016 and REQ-ROUTE-014 over random sequences on a two-hop route: after every call the route holds
/// exactly what was donated to it (every call ends with no change in its balance of any token, so a residue or an
/// output never stays and a donation never counts), it has no allowance outstanding to either pool, every successful
/// swap returned exactly LPVaultSwap's measured rise of the debt asset, and no swap moved more of LPVaultSwap's input
/// than it asked for (a reverted swap moved none).
contract DexPathRouteInvariantTest is SwapRouteFixture, HandlerReach {
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

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, bytes4(0), 32, 50, 0, own, true);
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](6);
        bool[] memory check = new bool[](6);
        floors[0] = 80; // donate
        floors[1] = 80; // setMaxIn
        floors[2] = 75; // setOutputFee
        floors[3] = 80; // setRate1
        floors[4] = 80; // setRate2
        floors[5] = 80; // swap
        _check(r, names, new string[](0), floors, new uint256[](0), check);
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](6), new string[](6), new int16[][](6));
        (actions[0], names[0]) = (DexPathRouteHandler.donate.selector, "donate");
        kinds[0] = new int16[](2);
        kinds[0][0] = 256;
        kinds[0][1] = 256;
        (actions[1], names[1]) = (DexPathRouteHandler.setMaxIn.selector, "setMaxIn");
        kinds[1] = new int16[](1);
        kinds[1][0] = 256;
        (actions[2], names[2]) = (DexPathRouteHandler.setOutputFee.selector, "setOutputFee");
        kinds[2] = new int16[](1);
        kinds[2][0] = 256;
        (actions[3], names[3]) = (DexPathRouteHandler.setRate1.selector, "setRate1");
        kinds[3] = new int16[](1);
        kinds[3][0] = 256;
        (actions[4], names[4]) = (DexPathRouteHandler.setRate2.selector, "setRate2");
        kinds[4] = new int16[](1);
        kinds[4][0] = 256;
        (actions[5], names[5]) = (DexPathRouteHandler.swap.selector, "swap");
        kinds[5] = new int16[](1);
        kinds[5][0] = 256;
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
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
