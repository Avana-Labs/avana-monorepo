// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaTimelockErrors} from "../../src/governance/timelock/IAvanaTimelockErrors.sol";
import {IParameterStoreAdmin} from "../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreLoosen} from "../../src/policy/parameter-store/IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title AvanaTimelockRiskChangeProcessUnitTest
/// @notice The on-chain steps of the risk-parameter change process of REQ-ACCESS-161, through the real AvanaTimelock
/// and the real ParameterStore: the batch delay set by its loosest call, the `CallScheduled` announcement and the
/// cancel window, public execution from the ready time until `GRACE_PERIOD` later, the setters' step, spacing and
/// liveness checks at execution, the band and grace values at the normal delay in both directions, and the
/// `poolRiskFactor` cut at the short delay that precedes an Aave collateral-factor cut.
contract AvanaTimelockRiskChangeProcessUnitTest is ParameterStoreFixture {
    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    // TEST-225 verifies: REQ-ACCESS-161, SPEC-GOV-001, REQ-CONFIG-053
    function test_TEST_225_oneLooseningMakesTheBatchWaitTheNormalDelay() public {
        Call memory tightenPledge =
            Call(address(store), abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (M, 20e8)));
        Call memory tightenRisk =
            Call(address(store), abi.encodeCall(IParameterStoreTighten.tightenPoolRiskFactor, (M, 3500)));
        Call memory loosen =
            Call(address(store), abi.encodeCall(IParameterStoreLoosen.loosenSlippageAllowanceBps, (M, 125)));
        assertEq(_required(_two(tightenPledge, tightenRisk)), SHORT_DELAY, "two tightenings: short delay");
        Call[] memory batch = new Call[](3);
        (batch[0], batch[1], batch[2]) = (tightenPledge, tightenRisk, loosen);
        assertEq(_required(batch), NORMAL_DELAY, "one loosening: the whole batch waits the normal delay");
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(batch);
        vm.prank(governanceMultisig);
        vm.expectRevert(
            abi.encodeWithSelector(IAvanaTimelockErrors.DelayBelowRequired.selector, SHORT_DELAY, NORMAL_DELAY)
        );
        timelock.scheduleBatch(t, v, p, bytes32(0), bytes32("mixed"), SHORT_DELAY);
        _run(batch, bytes32("mixed"));
        assertEq(store.getMarketParams(M).minPledgeUsd, 20e8, "tightening applied");
        assertEq(store.getMarketParams(M).poolRiskFactor, 3500, "risk factor applied");
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 125, "loosening applied");
    }

    // TEST-225 verifies: REQ-ACCESS-161, REQ-ACCESS-089
    function test_TEST_225_scheduledChangeIsAnnouncedAndCancellable() public {
        bytes memory data = abi.encodeCall(IParameterStoreLoosen.loosenMarketUsdCap, (M, 6_000_000e8));
        Call[] memory calls = _one(address(store), data);
        bytes32 id = _id(calls, bytes32("cap"));
        // Monitoring alerts on the operation's CallScheduled.
        vm.expectEmit(true, true, false, true, address(timelock));
        emit TimelockController.CallScheduled(id, 0, address(store), 0, data, bytes32(0), NORMAL_DELAY);
        _schedule(governanceMultisig, calls, NORMAL_DELAY, bytes32("cap"));
        // Any canceller cancels during the delay.
        vm.warp(block.timestamp + NORMAL_DELAY - 1);
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id), "cancelled");
        vm.warp(block.timestamp + 1);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, id, bytes32(uint256(1 << 2))
            )
        );
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("cap"));
        assertEq(store.marketUsdCap(M), 5_000_000e8, "cap unchanged");
    }

    // TEST-225 verifies: REQ-ACCESS-161, SPEC-GOV-013
    function test_TEST_225_anyoneExecutesUntilTheGraceEnds() public {
        Call[] memory a = _one(address(store), abi.encodeCall(IParameterStoreLoosen.loosenMarketUsdCap, (M, 6e14)));
        Call[] memory b = _one(address(store), abi.encodeCall(IParameterStoreLoosen.loosenTopUpSliceUsd, (M, 6e13)));
        bytes32 idA = _schedule(governanceMultisig, a, NORMAL_DELAY, bytes32("a"));
        bytes32 idB = _schedule(governanceMultisig, b, NORMAL_DELAY, bytes32("b"));
        uint256 readyAt = block.timestamp + NORMAL_DELAY;
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(a);
        vm.warp(readyAt - 1);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, idA, bytes32(uint256(1 << 2))
            )
        );
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("a"));
        // The last second of the grace window: any account executes.
        vm.warp(readyAt + GRACE_PERIOD - 1);
        _execute(attacker, a, bytes32("a"));
        assertEq(store.marketUsdCap(M), 6e14, "executed by anyone");
        // From readyAt + GRACE_PERIOD the operation is expired and never executes.
        vm.warp(readyAt + GRACE_PERIOD);
        assertTrue(timelock.isOperationExpired(idB), "expired");
        (t, v, p) = _arrays(b);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(IAvanaTimelockErrors.OperationExpired.selector, idB));
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("b"));
        assertEq(store.topUpSliceUsd(M), 500_000e8, "slice unchanged");
    }

    // TEST-225 verifies: REQ-ACCESS-161, SPEC-GOV-011, REQ-PSTORE-017
    function test_TEST_225_stepCheckedAgainstTheValueAtExecution() public {
        // Scheduled against 100 bps (a 25 bps step); a short-delay tightening to 60 lands first, so 125 is then
        // 65 bps above the live value and fails the step check at execution.
        Call[] memory loosen =
            _one(address(store), abi.encodeCall(IParameterStoreLoosen.loosenSlippageAllowanceBps, (M, 125)));
        _schedule(governanceMultisig, loosen, NORMAL_DELAY, bytes32("loosen"));
        _run(
            _one(address(store), abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, 60))),
            bytes32("tighten")
        );
        vm.warp(block.timestamp + NORMAL_DELAY);
        bytes32 key = keccak256(abi.encode(bytes32("slippageAllowanceBps"), bytes32(M)));
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(loosen);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreErrors.LoosenStepTooLarge.selector, key));
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("loosen"));
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 60, "tightened value kept");
    }

    // TEST-225 verifies: REQ-ACCESS-161, REQ-CONFIG-052
    function test_TEST_225_tighteningBoundedOnlyByLiveness() public {
        // 100 to 30 bps in one short-delay operation: no step limit on tightening.
        _run(
            _one(address(store), abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, 30))),
            bytes32("to30")
        );
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 30, "several steps at once");
        // Below slippageAllowanceMinBps (30) the liveness bound refuses it at execution.
        _tl();
        store.setSlippageAllowanceMinBps(M, 20);
        Call[] memory below =
            _one(address(store), abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, 19)));
        _schedule(governanceMultisig, below, SHORT_DELAY, bytes32("to19"));
        vm.warp(block.timestamp + SHORT_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(below);
        vm.prank(attacker);
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("to19"));
    }

    // TEST-225 verifies: REQ-ACCESS-161, Q-246
    function test_TEST_225_bandAndGraceWaitTheNormalDelayBothWays() public {
        bytes[6] memory data = [
            abi.encodeCall(IParameterStoreAdmin.setUsdBand, (0.95e8, 1.01e8)),
            abi.encodeCall(IParameterStoreAdmin.setUsdBand, (0.85e8, 1.05e8)),
            abi.encodeCall(IParameterStoreAdmin.setGraceDuration, (900)),
            abi.encodeCall(IParameterStoreAdmin.setGraceDuration, (3600)),
            abi.encodeCall(IParameterStoreAdmin.setGraceHealthFactor, (0.97e18)),
            abi.encodeCall(IParameterStoreAdmin.setGraceHealthFactor, (0.92e18))
        ];
        for (uint256 i = 0; i < data.length; ++i) {
            Call[] memory calls = _one(address(store), data[i]);
            assertEq(_required(calls), NORMAL_DELAY, "normal delay in either direction");
            (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
            vm.prank(governanceMultisig);
            vm.expectRevert(
                abi.encodeWithSelector(IAvanaTimelockErrors.DelayBelowRequired.selector, SHORT_DELAY, NORMAL_DELAY)
            );
            timelock.scheduleBatch(t, v, p, bytes32(0), bytes32(i), SHORT_DELAY);
            _run(calls, bytes32(i));
        }
        assertEq(store.usdBandLow(), 0.85e8, "band low");
        assertEq(store.usdBandHigh(), 1.05e8, "band high");
        assertEq(store.graceDuration(), 3600, "grace duration");
        assertEq(store.graceHealthFactor(), 0.92e18, "grace health factor");
    }

    // TEST-225 verifies: REQ-ACCESS-161, REQ-CONFIG-054
    function test_TEST_225_poolRiskFactorCutAtTheShortDelayRaiseAtTheNormal() public {
        // A collateral-factor cut: Avana tightens poolRiskFactor first, at the short delay.
        Call[] memory cut =
            _one(address(store), abi.encodeCall(IParameterStoreTighten.tightenPoolRiskFactor, (M, 3000)));
        assertEq(_required(cut), SHORT_DELAY, "cut at the short delay");
        _run(cut, bytes32("cut"));
        assertEq(store.getMarketParams(M).poolRiskFactor, 3000, "cut applied");
        // A raise goes through the either-direction setter at the normal delay.
        Call[] memory raise = _one(address(store), abi.encodeCall(IParameterStoreAdmin.setPoolRiskFactor, (M, 4000)));
        assertEq(_required(raise), NORMAL_DELAY, "raise at the normal delay");
        _run(raise, bytes32("raise"));
        assertEq(store.getMarketParams(M).poolRiskFactor, 4000, "raise applied");
    }
}
