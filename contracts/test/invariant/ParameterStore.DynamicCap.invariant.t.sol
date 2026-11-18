// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {ParameterStoreDynamicCapHandler} from "./handlers/ParameterStoreDynamicCapHandler.sol";

/// @title ParameterStoreDynamicCapInvariantTest
/// @notice Dynamic borrow cap tightenings and loosenings by the timelock, the Joint Configuration Safe and a stranger,
/// starting from never-written values, under random sequences. After every call: the stored value is all zero or within
/// its bounds; no write moved a value against its setter's direction; the steward never loosened; the stranger never
/// wrote.
contract ParameterStoreDynamicCapInvariantTest is ParameterStoreFixture, HandlerReach {
    ParameterStoreDynamicCapHandler internal handler;
    address internal safe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore();
        _listMarket();
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_RISK_STEWARD, safe);
        handler = new ParameterStoreDynamicCapHandler(store, address(timelock), safe, M);
        targetContract(address(handler));
    }

    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(
            address(handler), actions, ParameterStoreDynamicCapHandler.Skipped.selector, 32, 50, 0, own, true
        );
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](1);
        bool[] memory check = new bool[](1);
        floors[0] = 50; // market
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
        (actions, names, kinds) = (new bytes4[](1), new string[](1), new int16[][](1));
        (actions[0], names[0]) = (ParameterStoreDynamicCapHandler.market.selector, "market");
        kinds[0] = new int16[](3);
        kinds[0][0] = 256;
        kinds[0][1] = 8;
        kinds[0][2] = 1;
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

    function invariant_valuesZeroOrWithinBounds() public view {
        MarketDynamicCap memory m = store.marketDynamicCap(M);
        if (m.capInterval != 0) {
            assertTrue(m.capInterval >= 3600 && m.capInterval <= 604_800, "interval");
            assertLe(m.capAlphaBps, 10_000);
            assertLe(m.capBufferMin, m.capBufferMax);
        } else {
            assertEq(abi.encode(m), abi.encode(MarketDynamicCap(0, 0, 0, 0)), "never written is all zero");
        }
    }

    function invariant_directionsAndRoles() public view {
        assertEq(handler.wrongDirection(), 0, "a value moved against its setter");
        assertEq(handler.stewardLoosenings(), 0, "the steward loosened");
        assertEq(handler.strangerWrites(), 0, "a stranger wrote");
    }
}
