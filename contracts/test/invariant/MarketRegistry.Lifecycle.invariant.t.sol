// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {WindDownState} from "../../src/policy/market-registry/types/WindDownState.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {MarketRegistryLifecycleHandler} from "./handlers/MarketRegistryLifecycleHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @title MarketRegistryLifecycleInvariantTest
/// @notice Market lifecycle under random list, relist, activate, cancel, offboard, wind-down step and close calls
/// with time warps: every call follows the status machine, the reverse maps hold exactly the live markets, the Spoke's
/// live count matches, identifiers are consecutive and reused only by a relisting, and the wind-down threshold stays
/// between its final value and its start.
contract MarketRegistryLifecycleInvariantTest is Test, HandlerReach {
    MarketRegistryLifecycleHandler internal handler;
    MarketRegistry internal registry;

    function setUp() public {
        handler = new MarketRegistryLifecycleHandler();
        handler.init();
        registry = handler.reg();
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](10);
        actions[0] = MarketRegistryLifecycleHandler.list.selector;
        actions[1] = MarketRegistryLifecycleHandler.list.selector;
        actions[2] = MarketRegistryLifecycleHandler.activate.selector;
        actions[3] = MarketRegistryLifecycleHandler.activate.selector;
        actions[4] = MarketRegistryLifecycleHandler.cancel.selector;
        actions[5] = MarketRegistryLifecycleHandler.offboard.selector;
        actions[6] = MarketRegistryLifecycleHandler.offboard.selector;
        actions[7] = MarketRegistryLifecycleHandler.warp.selector;
        actions[8] = MarketRegistryLifecycleHandler.close.selector;
        actions[9] = MarketRegistryLifecycleHandler.warp.selector;
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
        Reach memory r = _replayLanded(
            address(handler), actions, MarketRegistryLifecycleHandler.Skipped.selector, 32, 50, 0, own, true
        );
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](6);
        bool[] memory check = new bool[](6);
        floors[0] = 50; // list
        floors[1] = 15; // activate
        floors[2] = 15; // cancel
        floors[3] = 5; // offboard
        floors[4] = 80; // warp
        check[4] = true; // warp
        floors[5] = 15; // close
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
        (actions[0], names[0]) = (MarketRegistryLifecycleHandler.list.selector, "list");
        kinds[0] = new int16[](1);
        kinds[0][0] = 256;
        (actions[1], names[1]) = (MarketRegistryLifecycleHandler.activate.selector, "activate");
        kinds[1] = new int16[](1);
        kinds[1][0] = 256;
        (actions[2], names[2]) = (MarketRegistryLifecycleHandler.cancel.selector, "cancel");
        kinds[2] = new int16[](1);
        kinds[2][0] = 256;
        (actions[3], names[3]) = (MarketRegistryLifecycleHandler.offboard.selector, "offboard");
        kinds[3] = new int16[](2);
        kinds[3][0] = 256;
        kinds[3][1] = 16;
        (actions[4], names[4]) = (MarketRegistryLifecycleHandler.warp.selector, "warp");
        kinds[4] = new int16[](1);
        kinds[4][0] = 256;
        (actions[5], names[5]) = (MarketRegistryLifecycleHandler.close.selector, "close");
        kinds[5] = new int16[](2);
        kinds[5][0] = 256;
        kinds[5][1] = 1;
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

    function _slot(
        uint256 i
    ) internal view returns (MarketRegistryLifecycleHandler.Slot memory) {
        return handler.slot(i);
    }

    // TEST-213 verifies: REQ-CONFIG-042, REQ-CONFIG-048, REQ-MREG-015, REQ-CONFIG-080, REQ-MREG-030, Q-227, Q-355
    // Sources: 5.1 TEST-213, TEST-252
    function invariant_TEST_213_everyCallFollowsTheStatusMachine() public view {
        assertEq(handler.outcomeMismatch(), 0, "a transition succeeded or failed against the model");
        assertEq(handler.statusMismatch(), 0, "a status differs from the model");
        assertEq(handler.idMismatch(), 0, "an identifier was not the next one or not the reserved one");
    }

    // TEST-252 verifies: REQ-CONFIG-007, REQ-CONFIG-048, REQ-MREG-030
    // Each reverse map holds a market while it is Registered, Active or Offboarding, and no Cancelled market.
    function invariant_TEST_252_reverseMapsHoldExactlyTheLiveMarkets() public view {
        address spoke = handler.spokeAddr();
        address hub = handler.hubAddr();
        for (uint256 i = 0; i < handler.SHAPES(); ++i) {
            MarketRegistryLifecycleHandler.Slot memory s = _slot(i);
            if (s.id == 0) continue;
            bytes32 key = handler.keyOf(i);
            bool live = s.status == MarketStatus.Registered || s.status == MarketStatus.Active
                || s.status == MarketStatus.Offboarding;
            if (live) {
                assertEq(registry.marketOfKey(key), s.id, "key of a live market");
                assertEq(registry.marketOfVaultToken(s.vaultToken), s.id, "token of a live market");
                assertEq(registry.marketOfLpOracle(s.lpOracle), s.id, "LPOracle of a live market");
            }
            if (s.status == MarketStatus.Cancelled) {
                assertEq(registry.marketOfKey(key), 0, "key of a cancelled market");
                assertEq(registry.marketOfVaultToken(s.vaultToken), 0, "token of a cancelled market");
                assertEq(registry.marketOfLpOracle(s.lpOracle), 0, "LPOracle of a cancelled market");
            }
            if (s.status == MarketStatus.Active || s.status == MarketStatus.Offboarding) {
                assertEq(registry.marketOfHubAsset(hub, handler.assetOf(i)), s.id, "Hub asset of a live market");
                assertEq(registry.marketOfReserve(spoke, handler.assetOf(i)), s.id, "reserve of a live market");
            }
        }
    }

    // TEST-213 verifies: REQ-MREG-031, REQ-CONFIG-006
    function invariant_TEST_213_countsMatchTheMarkets() public view {
        uint256 live = 0;
        uint256 ids = 0;
        for (uint256 i = 0; i < handler.SHAPES(); ++i) {
            MarketRegistryLifecycleHandler.Slot memory s = _slot(i);
            if (s.id == 0) continue;
            ++ids;
            assertLe(s.id, registry.marketCount(), "identifier within the count");
            if (s.status == MarketStatus.Active || s.status == MarketStatus.Offboarding) ++live;
        }
        assertEq(registry.activeMarketCount(handler.spokeAddr()), live, "Active and Offboarding markets");
        assertEq(registry.marketCount(), ids, "one identifier per listed shape");
        assertEq(registry.marketsOfSpoke(handler.spokeAddr()).length, ids, "each market once in the Spoke list");
    }

    // TEST-213 verifies: REQ-CONFIG-080, Q-355
    function invariant_TEST_213_offboardingTargetIsPublished() public view {
        assertEq(handler.ltMismatch(), 0, "a published target differs from half the start");
        for (uint256 i = 0; i < handler.SHAPES(); ++i) {
            MarketRegistryLifecycleHandler.Slot memory s = _slot(i);
            if (s.status != MarketStatus.Offboarding && s.status != MarketStatus.Closed) continue;
            WindDownState memory w = handler.windDownOf(i);
            assertEq(w.targetLtBps, uint256(w.startLtBps) * 5000 / 10_000, "the target is half the start");
            assertEq(w.unusedLastStepAt, 0, "the former ramp field stays 0");
        }
    }

    // TEST-138 verifies: REQ-CONFIG-008, REQ-CONFIG-009, REQ-CONFIG-010, ATTACK-005, ATTACK-033
    // Sources: 5.1 TEST-138
    // No sequence of lifecycle calls changes a market's identity fields after listing, or its Hub asset and Spoke
    // reserve after activation; a relisting writes the same identity back.
    function invariant_TEST_138_marketIdentityNeverChanges() public view {
        assertEq(handler.identityChanged(), 0, "a relisting wrote another identity");
        for (uint256 i = 0; i < handler.SHAPES(); ++i) {
            MarketRegistryLifecycleHandler.Slot memory s = _slot(i);
            if (s.id == 0) continue;
            (bytes32 listing, bytes32 reserve) = handler.identityAt(i);
            assertEq(handler.identityOf(s.id), listing, "identity fields changed");
            if (
                s.status == MarketStatus.Active || s.status == MarketStatus.Offboarding
                    || s.status == MarketStatus.Closed
            ) {
                assertEq(handler.reserveIdentityOf(s.id), reserve, "Hub asset or reserve changed after activation");
            }
        }
    }
}
