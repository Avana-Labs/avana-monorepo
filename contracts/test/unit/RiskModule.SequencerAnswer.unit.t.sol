// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

/// @title RiskModuleSequencerAnswerUnitTest
/// @notice The length handling of the sequencer-uptime read (REQ-RISK-081): the RiskModule accepts only an answer of
/// exactly 160 bytes, the five words of `latestRoundData()`; a shorter or longer answer is down, and an oversized one
/// costs the read no more than a 161-byte answer, since at most 161 bytes are copied.
contract RiskModuleSequencerAnswerUnitTest is RiskModuleFixture {
    uint256 internal constant ROUND_LENGTH = 160;
    RiskSequencerFeed internal feed;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
        feed = new RiskSequencerFeed();
        store.setSequencer(address(feed), 3600);
    }

    /// @dev `latestRoundData()` words (roundId, answer, startedAt, updatedAt, answeredInRound), restarted long ago.
    function _round(
        int256 answer
    ) internal pure returns (bytes memory) {
        return abi.encode(uint80(1), answer, uint256(1), uint256(1), uint80(1));
    }

    function _answer(
        bytes memory data
    ) internal {
        vm.clearMockedCalls();
        vm.mockCall(address(feed), abi.encodeCall(RiskSequencerFeed.latestRoundData, ()), data);
    }

    /// @notice External entry run in its own frame, so the test's memory, grown by a 1 MB answer, does not price it.
    /// The borrow check reverts `SequencerDown` on an answer that is not 160 bytes; the gas it used is measured either
    /// way, and `down` says whether it reverted with `SequencerDown`.
    function measureBorrowCheck() external returns (uint256 used, bool down) {
        uint256 before = gasleft();
        try riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1) {}
        catch (bytes memory reason) {
            down = keccak256(reason) == keccak256(abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector));
        }
        used = before - gasleft();
    }

    // TEST-275 verifies: REQ-RISK-081
    /// @notice The gate accepts exactly 160 bytes: a round reporting up passes and one reporting down reverts
    /// `SequencerDown`; an up round followed by one more byte or one more word, or one byte short of a round, is down.
    /// The answers of 161 and 192 bytes pass on a read that copies only 160 bytes (`maxLength = ROUND_LENGTH`), so
    /// this test kills the `+ 1` of `RiskModuleBase._sequencerState`.
    function test_TEST_275_sequencerRequiresExactRound() public {
        _answer(_round(0));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        _answer(abi.encodePacked(_round(1)));
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        _answer(abi.encodePacked(_round(0), uint8(0)));
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        _answer(abi.encodePacked(_round(0), uint256(0)));
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        bytes memory round = _round(0);
        bytes memory short = new bytes(ROUND_LENGTH - 1);
        for (uint256 i = 0; i < short.length; ++i) {
            short[i] = round[i];
        }
        _answer(short);
        vm.expectRevert(IRiskModuleErrors.SequencerDown.selector);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-275 verifies: REQ-RISK-081
    /// @notice A 1 MB answer whose first 160 bytes report up is down, and costs the borrow check exactly what a
    /// 192-byte answer costs: the read copies at most 161 bytes, whatever the answer's length. Both pay the constant
    /// truncation step a 161-byte answer does not (5 gas optimized, 8 under coverage instrumentation).
    function test_TEST_275_oversizedSequencerAnswerBoundedCost() public {
        bytes memory round = _round(0);
        _answer(abi.encodePacked(round, uint256(0)));
        this.measureBorrowCheck();
        (uint256 longerGas, bool longerDown) = this.measureBorrowCheck();
        bytes memory huge = new bytes(1 << 20);
        for (uint256 i = 0; i < ROUND_LENGTH; ++i) {
            huge[i] = round[i];
        }
        _answer(huge);
        (uint256 hugeGas, bool hugeDown) = this.measureBorrowCheck();
        emit log_named_uint("borrow check gas, 192-byte sequencer answer", longerGas);
        emit log_named_uint("borrow check gas, 1 MB sequencer answer", hugeGas);
        assertTrue(longerDown && hugeDown, "a longer answer is down");
        assertEq(hugeGas, longerGas, "cost independent of the answer's length");
    }
}
