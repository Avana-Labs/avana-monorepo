// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @title DebtOracleSequencerAnswerUnitTest
/// @notice The length handling of the DebtOracle's sequencer-uptime read (`SPEC-ORC-021`, `REQ-ORACLE-099`): only an
/// answer of exactly 160 bytes, the five words of `latestRoundData()`, is decoded; a shorter or longer one is
/// `sequencerUnknown`, so borrowing is blocked with reason `SEQUENCER_DOWN` and liquidation is not paused, whatever
/// its first 160 bytes report. The read copies at most five words and takes the length from `returndatasize()`, so an
/// oversized answer costs no more than a 192-byte one. Price-feed reads keep decoding the first five words of a longer
/// answer.
contract DebtOracleSequencerAnswerUnitTest is DebtOracleFixture {
    uint256 internal constant ROUND_LENGTH = 160;
    uint256 internal constant R_SEQUENCER_DOWN = 1 << 17;
    MockAggregator internal seq;

    function setUp() public {
        _deployDebtOracle();
        vm.warp(T0 + 10);
        seq = new MockAggregator(0, 0, T0 - 7200);
        store.setSequencer(address(seq), 3600);
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
        vm.mockCall(address(seq), abi.encodeCall(MockAggregator.latestRoundData, ()), data);
    }

    function _view() internal view returns (DebtPriceView memory) {
        return oracle.getPriceState();
    }

    /// @dev Unknown: borrowing blocked with `SEQUENCER_DOWN`, liquidation not paused, state and price unchanged.
    function _assertUnknown(
        string memory what
    ) internal view {
        DebtPriceView memory v = _view();
        assertFalse(v.borrowAllowed, what);
        assertEq(v.reasons & R_SEQUENCER_DOWN, R_SEQUENCER_DOWN, what);
        assertFalse(v.liquidationPaused, what);
        assertFalse(v.inGrace, what);
        assertEq(uint8(v.state), uint8(PriceState.Live), what);
        assertEq(uint256(v.answer), uint256(USDC_USD), what);
    }

    /// @notice External entry run in its own frame, so the test's memory, grown by a 1 MB answer, does not price it.
    function measureEvaluation() external view returns (uint256 used, bool unknown) {
        uint256 before = gasleft();
        DebtPriceView memory v = oracle.getPriceState();
        used = before - gasleft();
        unknown = !v.borrowAllowed && !v.liquidationPaused && v.reasons & R_SEQUENCER_DOWN != 0;
    }

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099, REQ-ORACLE-092
    // Sources: 2.10 SPEC-ORC-021 (a malformed return is sequencerUnknown), owner decision 2026-11-11
    /// @notice Exactly 160 bytes behaves as before: a round reporting up admits a borrow and one reporting down pauses
    /// liquidation and blocks borrowing. An up round one byte short (159), followed by one more byte (161) or one more
    /// word (192), or the first 160 bytes of a 1 MB answer, is unknown. A down round followed by one more byte or word
    /// is unknown too, so it never pauses liquidation. The 161- and 192-byte answers decode as up when the size is not
    /// checked, so this test kills the `size == 160` of `DebtOracleEvaluation._readSequencer`.
    function test_TEST_275_sequencerRequiresExactRound() public {
        bytes memory up = _round(0);
        bytes memory down = _round(1);
        _answer(up);
        DebtPriceView memory v = _view();
        assertTrue(v.borrowAllowed, "160 bytes, up: borrow allowed");
        assertEq(v.reasons, 0);
        assertFalse(v.liquidationPaused);
        _answer(down);
        v = _view();
        assertFalse(v.borrowAllowed, "160 bytes, down: borrowing blocked");
        assertTrue(v.liquidationPaused, "160 bytes, down: liquidation paused");
        assertEq(v.reasons & R_SEQUENCER_DOWN, R_SEQUENCER_DOWN);

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
        assertTrue(_view().borrowAllowed, "back to 160 bytes");
    }

    // TEST-275 verifies: SPEC-ORC-021, REQ-ORACLE-099, SPEC-ORC-023
    // Sources: 2.10 SPEC-ORC-023 (bounded return copy)
    /// @notice A 1 MB answer whose first 160 bytes report up is unknown and costs the evaluation exactly what a 192-byte
    /// answer costs: the read copies at most five words, whatever the answer's length.
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
    /// @notice The exact-length rule is the sequencer read's own: a primary feed answering a valid round followed by
    /// one more word is still decoded from its first five words, so the primary route keeps serving.
    function test_TEST_275_priceFeedLongerAnswerUnchanged() public {
        _answer(_round(0));
        DebtPriceView memory before = _view();
        assertTrue(before.borrowAllowed);
        assertEq(uint8(before.routeUsed), uint8(RouteSlot.Primary));
        (uint80 id, int256 a, uint256 started, uint256 at, uint80 answeredIn) = pUsd.latestRoundData();
        vm.mockCall(
            address(pUsd),
            abi.encodeCall(MockAggregator.latestRoundData, ()),
            abi.encodePacked(abi.encode(id, a, started, at, answeredIn), uint256(0))
        );
        DebtPriceView memory v = _view();
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.Primary), "the primary still serves");
        assertEq(v.reasons, before.reasons, "no reason bit");
        assertEq(v.answer, before.answer);
        assertTrue(v.borrowAllowed);
    }
}
