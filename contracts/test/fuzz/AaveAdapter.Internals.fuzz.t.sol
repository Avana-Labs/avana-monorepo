// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveAdapterProperties} from "../invariant/echidna/AaveAdapterProperties.sol";
import {Test} from "forge-std/Test.sol";

/// @title AaveAdapterInternalsFuzzTest
/// @notice The AaveAdapter's backing-gap check and transient session, through the Echidna harness that inherits the
/// production internals: the same assertion entry points under Foundry's fuzzer, and the harness's properties after
/// each call.
contract AaveAdapterInternalsFuzzTest is Test {
    AaveAdapterProperties internal h;

    function setUp() public {
        h = new AaveAdapterProperties();
    }

    // TEST-241 verifies: REQ-ADAPTER-069, REQ-ADAPTER-075, SPEC-PROXY-008, INV-080
    // Sources: QNT-03, HYP-44
    /// @notice `BackingMismatch` is raised exactly for an unbacked mint or an unmatched burn; a conforming pledge,
    /// withdrawal, deleverage reconciliation or a pledge after an orphan burn passes and keeps the gap.
    function testFuzz_TEST_241_gapCheckExactlyForNonConformingCalls(
        uint8 kind,
        uint64 a,
        uint64 b,
        uint64 base
    ) public {
        h.gapCall(kind, a, b, base);
        assertTrue(h.property_gapCheckMatchesModel(), "gap check matches the model");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-ADAPTER-092
    /// @notice The session reads back what was written, its step flags only accumulate, and a cleared or ended session
    /// is empty.
    function testFuzz_TEST_239_sessionRoundTrip(
        address proxy,
        uint256 marketId,
        bytes32 key,
        uint256 units,
        uint256 reserveId,
        bytes32 minHash,
        uint8 steps
    ) public {
        h.session(proxy, marketId, key, units, reserveId, minHash, steps);
        assertTrue(h.property_sessionEmptyBetweenTransactions(), "session empty");
        assertTrue(h.property_storageSlotIsNamespace(), "slot");
        assertTrue(h.property_immutablesFixed(), "immutables");
    }
}
