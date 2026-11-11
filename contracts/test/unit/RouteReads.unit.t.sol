// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ITetherFee} from "../../src/interfaces/external/tether/ITetherFee.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {RouteReadsHarness} from "../utils/harness/RouteReadsHarness.sol";
import {RawAnswer} from "../utils/mocks/RouteReadTargets.sol";
import {FeeSwitchToken} from "../utils/mocks/SwapRouteMocks.sol";

/// @title RouteReadsUnitTest
/// @notice The bounded reads a route's constructor makes (REQ-ROUTE-045: a named contract with no code, that reverts
/// or returns too little data fails the check) and the transfer-fee probe of REQ-ROUTE-008: an address word with any
/// bit above 160 is refused, a one-word read needs 32 bytes and a three-word read 96, longer answers are cut to the
/// words read, and the probe reports a switch only for an answer of exactly one word, and also when too little gas is
/// left to make it (fail closed).
contract RouteReadsUnitTest is AvanaTest {
    RouteReadsHarness internal reads;
    RawAnswer internal raw;

    function setUp() public {
        reads = new RouteReadsHarness();
        raw = new RawAnswer();
    }

    // TEST-054 verifies: REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (a read that reverts or returns too little data fails the check)
    /// @notice `addressOf` accepts exactly a word whose top 96 bits are clear: the largest address is accepted, one
    /// bit above it is refused; 31 bytes, no bytes, a revert and an address with no code are refused; a longer answer
    /// is read from its first word.
    function test_TEST_054_addressOfAcceptsOnlyAClean20ByteWord() public {
        address top = address(type(uint160).max);
        raw.set(abi.encode(top));
        (bool ok, address value) = reads.addressOf(address(raw), hex"01");
        assertTrue(ok);
        assertEq(value, top, "largest address");
        raw.set(abi.encode(uint256(type(uint160).max) + 1));
        (ok, value) = reads.addressOf(address(raw), hex"01");
        assertFalse(ok, "bit 160 set");
        assertEq(value, address(0));
        raw.set(abi.encode(type(uint256).max));
        (ok,) = reads.addressOf(address(raw), hex"01");
        assertFalse(ok, "every bit set");
        raw.set(new bytes(31));
        (ok,) = reads.addressOf(address(raw), hex"01");
        assertFalse(ok, "31 bytes");
        raw.set("");
        (ok,) = reads.addressOf(address(raw), hex"01");
        assertFalse(ok, "no bytes");
        raw.set(abi.encode(address(0xBEEF), uint256(7)));
        (ok, value) = reads.addressOf(address(raw), hex"01");
        assertTrue(ok, "two words: the first is read");
        assertEq(value, address(0xBEEF));
        raw.setReverts(true);
        (ok,) = reads.addressOf(address(raw), hex"01");
        assertFalse(ok, "revert");
        (ok,) = reads.addressOf(makeAddr("eoa"), hex"01");
        assertFalse(ok, "no code");
    }

    // TEST-054 verifies: REQ-ROUTE-045
    /// @notice `words` reads one word from 32 bytes and three words from 96; 95 bytes for three words and 31 for one
    /// fail; a longer answer is cut to the words read; values are not range-checked here (the caller compares them).
    function test_TEST_054_wordsNeedTheFullLength() public {
        raw.set(abi.encode(uint256(1), uint256(2), uint256(3), uint256(4)));
        (bool ok, uint256[3] memory w) = reads.words(address(raw), hex"01", true);
        assertTrue(ok);
        assertEq(w[0], 1);
        assertEq(w[1], 2);
        assertEq(w[2], 3);
        (ok, w) = reads.words(address(raw), hex"01", false);
        assertTrue(ok);
        assertEq(w[0], 1);
        assertEq(w[1], 0, "one-word read leaves the rest 0");
        bytes memory short3 = new bytes(95);
        raw.set(short3);
        (ok, w) = reads.words(address(raw), hex"01", true);
        assertFalse(ok, "95 bytes for three words");
        assertEq(w[0], 0);
        raw.set(new bytes(31));
        (ok,) = reads.words(address(raw), hex"01", false);
        assertFalse(ok, "31 bytes for one word");
        raw.set(abi.encode(type(uint256).max));
        (ok, w) = reads.words(address(raw), hex"01", false);
        assertTrue(ok, "any value decodes");
        assertEq(w[0], type(uint256).max);
        raw.setReverts(true);
        (ok,) = reads.words(address(raw), hex"01", false);
        assertFalse(ok, "revert");
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-008 (a token answering `basisPointsRate()` can switch on a fee, with the fee on or off)
    /// @notice The fee-switch probe: a token answering one word reports a switch whether the fee is 0 or not; an
    /// answer of 31, 33 or 64 bytes, a revert, an address with no code and a probe that burns its gas report none.
    function test_TEST_221_feeSwitchProbeAnswers() public {
        FeeSwitchToken tether = new FeeSwitchToken("USDT", 6);
        assertTrue(reads.hasFeeSwitch(address(tether)), "fee off still answers");
        tether.setFeeBps(10);
        assertTrue(reads.hasFeeSwitch(address(tether)), "fee on");
        raw.set(abi.encode(uint256(0)));
        assertTrue(reads.hasFeeSwitch(address(raw)), "one word");
        raw.set(new bytes(31));
        assertFalse(reads.hasFeeSwitch(address(raw)), "31 bytes");
        raw.set(new bytes(33));
        assertFalse(reads.hasFeeSwitch(address(raw)), "33 bytes");
        raw.set(abi.encode(uint256(0), uint256(0)));
        assertFalse(reads.hasFeeSwitch(address(raw)), "two words");
        raw.setReverts(true);
        assertFalse(reads.hasFeeSwitch(address(raw)), "revert");
        raw.setReverts(false);
        raw.setBurns(true);
        assertFalse(reads.hasFeeSwitch(address(raw)), "a probe that runs out of its 30,000 gas");
        assertFalse(reads.hasFeeSwitch(makeAddr("noCode")), "no code");
    }

    // TEST-221 verifies: REQ-ROUTE-008, REQ-ROUTE-045
    // Sources: 2.12 REQ-ROUTE-045 (every failed check fails closed)
    /// @notice With less gas than the probe needs (`ceil(64 x 30,000 / 63) + 5,000`) the probe reports a switch
    /// without calling, so a starved deployment refuses a concentrated-liquidity or GSM input rather than accepting an
    /// unprobed token; with ample gas a token that does not answer reports none.
    function test_TEST_221_starvedProbeFailsClosed() public {
        raw.set("");
        assertFalse(reads.hasFeeSwitch{gas: 200_000}(address(raw)), "ample gas, no answer");
        vm.expectCall(address(raw), abi.encodeCall(ITetherFee.basisPointsRate, ()), 0);
        assertTrue(reads.hasFeeSwitch{gas: 30_000}(address(raw)), "starved: treated as switchable");
    }

    // TEST-221 verifies: REQ-ROUTE-008
    /// @notice The probe forwards at most 30,000 gas: a token that would need more to answer is read as having no
    /// switch, and the caller keeps the rest of its gas.
    function testFuzz_TEST_221_probeGasIsBounded(
        uint256 callGas
    ) public {
        callGas = bound(callGas, 100_000, 3_000_000);
        raw.setBurns(true);
        uint256 before = gasleft();
        bool switchable = reads.hasFeeSwitch{gas: callGas}(address(raw));
        uint256 used = before - gasleft();
        assertFalse(switchable);
        assertLt(used, 60_000, "the probe's gas is capped");
    }
}
