// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {MarketRegistryRoutesHandler} from "./handlers/MarketRegistryRoutesHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @title MarketRegistryRoutesInvariantTest
/// @notice Swap-route slots under random set, disable and restore calls by the timelock and a guardian: every outcome
/// matches the model, the two slots of a (market, token, asset) never hold the same route or two routes through a
/// common venue, a restore never brings back a route the slot did not approve before, and a guardian changes nothing.
contract MarketRegistryRoutesInvariantTest is Test {
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

    // TEST-054 verifies: REQ-CONFIG-060, REQ-CONFIG-061, REQ-CONFIG-062, REQ-MREG-012, REQ-MREG-014, Q-151
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
