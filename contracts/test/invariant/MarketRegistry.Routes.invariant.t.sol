// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {MarketRegistryRoutesHandler} from "./handlers/MarketRegistryRoutesHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @title MarketRegistryRoutesInvariantTest
/// @notice Swap-route slots under random set, disable and restore calls by the timelock and a guardian: every outcome
/// matches the model, the two slots of a (market, token, asset) never hold the same route or two routes through a
/// common venue, a restore never brings back a route the slot did not approve before, and a guardian changes nothing.
contract MarketRegistryRoutesInvariantTest is Test, HandlerReach {
    MarketRegistryRoutesHandler internal handler;
    MarketRegistry internal registry;

    function setUp() public {
        handler = new MarketRegistryRoutesHandler();
        handler.init();
        registry = handler.reg();
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](4);
        actions[0] = MarketRegistryRoutesHandler.setRoute.selector;
        actions[1] = MarketRegistryRoutesHandler.setRoute.selector;
        actions[2] = MarketRegistryRoutesHandler.disableRoute.selector;
        actions[3] = MarketRegistryRoutesHandler.restoreRoute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
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
        uint256[] memory floors = new uint256[](3);
        bool[] memory check = new bool[](3);
        floors[0] = 25; // setRoute
        floors[1] = 15; // disableRoute
        floors[2] = 5; // restoreRoute
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
        (actions, names, kinds) = (new bytes4[](3), new string[](3), new int16[][](3));
        (actions[0], names[0]) = (MarketRegistryRoutesHandler.setRoute.selector, "setRoute");
        kinds[0] = new int16[](3);
        kinds[0][0] = 1;
        kinds[0][1] = 256;
        kinds[0][2] = 1;
        (actions[1], names[1]) = (MarketRegistryRoutesHandler.disableRoute.selector, "disableRoute");
        kinds[1] = new int16[](2);
        kinds[1][0] = 1;
        kinds[1][1] = 1;
        (actions[2], names[2]) = (MarketRegistryRoutesHandler.restoreRoute.selector, "restoreRoute");
        kinds[2] = new int16[](3);
        kinds[2][0] = 1;
        kinds[2][1] = 256;
        kinds[2][2] = 1;
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

    // TEST-054 verifies: REQ-CONFIG-060, REQ-CONFIG-061, REQ-CONFIG-062, REQ-MREG-012, REQ-MREG-014, Q-151, REQ-ROUTE-017, REQ-ROUTE-018, REQ-ROUTE-019, REQ-ROUTE-021, REQ-ROUTE-038
    // Sources: 5.1 TEST-054
    function invariant_TEST_054_everyRouteCallFollowsTheModel() public view {
        assertEq(handler.outcomeMismatch(), 0, "a route call succeeded or failed against the model");
        assertEq(handler.recordMismatch(), 0, "a slot record differs from the model");
        assertEq(handler.guardianSucceeded(), 0, "a guardian changed a route");
        assertEq(handler.restoredUnapproved(), 0, "a restore brought back a route never approved in the slot");
    }

    // TEST-054 verifies: REQ-CONFIG-060, REQ-CONFIG-039
    // The primary and the backup of a slot pair are always different contracts with no venue in common.
    function invariant_TEST_054_slotsNeverShareARouteOrVenue() public view {
        uint256 id = handler.marketId();
        (address p,) = registry.getRoute(id, handler.usdcAddr(), handler.ghoAddr(), 0);
        (address b,) = registry.getRoute(id, handler.usdcAddr(), handler.ghoAddr(), 1);
        if (p == address(0) || b == address(0)) return;
        assertTrue(p != b, "the same route in both slots");
        address[] memory dp = RegistryRouteMock(p).dependencies();
        address[] memory db = RegistryRouteMock(b).dependencies();
        for (uint256 i = 0; i < dp.length; ++i) {
            for (uint256 j = 0; j < db.length; ++j) {
                assertTrue(dp[i] != db[j], "a venue in both slots");
            }
        }
    }
}
