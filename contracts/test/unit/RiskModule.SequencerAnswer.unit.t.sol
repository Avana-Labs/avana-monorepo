// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

/// @title RiskModuleSequencerAnswerUnitTest
/// @notice The length handling of the sequencer-uptime read (REQ-RISK-081): the RiskModule copies at most the 160
/// bytes of `latestRoundData()` and decodes those; a shorter answer is down, and an oversized one costs the read no
/// more than a 160-byte answer.
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
    function measureBorrowCheck() external returns (uint256 used) {
        uint256 before = gasleft();
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        used = before - gasleft();
    }

    // TEST-275 verifies: REQ-RISK-081
    /// @notice The gate reads the first 160 bytes: a round reporting up passes and one reporting down reverts
    /// `SequencerDown`, whether or not words follow it; an answer one byte short of a round is down.
    function test_TEST_275_sequencerReadsTheRoundPrefix() public {
        _answer(_round(0));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        _answer(abi.encodePacked(_round(0), uint256(1)));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        _answer(abi.encodePacked(_round(1), uint256(0)));
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
    /// @notice A 1 MB answer whose first 160 bytes report up costs the borrow check exactly what a 192-byte answer
    /// costs: the read copies at most one round, whatever the answer's length. Above a 160-byte answer it pays only
    /// the constant truncation step (5 gas optimized, 8 under coverage instrumentation), bounded here by 32.
    function test_TEST_275_oversizedSequencerAnswerBoundedCost() public {
        _answer(_round(0));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        uint256 roundGas = this.measureBorrowCheck();
        bytes memory huge = new bytes(1 << 20);
        bytes memory round = _round(0);
        for (uint256 i = 0; i < ROUND_LENGTH; ++i) {
            huge[i] = round[i];
        }
        _answer(abi.encodePacked(round, uint256(0)));
        uint256 longerGas = this.measureBorrowCheck();
        _answer(huge);
        uint256 hugeGas = this.measureBorrowCheck();
        emit log_named_uint("borrow check gas, 160-byte sequencer answer", roundGas);
        emit log_named_uint("borrow check gas, 192-byte sequencer answer", longerGas);
        emit log_named_uint("borrow check gas, 1 MB sequencer answer", hugeGas);
        assertEq(hugeGas, longerGas, "cost independent of the answer's length");
        assertLe(hugeGas, roundGas + 32, "only the constant truncation step above a 160-byte answer");
    }
}
