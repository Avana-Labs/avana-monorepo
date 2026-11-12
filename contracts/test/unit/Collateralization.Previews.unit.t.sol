// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CollateralizationPreviewsUnitTest
/// @notice The previews a borrower and the Adapter size their calls with, checked against the calls themselves after a
/// kept seizure: `previewRelease` of every record equals the units the release must name, `previewRecredit` equals the
/// units the re-credit then credits (the reconcile removes exactly what it debits), and both skip the reconcile while
/// Hub shares differ from assets. Also the exact `RecordDebited` and `SeizureReconciled` arguments of a reconcile that
/// spans two records, and the counters view's refusals.
/// forge-config: default.isolate = false
contract CollateralizationPreviewsUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY_A = bytes32(uint256(1));
    bytes32 internal constant KEY_B = bytes32(uint256(2));
    bytes32 internal constant KEY_C = bytes32(uint256(3));

    function setUp() public {
        _deployCollateralization();
        // List [A 3e9, B 2e9, C 1e9]: a kept seizure above 3e9 empties A and reaches B.
        _pledge(alice, aliceProxy, KEY_A, 3_000_000_000);
        _pledge(alice, aliceProxy, KEY_B, 2_000_000_000);
        _pledge(alice, aliceProxy, KEY_C, 1_000_000_000);
        _borrow(aliceProxy, 9000e18);
        vtPrice.set(1.0e8);
    }

    function _keep() internal returns (uint256 c) {
        c = _seizeAndKeep(aliceProxy, 3500e18);
        assertGt(c, 3_000_000_000, "the kept seizure reaches the second record");
        assertLt(c, 5_000_000_000);
        vtPrice.set(2e8);
        debt.mint(aliceProxy, 1_000_000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();
    }

    // TEST-150 verifies: REQ-VAULT-128, REQ-COLL-018, SPEC-BACK-011, INV-058
    // Sources: 2.3 REQ-VAULT-128 (previewRelease is the units a withdrawal must use; 0 means a zero-credit release)
    /// @notice After a kept seizure of `c` units, the previews walk the list as the reconcile will: A previews 0, B
    /// previews `5e9 - c`, C previews all 1e9; withdrawing B with exactly its preview succeeds and A is then released
    /// with `releaseZeroCredit`.
    function test_TEST_150_previewReleaseOfEveryRecordAfterAShortfall() public {
        uint256 c = _keep();
        assertEq(coll.previewRelease(INTEGRATION, KEY_A), 0);
        assertEq(coll.previewRelease(INTEGRATION, KEY_B), 5_000_000_000 - c);
        assertEq(coll.previewRelease(INTEGRATION, KEY_C), 1_000_000_000);
        assertEq(coll.previewRecredit(INTEGRATION, KEY_A), 0, "a record that reconciles to 0 cannot be re-credited");
        _withdraw(aliceProxy, KEY_B, 5_000_000_000 - c);
        assertEq(coll.getPending(vt).units, c);
        assertEq(coll.getRecord(1).credited, 0, "A emptied by the reconcile");
        vm.startPrank(adapter);
        lock.acquire();
        coll.releaseZeroCredit(alice, vt, KEY_A);
        lock.release();
        vm.stopPrank();
        assertEq(lpVault.ownerOf(KEY_A), alice);
        assertEq(_shares(aliceProxy), coll.getAccountCredited(aliceProxy, vt));
        assertEq(_gap(), 0);
    }

    // TEST-238 verifies: REQ-COLL-018, REQ-COLL-015, REQ-VAULT-074, SPEC-BACK-011, SPEC-BACK-013
    // Sources: 2.3 REQ-COLL-018 (previewRecredit returns the added units recredit would credit now)
    /// @notice After a kept seizure and a 700,000,000-unit donation to C, `previewRecredit(C)` is 700,000,000 and the
    /// re-credit that follows (reconciling the shortfall first) credits exactly that, at a charge rebased on C's
    /// remaining basis.
    function test_TEST_238_previewRecreditMatchesTheRecredit() public {
        uint256 c = _keep();
        lpVault.addUnits(KEY_C, 700_000_000);
        lpVault.addUnits(KEY_B, 1);
        uint128 preview = coll.previewRecredit(INTEGRATION, KEY_C);
        assertEq(preview, 700_000_000);
        assertEq(coll.previewRecredit(INTEGRATION, KEY_B), 1, "B's donation is counted after its own reconcile");
        vm.startPrank(adapter);
        lock.acquire();
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordRecredited(3, 700_000_000, 140_000_000_000, 0);
        (uint128 added,) = coll.recredit(alice, aliceProxy, vt, KEY_C, "", false);
        token.mint(aliceProxy, added);
        vm.stopPrank();
        _supply(aliceProxy, added);
        vm.prank(adapter);
        lock.release();
        assertEq(added, preview, "the preview is what the re-credit credits");
        assertEq(coll.getPending(vt).units, c, "the re-credit reconciled first");
        assertEq(coll.getRecord(3).credited, 1_700_000_000);
        assertEq(coll.getRecord(3).originalUsdCharge, 340_000_000_000);
        assertEq(_shares(aliceProxy), coll.getAccountCredited(aliceProxy, vt));
    }

    // TEST-150 verifies: REQ-VAULT-130, REQ-VAULT-143, REQ-COLL-018, Q-189
    // Sources: 2.3 REQ-VAULT-130 (no reconcile while Hub added assets differ from added shares)
    /// @notice While the Hub's added assets differ from its added shares, the previews skip the reconcile: every record
    /// previews its stored credit and the donation-free re-credit preview is 0.
    function test_TEST_150_previewsSkipTheReconcileWhileSharesDifferFromAssets() public {
        _keep();
        uint256 shares = IAaveV4Hub(aave.hub).getAddedShares(vtAssetId);
        vm.mockCall(aave.hub, abi.encodeCall(IAaveV4Hub.getAddedAssets, (vtAssetId)), abi.encode(shares + 1));
        assertEq(coll.previewRelease(INTEGRATION, KEY_A), 3_000_000_000);
        assertEq(coll.previewRelease(INTEGRATION, KEY_B), 2_000_000_000);
        assertEq(coll.previewRecredit(INTEGRATION, KEY_A), 0, "no live units above credit");
        vm.clearMockedCalls();
        assertEq(coll.previewRelease(INTEGRATION, KEY_A), 0, "with equal shares the reconcile applies again");
    }

    // TEST-150 verifies: REQ-VAULT-134, REQ-VAULT-135, REQ-VAULT-136, SPEC-BACK-005, SPEC-BACK-011, SPEC-BACK-015
    // Sources: 2.3 REQ-VAULT-136 (one RecordDebited per debited record, one SeizureReconciled)
    /// @notice A reconcile of `c` units across two records emits `RecordDebited` for A (all 3e9, creditedAfter 0, its
    /// whole $6,000 charge released) and for B (`c - 3e9`, the rest, its charge released down to the ceiling of its
    /// basis share), each with its own principal, then `SeizureReconciled` with the summed principal.
    function test_TEST_150_reconcileEventsAcrossTwoRecords() public {
        uint256 c = _keep();
        uint256 takeB = c - 3_000_000_000;
        uint256 afterB = 2_000_000_000 - takeB;
        uint256 releasedB = 400_000_000_000 - Math.mulDiv(400_000_000_000, afterB, 2_000_000_000, Math.Rounding.Ceil);
        uint256[] memory a = new uint256[](2);
        (a[0], a[1]) = (2_400_000_000, 3_750_000_000);
        uint256[] memory b = new uint256[](2);
        (b[0], b[1]) = (takeB * 800_000 / 1e6, takeB * 1_250_000 / 1e6);
        uint256[] memory sum = new uint256[](2);
        (sum[0], sum[1]) = (a[0] + b[0], a[1] + b[1]);
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, 1_000_000_000);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordDebited(1, KEY_A, aliceProxy, vt, 3_000_000_000, 0, a, 600_000_000_000);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordDebited(2, KEY_B, aliceProxy, vt, takeB, afterB, b, releasedB);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.SeizureReconciled(aliceProxy, vt, c, sum);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY_C, 1_000_000_000);
        vm.prank(adapter);
        lock.release();
        assertEq(coll.getPending(vt).amounts[0], sum[0]);
        assertEq(_gap(), 0);
    }

    // TEST-097 verifies: REQ-COLL-003, REQ-VAULT-128, REQ-COLL-026
    // Sources: 2.3 REQ-VAULT-128 (getCounters names no proxy, so accountRecords is 0)
    /// @notice `getCounters` reports the account-free counters (`accountRecords = 0`) for any depositor, a depositor with
    /// no record reads 0 on its own counter, and an address that is not a registered vault token reverts
    /// `InvalidVaultToken`.
    function test_TEST_097_countersView() public {
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.accountRecords, 0, "no proxy named");
        assertEq(k.depositorUsed, 1_200_000_000_000, "6e9 units at $2");
        assertEq(coll.getCounters(vt, bob).depositorUsed, 0);
        assertEq(coll.getCounters(vt, bob).regularUsed, k.regularUsed, "market counters do not depend on the depositor");
        vm.expectRevert(ICollateralizationErrors.InvalidVaultToken.selector);
        coll.getCounters(makeAddr("notAVaultToken"), alice);
    }
}
