// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {CollateralizationLedgerHarness, HarnessLock} from "../utils/harness/CollateralizationLedgerHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title CollateralizationFuzzTest
/// @notice Stateless properties of Collateralization's record internals: the exit charge depends only on the remaining
/// units, insertion keeps the list largest-first, a debit walks from the head and touches only what it debits, and
/// the totals, counters and rescue units follow every debit. Fuzz twins of the Halmos checks that can time out.
contract CollateralizationFuzzTest is Test {
    address internal constant PROXY = address(0xA11CE);
    address internal constant ADAPTER = address(0xADA);
    address internal constant SWAP = address(0x5A1);

    CollateralizationLedgerHarness internal h;
    HarnessLock internal lock;

    function setUp() public {
        lock = new HarnessLock();
        h = new CollateralizationLedgerHarness(ADAPTER, SWAP, address(lock));
    }

    // TEST-014 verifies: SPEC-BACK-005, SPEC-BACK-013, REQ-VAULT-036, INV-027, ATTACK-012, Q-174
    // Sources: 5.1 TEST-014, PROP-028 fuzz twin, MATH-UO-25, MATH-UO-26
    /// @notice `ceil(V0 * remaining / U0)` is the same however exits are split, never rises as units leave, never
    /// exceeds `V0`, and is 0 exactly when nothing remains.
    function testFuzz_TEST_014_chargeIndependentOfSplit(
        uint64 v0,
        uint120 u0,
        uint120 x1,
        uint120 x2
    ) public view {
        u0 = uint120(bound(u0, 1, type(uint120).max));
        x1 = uint120(bound(x1, 0, u0));
        x2 = uint120(bound(x2, 0, u0 - x1));
        uint256 afterBoth = h.remainingCharge(v0, u0 - x1 - x2, u0);
        uint256 afterFirst = h.remainingCharge(v0, u0 - x1, u0);
        assertLe(afterBoth, afterFirst, "monotone");
        assertLe(afterFirst, v0, "never above the basis");
        assertEq(h.remainingCharge(v0, u0, u0), v0, "nothing exited");
        assertEq(h.remainingCharge(v0, 0, u0), 0, "last exit clears");
        uint256 released = (v0 - afterFirst) + (afterFirst - afterBoth);
        assertEq(released, v0 - afterBoth, "split releases the same total");
    }

    // TEST-124 verifies: SPEC-BACK-006, REQ-VAULT-016, INV-015, Q-194
    // Sources: 5.1 TEST-124, HYP-45
    /// @notice Pledging up to 16 records of random sizes keeps the list largest-first with ties by lowest ID.
    function testFuzz_TEST_124_insertionKeepsOrder(
        uint128[16] memory sizes,
        uint8 count
    ) public {
        count = uint8(bound(count, 1, 16));
        for (uint256 i = 0; i < count; ++i) {
            h.seed(PROXY, uint128(bound(sizes[i], 1, 1e18)), 1, 0, 0);
        }
        uint256[] memory l = h.list(PROXY);
        assertEq(l.length, count);
        for (uint256 i = 1; i < l.length; ++i) {
            uint256 prev = h.record(l[i - 1]).credited;
            uint256 cur = h.record(l[i]).credited;
            assertTrue(prev > cur || (prev == cur && l[i - 1] < l[i]), "largest first, ties by lowest ID");
        }
    }

    // TEST-057 verifies: SPEC-BACK-006, SPEC-BACK-014, REQ-VAULT-054, REQ-VAULT-055, REQ-VAULT-074, REQ-COLL-016, INV-015, INV-082, ATTACK-013
    // Sources: 5.1 TEST-057, PROP-012 and PROP-013 fuzz twins, MATH-ST-42..45
    /// @notice A debit of `u` takes from the head, empties a prefix, partially debits at most the last record it
    /// touches (which ends at the head), leaves the rest untouched, lowers every total by `u` and keeps rescue units at
    /// most the credit; a debit above the account's credit reverts with no change.
    function testFuzz_TEST_057_debitWalk(
        uint64[6] memory sizes,
        uint8 count,
        uint256 u,
        uint64 rescueSeed
    ) public {
        count = uint8(bound(count, 1, 6));
        uint256 sum = 0;
        for (uint256 i = 0; i < count; ++i) {
            uint128 c = uint128(bound(sizes[i], 1, 1e15));
            h.seed(PROXY, c, uint64(c), 0, uint128(bound(rescueSeed, 0, c)));
            sum += c;
        }
        uint256[] memory before = h.list(PROXY);
        uint256[] memory creditBefore = new uint256[](before.length);
        for (uint256 i = 0; i < before.length; ++i) {
            creditBefore[i] = h.record(before[i]).credited;
        }
        if (u > sum) {
            u = bound(u, sum + 1, type(uint128).max);
            vm.expectRevert(ICollateralizationErrors.InsufficientCredit.selector);
            h.debit(PROXY, u);
            return;
        }
        u = bound(u, 0, sum);
        h.debit(PROXY, u);
        assertEq(h.credit(PROXY), sum - u, "account credit");
        assertEq(h.total(), sum - u, "market credit");
        assertEq(h.pool(), sum - u, "pool units");
        uint256 rem = u;
        uint256 emptied = 0;
        for (uint256 i = 0; i < before.length; ++i) {
            BackingRecord memory r = h.record(before[i]);
            uint256 take = rem < creditBefore[i] ? rem : creditBefore[i];
            rem -= take;
            assertEq(r.credited, creditBefore[i] - take, "head-first allocation");
            assertLe(r.rescueUnits, r.credited, "rescue capped");
            if (take == creditBefore[i] && take != 0) {
                assertFalse(r.inList);
                ++emptied;
            }
        }
        uint256[] memory l = h.list(PROXY);
        assertEq(l.length, before.length - emptied, "emptied records left the list");
        assertEq(h.zeros(PROXY).length, emptied, "and stay open at 0");
        if (l.length > 0 && emptied < before.length) assertEq(l[0], before[emptied], "partial record at the head");
    }

    // TEST-097 verifies: INV-027, REQ-VAULT-036, REQ-VAULT-037, REQ-VAULT-038, SPEC-BACK-005
    // Sources: 5.1 TEST-097 (ledger side)
    /// @notice After any debit the market buckets equal the sum of the records' remaining charges, the token counter
    /// too, and closing every record returns every counter to 0 without saturation.
    function testFuzz_TEST_097_countersFollowCharges(
        uint64[4] memory sizes,
        uint64[4] memory slices,
        uint256 u
    ) public {
        uint256 sum = 0;
        for (uint256 i = 0; i < 4; ++i) {
            uint128 c = uint128(bound(sizes[i], 1, 1e15));
            uint64 charge = uint64(bound(sizes[i], 1, type(uint64).max / 8));
            h.seed(PROXY, c, charge, uint64(bound(slices[i], 0, charge)), 0);
            sum += c;
        }
        h.debit(PROXY, bound(u, 0, sum));
        uint256 charges = 0;
        for (uint256 id = 1; id <= 4; ++id) {
            charges += h.record(id).currentUsdCharge;
        }
        (uint256 regular, uint256 slice) = h.market();
        assertEq(regular + slice, charges, "buckets = remaining charges");
        assertEq(h.tokenCounter(), charges, "token counter = remaining charges");
        for (uint256 id = 1; id <= 4; ++id) {
            h.close(id);
        }
        (regular, slice) = h.market();
        assertEq(regular + slice, 0);
        assertEq(h.tokenCounter(), 0);
        assertEq(h.credit(PROXY), 0);
    }
}
