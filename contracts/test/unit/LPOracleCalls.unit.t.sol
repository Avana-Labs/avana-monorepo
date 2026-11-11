// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCalls} from "../../src/oracle/lp-oracle/LPOracleCalls.sol";
import {Test} from "forge-std/Test.sol";

/// @notice External entry points over the internal `LPOracleCalls` decoders.
contract LPOracleCallsHarness {
    function wordAt(
        bytes memory b,
        uint256 offset
    ) external pure returns (bool ok, uint256 word) {
        return LPOracleCalls.wordAt(b, offset);
    }

    function uintAt(
        bytes memory b,
        uint256 offset,
        uint256 max
    ) external pure returns (bool ok, uint256 value) {
        return LPOracleCalls.uintAt(b, offset, max);
    }

    function intAt(
        bytes memory b,
        uint256 offset,
        uint256 bits
    ) external pure returns (bool ok, int256 value) {
        return LPOracleCalls.intAt(b, offset, bits);
    }

    function wordArray(
        bytes memory b,
        uint256 count
    ) external pure returns (bool ok, uint256[] memory values) {
        return LPOracleCalls.wordArray(b, count);
    }
}

/// @notice The bounded decoders of every LPOracle external read (2.10 `REQ-ORACLE-001`, `REQ-ORACLE-061`): a return
/// that is too short, a word beyond its type or a malformed `uint256[]` encoding is a failed read (`ok = false`, value
/// 0), never a decoder revert and never an out-of-bounds read.
contract LPOracleCallsUnitTest is Test {
    LPOracleCallsHarness internal h;

    function setUp() public {
        h = new LPOracleCallsHarness();
    }

    // TEST-038 verifies: REQ-ORACLE-001, REQ-ORACLE-061
    function test_TEST_038_wordAtIsBoundsChecked() public view {
        bytes memory b = abi.encode(uint256(7), uint256(9));
        (bool ok, uint256 w) = h.wordAt(b, 32);
        assertTrue(ok, "last whole word");
        assertEq(w, 9);
        (ok, w) = h.wordAt(b, 33);
        assertFalse(ok, "31 bytes left");
        assertEq(w, 0);
        (ok, w) = h.wordAt(b, 65);
        assertFalse(ok, "offset past the end");
        assertEq(w, 0);
        (ok, w) = h.wordAt(hex"0011", 0);
        assertFalse(ok, "2-byte return");
        (ok, w) = h.wordAt(b, type(uint256).max);
        assertFalse(ok, "offset 2^256 - 1 does not wrap");
    }

    // TEST-038 verifies: REQ-ORACLE-001, REQ-ORACLE-061
    function test_TEST_038_uintAtRangeChecksTheWord() public view {
        bytes memory b = abi.encode(uint256(255), uint256(256));
        (bool ok, uint256 v) = h.uintAt(b, 0, type(uint8).max);
        assertTrue(ok, "255 fits uint8");
        assertEq(v, 255);
        (ok, v) = h.uintAt(b, 32, type(uint8).max);
        assertFalse(ok, "256 does not fit uint8");
        assertEq(v, 0);
        (ok, v) = h.uintAt(hex"ff", 0, type(uint8).max);
        assertFalse(ok, "short return");
        assertEq(v, 0);
    }

    // TEST-038 verifies: REQ-ORACLE-001, REQ-ORACLE-061
    function test_TEST_038_intAtChecksTheSignExtension() public view {
        int256 top = int256(type(int192).max);
        int256 bottom = int256(type(int192).min);
        (bool ok, int256 v) = h.intAt(abi.encode(top), 0, 192);
        assertTrue(ok);
        assertEq(v, top, "int192 max");
        (ok, v) = h.intAt(abi.encode(bottom), 0, 192);
        assertTrue(ok);
        assertEq(v, bottom, "int192 min");
        (ok, v) = h.intAt(abi.encode(top + 1), 0, 192);
        assertFalse(ok, "2^191 is no int192");
        assertEq(v, 0);
        (ok, v) = h.intAt(abi.encode(bottom - 1), 0, 192);
        assertFalse(ok, "-2^191 - 1 is no int192");
        assertEq(v, 0);
        // A positive word with high bits set that are not a sign extension is malformed.
        (ok, v) = h.intAt(abi.encode(uint256(1) << 200), 0, 192);
        assertFalse(ok);
        // 256 bits: every word is a valid int256, negative ones included.
        (ok, v) = h.intAt(abi.encode(type(uint256).max), 0, 256);
        assertTrue(ok, "any word is an int256");
        assertEq(v, -1);
        (ok, v) = h.intAt(abi.encode(type(int256).min), 0, 256);
        assertTrue(ok);
        assertEq(v, type(int256).min);
        (ok, v) = h.intAt(hex"0102", 0, 192);
        assertFalse(ok, "short return");
        assertEq(v, 0);
    }

    // TEST-038 verifies: REQ-ORACLE-001, REQ-ORACLE-061
    function test_TEST_038_wordArrayAcceptsOnlyTheExactEncoding() public view {
        uint256[] memory a = new uint256[](3);
        (a[0], a[1], a[2]) = (11, 22, 33);
        bytes memory b = abi.encode(a);
        (bool ok, uint256[] memory w) = h.wordArray(b, 3);
        assertTrue(ok);
        assertEq(w.length, 3);
        assertEq(w[2], 33);
        (ok, w) = h.wordArray(b, 2);
        assertFalse(ok, "length differs from 64 + 32 * count");
        assertEq(w.length, 0);
        (ok, w) = h.wordArray(bytes.concat(b, bytes32(0)), 3);
        assertFalse(ok, "trailing word");
        bytes memory badOffset = abi.encode(uint256(0x40), uint256(3), uint256(11), uint256(22), uint256(33));
        (ok, w) = h.wordArray(badOffset, 3);
        assertFalse(ok, "offset word not 0x20");
        assertEq(w.length, 0);
        bytes memory badCount = abi.encode(uint256(0x20), uint256(4), uint256(11), uint256(22), uint256(33));
        (ok, w) = h.wordArray(badCount, 3);
        assertFalse(ok, "length word differs from count");
        (ok, w) = h.wordArray(b, uint256(type(uint32).max) + 1);
        assertFalse(ok, "count above 2^32 - 1");
    }
}
