// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {MarketRegistryStopsHandler} from "./handlers/MarketRegistryStopsHandler.sol";
import {Test} from "forge-std/Test.sol";

/// @title MarketRegistryStopsInvariantTest
/// @notice Address freezes and breakers under random guardian, admin, stranger and RiskModule calls with time warps:
/// every outcome matches the model, no caller ever holds more than 20 freezes in its 24 hour buckets, no protected
/// address is ever frozen, latches hold only security and manual reasons, and the breach time is never in the future.
contract MarketRegistryStopsInvariantTest is Test, HandlerReach {
    MarketRegistryStopsHandler internal handler;
    MarketRegistry internal registry;

    function setUp() public {
        handler = new MarketRegistryStopsHandler();
        handler.init();
        registry = handler.reg();
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](10);
        actions[0] = MarketRegistryStopsHandler.freezeAddress.selector;
        actions[1] = MarketRegistryStopsHandler.freezeAddress.selector;
        actions[2] = MarketRegistryStopsHandler.freezeAddress.selector;
        actions[3] = MarketRegistryStopsHandler.unfreezeAddress.selector;
        actions[4] = MarketRegistryStopsHandler.recordBreach.selector;
        actions[5] = MarketRegistryStopsHandler.trip.selector;
        actions[6] = MarketRegistryStopsHandler.setLive.selector;
        actions[7] = MarketRegistryStopsHandler.reset.selector;
        actions[8] = MarketRegistryStopsHandler.reset.selector;
        actions[9] = MarketRegistryStopsHandler.warp.selector;
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
        _check(r, names, new string[](0), _floors(7, 0), new uint256[](0));
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
        (actions, names, kinds) = (new bytes4[](7), new string[](7), new int16[][](7));
        (actions[0], names[0]) = (MarketRegistryStopsHandler.freezeAddress.selector, "freezeAddress");
        kinds[0] = new int16[](3);
        kinds[0][0] = 256;
        kinds[0][1] = 256;
        kinds[0][2] = 1;
        (actions[1], names[1]) = (MarketRegistryStopsHandler.unfreezeAddress.selector, "unfreezeAddress");
        kinds[1] = new int16[](2);
        kinds[1][0] = 256;
        kinds[1][1] = 256;
        (actions[2], names[2]) = (MarketRegistryStopsHandler.recordBreach.selector, "recordBreach");
        kinds[2] = new int16[](2);
        kinds[2][0] = 1;
        kinds[2][1] = 32;
        (actions[3], names[3]) = (MarketRegistryStopsHandler.trip.selector, "trip");
        kinds[3] = new int16[](2);
        kinds[3][0] = 256;
        kinds[3][1] = 1;
        (actions[4], names[4]) = (MarketRegistryStopsHandler.setLive.selector, "setLive");
        kinds[4] = new int16[](2);
        kinds[4][0] = 1;
        kinds[4][1] = 32;
        (actions[5], names[5]) = (MarketRegistryStopsHandler.reset.selector, "reset");
        kinds[5] = new int16[](2);
        kinds[5][0] = 256;
        kinds[5][1] = 1;
        (actions[6], names[6]) = (MarketRegistryStopsHandler.warp.selector, "warp");
        kinds[6] = new int16[](1);
        kinds[6][0] = 256;
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

    // TEST-229 verifies: REQ-MREG-019, REQ-MREG-020, REQ-MREG-022, INV-085, ATTACK-139, Q-242
    // Sources: 5.1 TEST-229
    function invariant_TEST_229_freezeOutcomesFollowTheModel() public view {
        assertEq(handler.outcomeMismatch(), 0, "a freeze, unfreeze, trip or reset outcome against the model");
        assertEq(handler.frozenMismatch(), 0, "a frozen flag differs from the model");
    }

    // TEST-229 verifies: REQ-MREG-019, INV-085, ATTACK-132, ATTACK-139
    // The registry's own window count never exceeds 20 for any caller and equals the model's.
    function invariant_TEST_229_noCallerExceedsTwentyFreezes() public view {
        for (uint256 i = 0; i < handler.ACTORS(); ++i) {
            address a = handler.actor(i);
            uint256 n = registry.freezesInWindow(a);
            assertLe(n, registry.MAX_ADDRESS_FREEZES_PER_DAY(), "more than 20 freezes in the window");
            assertEq(n, handler.windowCount(a), "window count differs from the model");
        }
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085
    function invariant_TEST_229_protectedSetNeverFrozen() public view {
        assertEq(handler.protectedFrozen(), 0, "a protected address was frozen");
        for (uint256 i = 0; i < handler.protectedCount(); ++i) {
            assertFalse(registry.isFrozenAddress(handler.protectedAt(i)), "protected address frozen");
        }
    }

    // TEST-228 verifies: REQ-MREG-025, REQ-MREG-026, SPEC-BRK-007, SPEC-BRK-008, Q-399
    // Sources: 5.1 TEST-228
    function invariant_TEST_228_latchesHoldOnlySecurityAndManual() public view {
        assertEq(handler.latchMismatch(), 0, "a latch or breach time differs from the model");
        uint32 allowed = BreakerReasons.SECURITY | BreakerReasons.MANUAL;
        (uint32 m, uint64 mt) = registry.marketBreaker(handler.marketId());
        (uint32 d, uint64 dt) = registry.debtBreaker(handler.spokeOf(), 0);
        assertEq(m & ~allowed, 0, "market latch holds another reason");
        assertEq(d & ~allowed, 0, "debt latch holds another reason");
        assertLe(mt, block.timestamp, "market breach time in the future");
        assertLe(dt, block.timestamp, "debt breach time in the future");
    }
}
