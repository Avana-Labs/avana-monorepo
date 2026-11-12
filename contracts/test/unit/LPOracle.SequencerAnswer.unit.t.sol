// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {LPOracleFixture} from "../utils/fixtures/LPOracleFixture.sol";
import {OracleFeedMock} from "../utils/mocks/LPOracleMocks.sol";

/// @title LPOracleSequencerAnswerUnitTest
/// @notice The length handling of the LPOracle's sequencer-uptime read (`SPEC-ORC-021`, `REQ-ORACLE-099`): only an
/// answer of exactly 160 bytes, the five words of `latestRoundData()`, is decoded; a shorter or longer one is
/// `sequencerUnknown`, so borrowing is blocked with reason `SEQUENCER_DOWN` and liquidation is not paused, whatever
/// its first 160 bytes report. The read copies at most 161 bytes, so an oversized answer costs no more than a 192-byte
/// one. Price-feed reads keep decoding the first five words of a longer answer.
contract LPOracleSequencerAnswerUnitTest is LPOracleFixture {
    uint256 internal constant ROUND_LENGTH = 160;
    uint256 internal constant SEQUENCER_DOWN_BIT = 14;
    /// @dev The answer served with the sequencer up; an unknown sequencer never changes it.
    int256 internal served;

    function setUp() public {
        _deployMarket(true);
        vm.warp(T0 + 60);
    }

    /// @dev `latestRoundData()` words (roundId, answer, startedAt, updatedAt, answeredInRound), restarted two hours ago,
    /// past the 3,600 s grace period.
    function _round(
        int256 answer
    ) internal pure returns (bytes memory) {
        return abi.encode(uint80(1), answer, T0 - 7200, T0 - 7200, uint80(1));
    }

    /// @dev The first `length` bytes of `round`, zero-padded beyond it.
    function _sized(
        bytes memory round,
        uint256 length
    ) internal pure returns (bytes memory out) {
        out = new bytes(length);
        uint256 n = length < round.length ? length : round.length;
        for (uint256 i = 0; i < n; ++i) {
            out[i] = round[i];
        }
    }

    function _answer(
        bytes memory data
    ) internal {
        vm.clearMockedCalls();
        vm.mockCall(address(seqFeed), abi.encodeCall(OracleFeedMock.latestRoundData, ()), data);
    }

    /// @dev Unknown: borrowing blocked with `SEQUENCER_DOWN`, liquidation not paused, state and price unchanged.
    function _assertUnknown(
        string memory what
    ) internal view {
        PriceStateView memory v = _state();
        assertFalse(v.borrowAllowed, what);
        assertFalse(v.sequencerReady, what);
        assertTrue(_has(v.reasons, SEQUENCER_DOWN_BIT), what);
        assertFalse(v.liquidationPaused, what);
        assertFalse(v.inGrace, what);
        assertEq(uint8(v.state), uint8(PriceState.Live), what);
        assertEq(v.answer, served, what);
    }

    /// @notice External entry run in its own frame, so the test's memory, grown by a 1 MB answer, does not price it.
    function measureEvaluation() external view returns (uint256 used, bool unknown) {
        uint256 before = gasleft();
        PriceStateView memory v = oracle.getPriceState();
        used = before - gasleft();
        unknown = !v.borrowAllowed && !v.liquidationPaused && _has(v.reasons, SEQUENCER_DOWN_BIT);
    }

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099
    // Sources: 2.10 SPEC-ORC-021 (a malformed return is sequencerUnknown), owner decision 2026-11-11
    /// @notice Exactly 160 bytes behaves as before: a round reporting up admits a borrow and one reporting down pauses
    /// liquidation and blocks borrowing. An up round one byte short (159), followed by one more byte (161) or one more
    /// word (192), or the first 160 bytes of a 1 MB answer, is unknown. A down round followed by one more byte or word
    /// is unknown too, so it never pauses liquidation. The 161- and 192-byte answers decode as up on a read that copies
    /// only 160 bytes and accepts a longer answer, so this test kills the `+ 1` and the `ret.length == ROUND_LENGTH`
    /// of `LPOracleConfig._readSequencer`.
    function test_TEST_275_sequencerRequiresExactRound() public {
        bytes memory up = _round(0);
        bytes memory down = _round(1);
        _answer(up);
        PriceStateView memory v = _state();
        assertTrue(v.borrowAllowed, "160 bytes, up: borrow allowed");
        assertTrue(v.sequencerReady);
        assertFalse(v.liquidationPaused);
        assertFalse(_has(v.reasons, SEQUENCER_DOWN_BIT));
        served = v.answer;
        _answer(down);
        v = _state();
        assertFalse(v.borrowAllowed, "160 bytes, down: borrowing blocked");
        assertTrue(v.liquidationPaused, "160 bytes, down: liquidation paused");
        assertTrue(_has(v.reasons, SEQUENCER_DOWN_BIT));

        _answer(_sized(up, ROUND_LENGTH - 1));
        _assertUnknown("159 bytes");
        _answer(_sized(up, ROUND_LENGTH + 1));
        _assertUnknown("161 bytes");
        _answer(abi.encodePacked(up, uint256(0)));
        _assertUnknown("192 bytes");
        _answer(_sized(up, 1 << 20));
        _assertUnknown("1 MB");
        _answer(_sized(down, ROUND_LENGTH + 1));
        _assertUnknown("161 bytes reporting down");
        _answer(abi.encodePacked(down, uint256(0)));
        _assertUnknown("192 bytes reporting down");

        _answer(up);
        assertTrue(_state().borrowAllowed, "back to 160 bytes");
    }

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099, SPEC-ORC-023
    // Sources: 2.10 SPEC-ORC-023 (bounded return copy)
    /// @notice A 1 MB answer whose first 160 bytes report up is unknown and costs the evaluation exactly what a 192-byte
    /// answer costs: the read copies at most 161 bytes, whatever the answer's length.
    function test_TEST_275_oversizedSequencerAnswerBoundedCost() public {
        bytes memory up = _round(0);
        _answer(abi.encodePacked(up, uint256(0)));
        this.measureEvaluation();
        (uint256 longerGas, bool longerUnknown) = this.measureEvaluation();
        _answer(_sized(up, 1 << 20));
        (uint256 hugeGas, bool hugeUnknown) = this.measureEvaluation();
        emit log_named_uint("getPriceState gas, 192-byte sequencer answer", longerGas);
        emit log_named_uint("getPriceState gas, 1 MB sequencer answer", hugeGas);
        assertTrue(longerUnknown && hugeUnknown, "a longer answer is unknown");
        assertLe(hugeGas, longerGas, "1 MB costs no more than 192 bytes");
    }

    // TEST-275 verifies: REQ-ORACLE-001, REQ-ORACLE-099
    /// @notice The exact-length rule is the sequencer read's own: a price feed answering a valid round followed by one
    /// more word is still decoded from its first five words, so the market stays Live on its primary routes.
    function test_TEST_275_priceFeedLongerAnswerUnchanged() public {
        _answer(_round(0));
        PriceStateView memory before = _state();
        assertTrue(before.borrowAllowed);
        bytes memory round = abi.encode(pA.roundId(), pA.answer(), pA.startedAt(), pA.updatedAt(), pA.roundId());
        vm.mockCall(
            address(pA), abi.encodeCall(OracleFeedMock.latestRoundData, ()), abi.encodePacked(round, uint256(0))
        );
        PriceStateView memory v = _state();
        assertEq(v.reasons, before.reasons, "no reason bit");
        assertEq(v.tokens[0].reasons, before.tokens[0].reasons, "no token reason bit");
        assertEq(v.tokens[0].routeUsed, uint8(RouteSlot.Primary), "token A on its primary route");
        assertEq(v.answer, before.answer);
        assertTrue(v.borrowAllowed);
    }
}
