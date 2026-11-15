// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {ParameterStoreSpeedHandler} from "./handlers/ParameterStoreSpeedHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title ParameterStoreSpeedInvariantTest
/// @notice TEST-325 under random sequences: speed-limit tightenings and loosenings by the timelock, the Joint
/// Configuration Safe and a stranger, starting from never-written values. After every call: each stored value is
/// all zero or within the bounds of REQ-PSTORE-035; no write moved a value against its setter's direction; the
/// steward never loosened; the stranger never wrote.
contract ParameterStoreSpeedInvariantTest is ParameterStoreFixture, HandlerReach {
    ParameterStoreSpeedHandler internal handler;
    address internal safe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore(false);
        _listMarket();
        vm.prank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_RISK_STEWARD, safe);
        handler = new ParameterStoreSpeedHandler(store, address(timelock), safe, M, address(hub), gho);
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
        Reach memory r = _replayLanded(address(handler), actions, ParameterStoreSpeedHandler.Skipped.selector, 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(2, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions() internal pure returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds) {
        (actions, names, kinds) = (new bytes4[](2), new string[](2), new int16[][](2));
        (actions[0], names[0]) = (ParameterStoreSpeedHandler.debt.selector, "debt");
        kinds[0] = new int16[](3);
        kinds[0][0] = 256;
        kinds[0][1] = 8;
        kinds[0][2] = 1;
        (actions[1], names[1]) = (ParameterStoreSpeedHandler.market.selector, "market");
        kinds[1] = new int16[](3);
        kinds[1][0] = 256;
        kinds[1][1] = 8;
        kinds[1][2] = 1;
    }

    function _calldata(bytes4 selector, uint256 seed) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }

    // TEST-325 verifies: REQ-PSTORE-035, REQ-RISK-096
    function invariant_TEST_325_valuesZeroOrWithinBounds() public view {
        MarketSpeedLimits memory m = store.marketSpeedLimits(M);
        if (m.window != 0) {
            assertTrue(m.window >= 3600 && m.window <= 604_800, "market window");
            assertLe(m.borrowRateBps, 10_000);
            assertLe(m.pledgeRateBps, 10_000);
            assertLe(m.borrowMinUsd, m.borrowMaxUsd);
            assertLe(m.pledgeMinUsd, m.pledgeMaxUsd);
        } else {
            assertEq(abi.encode(m), abi.encode(MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0)), "never written is all zero");
        }
        SpeedLimit memory d = store.debtSpeedLimit(address(hub), gho);
        if (d.window != 0) {
            assertTrue(d.window >= 3600 && d.window <= 604_800, "debt window");
            assertLe(d.rateBps, 10_000);
            assertLe(d.min, d.max);
        } else {
            assertEq(abi.encode(d), abi.encode(SpeedLimit(0, 0, 0, 0)));
        }
    }

    // TEST-325 verifies: REQ-PSTORE-036, REQ-PSTORE-002, REQ-CONFIG-049
    function invariant_TEST_325_directionsAndRoles() public view {
        assertEq(handler.wrongDirection(), 0, "a value moved against its setter");
        assertEq(handler.stewardLoosenings(), 0, "the steward loosened");
        assertEq(handler.strangerWrites(), 0, "a stranger wrote");
    }
}
