// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {CollateralizationLedgerModel} from "./Collateralization.LedgerModel.sol";

/// @title CollateralizationLedgerUnitTest
/// @notice Long ledger sequences on the real Collateralization, Lock, vault token and local Aave V4, each step checked
/// against the reference model of `CollateralizationLedgerModel`: pledges of two borrowers, a kept seizure, an honest
/// liquidation, partial removals, re-credits, deleverage releases, zero-credit releases, pending settlements and
/// withdrawals, with exact unit accounting after every step (INV-001, INV-008, INV-015, INV-058), and the seizure-list
/// order after partial changes (SPEC-BACK-006).
/// forge-config: default.isolate = false
contract CollateralizationLedgerUnitTest is CollateralizationLedgerModel {
    function setUp() public {
        _deployCollateralization();
    }

    // TEST-153 verifies: INV-001, INV-008, INV-015, INV-058, REQ-VAULT-129, REQ-VAULT-133, REQ-VAULT-136, REQ-VAULT-137, REQ-VAULT-139, REQ-COLL-014, REQ-COLL-015, REQ-COLL-017, SPEC-BACK-005, SPEC-BACK-006, SPEC-BACK-011, SPEC-BACK-012, SPEC-BACK-015
    // Sources: 5.1 TEST-153, 4.1 INV-001, INV-008, INV-015, INV-058, 2.3 worked example "reconcile on exit"
    /// @notice Two borrowers run through every ledger write: four pledges, alice's seizure kept by a non-conforming
    /// LPVaultSwap, an honest liquidation of bob, alice's partial removal that reconciles the kept units, a re-credit,
    /// a pledge inserted among partly changed records, bob's partial and full deleverage releases, two pending
    /// settlements and every withdrawal. After each step every record, list, total, counter and pending amount equals
    /// the model, and supply equals credited plus pending.
    function test_TEST_153_ledgerSequenceAcrossEveryWrite() public {
        uint256 a1 = _doPledge(alice, aliceProxy, _key(1), 5_000_000_000);
        uint256 a2 = _doPledge(alice, aliceProxy, _key(2), 4_000_000_000);
        uint256 b3 = _doPledge(bob, bobProxy, _key(3), 3_000_000_000);
        uint256 b4 = _doPledge(bob, bobProxy, _key(4), 6_000_000_000);
        _check("pledges");
        assertEq(mList[bobProxy][0], b4, "bob's larger record at the head");

        _borrow(aliceProxy, 13_000e18);
        _borrow(bobProxy, 13_000e18);
        vtPrice.set(1.6e8);
        uint256 c = _doKeep(aliceProxy, 2400e18);
        assertGt(c, 0, "the kept seizure took units");
        assertLt(c, 5_000_000_000, "the kept seizure stays inside the head record");
        _check("kept seizure");
        assertEq(coll.previewRelease(INTEGRATION, _key(1)), _mPreview(a1), "preview of the head after the shortfall");
        assertEq(coll.previewRelease(INTEGRATION, _key(2)), _mPreview(a2), "preview of the second record");
        assertEq(coll.previewRelease(INTEGRATION, _key(1)), 5_000_000_000 - c);

        (uint256 s,) = _doLiquidate(bobProxy, 2400e18);
        assertGt(s, 0, "bob seized");
        _check("honest liquidation of bob");
        assertEq(mRec[b4].credited, 6_000_000_000 - s, "bob's head record debited");
        assertEq(mRec[b3].credited, 3_000_000_000, "bob's second record untouched");

        vtPrice.set(2e8);
        _repayAll(aliceProxy);
        _repayAll(bobProxy);
        uint256[] memory amounts = _doPartial(a2, 1_000_000_000);
        assertEq(amounts[0], 800_000_000, "partial removal pays the depositor");
        assertEq(mPendingUnits, c, "the kept units reconciled into pending");
        _check("partial removal reconciles");

        uint128 added = _doRecredit(a1, 2_000_000_000);
        assertEq(added, 2_000_000_000, "re-credit adds the live units above credit");
        _check("re-credit");

        uint256 a5 = _doPledge(alice, aliceProxy, _key(5), 4_500_000_000);
        _check("insertion among partly changed records");

        (amounts,) = _doDeleverage(b4, 1_000_000_000);
        assertEq(amounts[1], 1_250_000_000, "deleverage principal to LPVaultSwap");
        _check("partial deleverage");
        bool closed;
        (amounts, closed) = _doDeleverage(b3, mRec[b3].credited);
        assertTrue(closed, "a full deleverage closes the record");
        assertEq(lpVault.ownerOf(_key(3)), bob, "position returned to bob");
        _check("full deleverage");

        _doSettlePending(c / 3);
        _check("first pending settlement");
        _doSettlePending(mPendingUnits);
        _check("last pending settlement");
        assertEq(mPendingAmounts[0] + mPendingAmounts[1], 0, "nothing stranded");

        assertEq(mList[aliceProxy][1], a5, "the new record sits between the two older ones");
        _doWithdraw(a5);
        _check("withdraw a middle record");
        _doWithdraw(a1);
        _doWithdraw(a2);
        _doWithdraw(b4);
        _check("every record withdrawn");
        assertEq(coll.getTotalCredited(vt), 0);
        assertEq(token.totalSupply(), 0, "every unit retired");
        assertEq(coll.getCounters(vt, alice).regularUsed, 0, "every charge released");
    }

    // TEST-057 verifies: INV-015, REQ-VAULT-024, REQ-VAULT-054, SPEC-BACK-006, Q-194
    // Sources: 2.3 SPEC-BACK-006 (insertion walks the stored order; partial changes keep it)
    /// @notice Insertion into a list that partial removals left out of credited order walks the stored order and stops
    /// at the first record with fewer credited units: a new 3,500,000,000 record lands at the head before a record
    /// reduced to 3,000,000,000; a 2,000,000,000 record lands before a record reduced to 1,000,000,000; a tie stays
    /// behind the equal record. A seizure then debits in the stored order.
    function test_TEST_057_insertionWalksStoredOrderAfterPartialChanges() public {
        uint256 r1 = _doPledge(alice, aliceProxy, _key(1), 3_000_000_000);
        uint256 r2 = _doPledge(alice, aliceProxy, _key(2), 5_000_000_000);
        uint256 r3 = _doPledge(alice, aliceProxy, _key(3), 4_000_000_000);
        uint256 r4 = _doPledge(alice, aliceProxy, _key(4), 4_000_000_000);
        _assertOrder(aliceProxy, _ids4(r2, r3, r4, r1), "largest first, ties by lowest ID");
        _doPartial(r2, 2_000_000_000);
        _assertOrder(aliceProxy, _ids4(r2, r3, r4, r1), "partial removal keeps the place");
        uint256 r5 = _doPledge(alice, aliceProxy, _key(5), 3_500_000_000);
        assertEq(mList[aliceProxy][0], r5, "model puts 3.5e9 before the 3e9 head");
        _doPartial(r3, 3_000_000_000);
        uint256 r6 = _doPledge(alice, aliceProxy, _key(6), 2_000_000_000);
        uint256 r7 = _doPledge(alice, aliceProxy, _key(7), 3_000_000_000);
        uint256[] memory expected = new uint256[](7);
        (expected[0], expected[1], expected[2], expected[3]) = (r5, r2, r7, r6);
        (expected[4], expected[5], expected[6]) = (r3, r4, r1);
        _assertOrder(aliceProxy, expected, "stored order after partial changes");
        _check("seven records");

        _borrow(aliceProxy, 30_000e18);
        vtPrice.set(1.6e8);
        (uint256 seized,) = _doLiquidate(aliceProxy, 6000e18);
        assertGt(seized, 3_500_000_000, "the seizure reaches the second record");
        _check("debit in stored order");
        assertEq(coll.getRecord(r5).credited, 0, "head emptied first");
        assertFalse(coll.getRecord(r5).inList);
        assertEq(coll.getRecord(r2).credited, 6_500_000_000 - seized, "second record partly debited");
        assertEq(coll.getRecord(r7).credited, 3_000_000_000, "third record untouched though larger than the second");
    }

    // TEST-020 verifies: INV-015, INV-058, REQ-VAULT-075, REQ-VAULT-121, REQ-VAULT-143, REQ-COLL-011, REQ-COLL-021, SPEC-BACK-006, SPEC-BACK-011
    // Sources: 5.1 TEST-020, 2.3 SPEC-BACK-006 (records debited to 0 join the zero-credit list in walk order)
    /// @notice A kept seizure larger than the two head records turns both into zero-credit records at the next exit, in
    /// walk order behind the seizure list; the first is released by `releaseZeroCredit`, whose own reconcile emptied it,
    /// the list keeps the second; a credited record refuses the zero-credit release, a stranger is not the depositor, a
    /// zero record cannot be re-credited and previews 0 units.
    function test_TEST_020_zeroCreditListOrder() public {
        uint256 r1 = _doPledge(alice, aliceProxy, _key(1), 1_500_000_000);
        uint256 r2 = _doPledge(alice, aliceProxy, _key(2), 1_000_000_000);
        uint256 r3 = _doPledge(alice, aliceProxy, _key(3), 6_000_000_000);
        uint256 r4 = _doPledge(alice, aliceProxy, _key(4), 2_000_000_000);
        _assertOrder(aliceProxy, _ids4(r3, r4, r1, r2), "insertion order");
        _doPartial(r3, 5_500_000_000);
        _borrow(aliceProxy, 7500e18);
        vtPrice.set(1.5e8);
        uint256 c = _doKeep(aliceProxy, 4000e18);
        assertGt(c, 2_500_000_000, "the kept seizure empties the two head records");
        assertLt(c, 4_000_000_000, "and leaves the third with credit");
        assertEq(coll.previewRelease(INTEGRATION, _key(3)), 0, "head previews 0");
        assertEq(coll.previewRelease(INTEGRATION, _key(4)), 0, "second previews 0");
        assertEq(coll.previewRelease(INTEGRATION, _key(1)), _mPreview(r1), "third previews its rest");
        assertEq(coll.previewRecredit(INTEGRATION, _key(3)), 0, "a record that reconciles to 0 previews no re-credit");
        _check("kept seizure");

        _doZeroRelease(r3);
        _check("zero-credit release after its own reconcile");
        assertEq(lpVault.ownerOf(_key(3)), alice, "position returned with its remaining liquidity");
        assertEq(mZero[aliceProxy].length, 1, "the second zero record stays");
        assertEq(mZero[aliceProxy][0], r4);
        (uint256[] memory ids, BackingRecord[] memory rs) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids[ids.length - 1], r4, "zero-credit records follow the seizure list");
        assertEq(rs[ids.length - 1].credited, 0);

        vm.startPrank(adapter);
        lock.acquire();
        vm.expectRevert(ICollateralizationErrors.RecordHasCredit.selector);
        coll.releaseZeroCredit(alice, vt, _key(1));
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        coll.releaseZeroCredit(bob, vt, _key(4));
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.NothingToRecredit.selector, _key(4)));
        coll.recredit(alice, aliceProxy, vt, _key(4), "", false);
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        coll.release(aliceProxy, vt, _key(4), 0);
        lock.release();
        vm.stopPrank();

        uint256 r5 = _doPledge(alice, aliceProxy, _key(5), 100_000_000);
        _check("pledge with a zero-credit record open");
        (ids,) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids[ids.length - 1], r4, "a new pledge joins the seizure list, ahead of the zero list");
        assertEq(ids[ids.length - 2], r5);
        _doZeroRelease(r4);
        _check("last zero-credit record released");
        assertEq(mZero[aliceProxy].length, 0);
    }

    // TEST-151 verifies: INV-001, INV-008, INV-058, REQ-VAULT-133, REQ-VAULT-140, SPEC-BACK-011
    // Sources: 5.1 TEST-151 (two kept seizures reconciled by one honest settlement)
    /// @notice Two kept seizures of alice accumulate one shortfall; the honest liquidation that follows reconciles both
    /// into the pending balance first (one debit of their sum from the head) and then debits only its own units; the
    /// pending balance is then settled in one call.
    function test_TEST_151_twoKeptSeizuresOneReconcile() public {
        _doPledge(alice, aliceProxy, _key(1), 5_000_000_000);
        _doPledge(alice, aliceProxy, _key(2), 4_000_000_000);
        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.6e8);
        uint256 c1 = _doKeep(aliceProxy, 800e18);
        uint256 c2 = _doKeep(aliceProxy, 800e18);
        assertEq(mKept[aliceProxy], c1 + c2);
        _check("two kept seizures");
        (uint256 s,) = _doLiquidate(aliceProxy, 500e18);
        assertGt(s, 0);
        assertEq(mPendingUnits, c1 + c2, "both kept seizures reconciled");
        _check("honest settlement after two kept seizures");
        _doSettlePending(c1 + c2);
        _check("pending settled at once");
    }

    // ─── Helpers ───

    function _assertOrder(
        address proxy,
        uint256[] memory expected,
        string memory what
    ) internal view {
        (uint256[] memory ids,) = coll.getAccountRecords(proxy, vt, 0, 16);
        assertEq(ids.length, expected.length, what);
        for (uint256 i = 0; i < ids.length; ++i) {
            assertEq(ids[i], expected[i], what);
            assertEq(mList[proxy][i], expected[i], string.concat(what, " (model)"));
        }
    }

    function _ids4(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (a, b, c, d);
    }
}
