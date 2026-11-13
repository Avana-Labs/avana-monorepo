// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaTimelockErrors} from "../../src/governance/timelock/IAvanaTimelockErrors.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @title ParameterStoreTimelockRowsUnitTest
/// @notice The real ParameterStore driven through the real AvanaTimelock (launch short-delay list naming the store):
/// the `minPledgeUsd` setters' delays and rules (TEST-196) and the store selectors of the timelock's short list
/// resolving on the deployed store (TEST-244).
contract ParameterStoreTimelockRowsUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _scheduleAndWait(
        Call[] memory calls,
        uint256 delay,
        bytes32 salt
    ) internal {
        _schedule(governanceMultisig, calls, delay, salt);
        vm.warp(block.timestamp + delay);
    }

    // TEST-196 verifies: REQ-PSTORE-005, REQ-RISK-057, REQ-ACCESS-146
    // Sources: 5.1 TEST-196 (ParameterStore and timelock side)
    /// @notice `tightenMinPledgeUsd` is on the short-delay list and takes effect after 43,200 s; it refuses a lower
    /// value (`NotStricter`) and one above 100,000e8 (`OutOfBounds`) at execution. `loosenMinPledgeUsd` needs the
    /// normal delay (scheduling it at the short delay reverts `DelayBelowRequired`), lowers the value, and refuses a
    /// higher one (`NotLooser`).
    function test_TEST_196_minPledgeSettersThroughTheTimelock() public {
        uint256 start = store.minPledgeUsd(M);
        Call[] memory up = _one(address(store), abi.encodeCall(store.tightenMinPledgeUsd, (M, 20e8)));
        assertEq(_required(up), SHORT_DELAY, "tighten is short-delay");
        _run(up, bytes32("up"));
        assertEq(store.minPledgeUsd(M), 20e8, "raised after the short delay");

        Call[] memory lower = _one(address(store), abi.encodeCall(store.tightenMinPledgeUsd, (M, 15e8)));
        _scheduleAndWait(lower, SHORT_DELAY, bytes32("lower"));
        vm.expectRevert(IParameterStoreErrors.NotStricter.selector);
        _execute(attacker, lower, bytes32("lower"));
        Call[] memory huge = _one(address(store), abi.encodeCall(store.tightenMinPledgeUsd, (M, 100_000e8 + 1)));
        _scheduleAndWait(huge, SHORT_DELAY, bytes32("huge"));
        vm.expectRevert(IParameterStoreErrors.OutOfBounds.selector);
        _execute(attacker, huge, bytes32("huge"));
        assertEq(store.minPledgeUsd(M), 20e8, "refused writes change nothing");

        Call[] memory down = _one(address(store), abi.encodeCall(store.loosenMinPledgeUsd, (M, 10e8)));
        assertEq(_required(down), NORMAL_DELAY, "loosen needs the normal delay");
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(down);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaTimelockErrors.DelayBelowRequired.selector, SHORT_DELAY, NORMAL_DELAY)
        );
        vm.prank(governanceMultisig);
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32("short"), SHORT_DELAY);
        _run(down, bytes32("down"));
        assertEq(store.minPledgeUsd(M), 10e8, "lowered after the normal delay");
        Call[] memory higher = _one(address(store), abi.encodeCall(store.loosenMinPledgeUsd, (M, 30e8)));
        _scheduleAndWait(higher, NORMAL_DELAY, bytes32("higher"));
        vm.expectRevert(IParameterStoreErrors.NotLooser.selector);
        _execute(attacker, higher, bytes32("higher"));
        assertTrue(start != 20e8, "the run moved the value");
    }

    // TEST-244 verifies: REQ-ACCESS-146, SPEC-GOV-008
    // Sources: 5.1 TEST-244 (ParameterStore side), Q-262
    /// @notice `SHORT_ELIGIBLE` names `tightenFloorRoundingAllowance` and `tightenMaxFlashFeeBps` on the deployed
    /// ParameterStore, and the name resolves to a selector of that contract: `tightenMaxFlashFeeBps` scheduled at the
    /// short delay executes on the real store and writes the value.
    function test_TEST_244_shortListedStoreSelectorsRunOnTheDeployedStore() public {
        assertTrue(
            timelock.isShortEligible(address(store), IParameterStoreTighten.tightenFloorRoundingAllowance.selector),
            "tightenFloorRoundingAllowance is short-eligible"
        );
        assertTrue(
            timelock.isShortEligible(address(store), IParameterStoreAdmin.tightenMaxFlashFeeBps.selector),
            "tightenMaxFlashFeeBps is short-eligible"
        );
        uint16 before = store.maxFlashFeeBps();
        uint16 next = before - 1;
        Call[] memory c = _one(address(store), abi.encodeCall(IParameterStoreAdmin.tightenMaxFlashFeeBps, (next)));
        assertEq(_required(c), SHORT_DELAY, "short delay");
        _run(c, bytes32("flash"));
        assertEq(store.maxFlashFeeBps(), next, "the selector ran on the deployed store");
    }
}
