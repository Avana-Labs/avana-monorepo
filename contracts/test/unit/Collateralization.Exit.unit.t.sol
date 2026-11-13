// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollOracleMock} from "../utils/mocks/CollateralizationMocks.sol";

/// @title CollateralizationExitUnitTest
/// @notice Exits on the real local Aave V4: withdrawal release, partial removal, deleverage release, zero-credit
/// release and fee collection, reconcile on exit after a seize-and-keep LPVaultSwap, the skip while Hub shares differ
/// from assets, donations and a third party's dust liquidation.
/// forge-config: default.isolate = false
contract CollateralizationExitUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    function _acquire(
        address member
    ) internal {
        vm.prank(member);
        lock.acquire();
    }

    function _release(
        address member
    ) internal {
        vm.prank(member);
        lock.release();
    }

    // TEST-018 verifies: REQ-VAULT-068, REQ-VAULT-069, REQ-VAULT-070, REQ-VAULT-071, REQ-VAULT-072, REQ-VAULT-073, REQ-VAULT-033, REQ-COLL-006, REQ-COLL-008, WDR-015, INV-045
    // Sources: 5.1 TEST-018 (Collateralization side)
    /// @notice A debt-free withdrawal of NFT 42: `release` with the record's credited units closes the record,
    /// releases its whole charge, lowers every total and has the LPVault return the position to its depositor; no
    /// RiskModule or LPOracle call is made.
    function test_TEST_018_withdrawalRelease() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 5_000_000_000);
        vm.expectCall(address(riskModule), abi.encodeWithSelector(IRiskModuleChecks.checkPledge.selector), 0);
        vm.expectCall(address(oracle), abi.encodeCall(CollOracleMock.poke, ()), 0);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.CollateralReleased(1, KEY42, alice, aliceProxy, vt, 5_000_000_000);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, 5_000_000_000);
        _release(adapter);
        assertEq(coll.recordIdOf(INTEGRATION, KEY42), 0, "record closed");
        assertEq(coll.getRecord(1).depositor, address(0), "record deleted");
        assertEq(lpVault.ownerOf(KEY42), alice, "position back to its depositor");
        assertEq(coll.getTotalCredited(vt), 4_000_000_000);
        assertEq(coll.getAccountCredited(aliceProxy, vt), 4_000_000_000);
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 1);
        assertEq(coll.getMarketRecordCount(vt), 1);
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.regularUsed, 800_000_000_000, "only NFT 7's charge stays");
        assertEq(k.tokenUsed[1], 800_000_000_000);
        assertEq(k.depositorUsed, 800_000_000_000);
        assertEq(k.poolUnits, 4_000_000_000);
        assertEq(_gap(), 0);
        (uint256[] memory ids,) = coll.getMarketRecords(vt, 0, 10);
        assertEq(ids.length, 1);
        assertEq(ids[0], 2);
    }

    // TEST-018 verifies: REQ-VAULT-068, REQ-VAULT-069, REQ-VAULT-113, REQ-VAULT-118, REQ-VAULT-119, REQ-VAULT-102, REQ-LOCK-011
    /// @notice `release` refuses an unknown position, another proxy, another market and units other than the
    /// record's credited units.
    function test_TEST_018_releaseRejections() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(bob, bobProxy, KEY7, 4_000_000_000);
        _acquire(adapter);
        vm.startPrank(adapter);
        vm.expectRevert(ICollateralizationErrors.RecordNotFound.selector);
        coll.release(aliceProxy, vt, _key(1), 1);
        vm.expectRevert(ICollateralizationErrors.NotRecordProxy.selector);
        coll.release(bobProxy, vt, KEY42, 5_000_000_000);
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        coll.release(aliceProxy, vt, KEY42, 4_999_999_999);
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        coll.release(aliceProxy, vt, KEY42, 0);
        vm.stopPrank();
        _release(adapter);
    }

    // TEST-237 verifies: REQ-COLL-014, REQ-COLL-020, REQ-VAULT-031, REQ-VAULT-032, REQ-VAULT-036, REQ-VAULT-088, SPEC-BACK-005, SPEC-BACK-010, SPEC-BACK-015, INV-088, Q-254
    // Sources: 5.1 TEST-237 (Collateralization side), 2.3 REQ-COLL-014 example
    /// @notice Alice removes 1,000,000,000 of NFT 42's 5,000,000,000 units: the record keeps 4,000,000,000 units and
    /// an $8,000 charge, the counters fall by $2,000, the principal reaches alice measured by her balance deltas, and a
    /// request for every remaining unit reverts `PartialRemovalTooLarge`.
    function test_TEST_237_partialRemoval() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        uint256 usdcBefore = usdc.balanceOf(alice);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 1_000_000_000);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.RecordReduced(1, 1_000_000_000, 200_000_000_000);
        vm.prank(adapter);
        (uint128 remaining, uint256[] memory amounts) =
            coll.releasePartial(aliceProxy, vt, KEY42, 1_000_000_000, new uint256[](2));
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralizationErrors.PartialRemovalTooLarge.selector, uint128(4_000_000_000), uint128(4_000_000_000)
            )
        );
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 4_000_000_000, new uint256[](2));
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 0, new uint256[](2));
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, 2, 3));
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 1, new uint256[](3));
        _release(adapter);
        assertEq(remaining, 4_000_000_000);
        assertEq(amounts[0], 800_000_000, "USDC principal");
        assertEq(amounts[1], 1_250_000_000, "USDT principal");
        assertEq(usdc.balanceOf(alice) - usdcBefore, 800_000_000, "paid to the depositor");
        BackingRecord memory r = coll.getRecord(1);
        assertEq(r.credited, 4_000_000_000);
        assertEq(r.currentUsdCharge, 800_000_000_000);
        assertEq(r.originalUnits, 5_000_000_000, "basis unchanged");
        assertEq(coll.getCounters(vt, alice).regularUsed, 800_000_000_000);
        assertEq(coll.getTotalCredited(vt), 4_000_000_000);
        assertEq(_gap(), 0);
        assertEq(lpVault.ownerOf(KEY42), address(lpVault), "the position stays in custody");
    }

    // TEST-237 verifies: SPEC-BACK-015, REQ-VAULT-088, REQ-VAULT-061, Q-271
    /// @notice With a 10 bps USDT transfer fee the returned amounts are what alice actually received.
    function test_TEST_237_partialRemovalMeasuresReceipts() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        usdt.setFeeBps(10);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 1_000_000_000);
        vm.prank(adapter);
        (, uint256[] memory amounts) = coll.releasePartial(aliceProxy, vt, KEY42, 1_000_000_000, new uint256[](2));
        _release(adapter);
        assertEq(amounts[1], 1_250_000_000 - 1_250_000, "received, not removed");
    }

    // TEST-239 verifies: REQ-COLL-017, REQ-VAULT-031, REQ-VAULT-036, REQ-VAULT-074, SPEC-BACK-005, Q-255
    // Sources: 5.1 TEST-239 (Collateralization side), 2.3 REQ-COLL-017 example
    /// @notice A deleverage release of 800,000,000 of NFT 7's 4,000,000,000 units keeps the record open at a $6,400
    /// charge and sends the principal to LPVaultSwap; a release of every remaining unit closes the record and returns
    /// NFT 7 to alice.
    function test_TEST_239_deleverageRelease() public {
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 800_000_000);
        vm.prank(adapter);
        (uint256[] memory amounts, bool closed) =
            coll.releaseForDeleverage(aliceProxy, vt, KEY7, 800_000_000, new uint256[](2));
        assertFalse(closed);
        assertEq(amounts[0], 640_000_000);
        assertEq(usdc.balanceOf(lpVaultSwap), 640_000_000, "principal to LPVaultSwap");
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        vm.prank(adapter);
        coll.releaseForDeleverage(aliceProxy, vt, KEY7, 3_200_000_001, new uint256[](2));
        _withdrawAndBurn(aliceProxy, 3_200_000_000);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.CollateralReleased(1, KEY7, alice, aliceProxy, vt, 3_200_000_000);
        vm.prank(adapter);
        (, closed) = coll.releaseForDeleverage(aliceProxy, vt, KEY7, 3_200_000_000, new uint256[](2));
        _release(adapter);
        assertTrue(closed);
        assertEq(coll.recordIdOf(INTEGRATION, KEY7), 0);
        assertEq(lpVault.ownerOf(KEY7), alice);
        assertEq(coll.getCounters(vt, alice).regularUsed, 0, "whole charge released");
        assertEq(_gap(), 0);
    }

    // TEST-239 verifies: REQ-COLL-017, REQ-VAULT-010, REQ-VAULT-105, REQ-COLL-023
    /// @notice The pool lock and the LPVault's per-token minimums revert the deleverage release unchanged.
    function test_TEST_239_poolLockAndMinimums() public {
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 800_000_000);
        lpVault.setPoolLocked(true);
        vm.expectRevert(ILPVaultErrors.PoolLocked.selector);
        vm.prank(adapter);
        coll.releaseForDeleverage(aliceProxy, vt, KEY7, 800_000_000, new uint256[](2));
        lpVault.setPoolLocked(false);
        uint256[] memory mins = new uint256[](2);
        mins[0] = 640_000_001;
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.BelowMinimum.selector, 0, 640_000_000, 640_000_001));
        vm.prank(adapter);
        coll.releaseForDeleverage(aliceProxy, vt, KEY7, 800_000_000, mins);
        _release(adapter);
    }

    // TEST-014 verifies: REQ-VAULT-036, REQ-VAULT-037, REQ-VAULT-038, SPEC-BACK-005, SPEC-BACK-013, INV-027, ATTACK-012, ATTACK-091, Q-174
    // Sources: 5.1 TEST-014, 2.3 SPEC-BACK-013 example
    /// @notice NFT 42 after a partial removal of 1e9 and a re-credit of 1.5e9 carries $11,000 over 5.5e9 units; a
    /// removal of 2.75e9 leaves $5,500 and the withdrawal releases the last $5,500: $13,000 left the counters, exactly
    /// what was booked.
    function test_TEST_014_exitChargesFollowTheBasis() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, 1_000_000_000);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 1_000_000_000, new uint256[](2));
        lpVault.addUnits(KEY42, 1_500_000_000);
        vm.prank(adapter);
        (uint128 added,) = coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        vm.prank(adapter);
        token.mint(aliceProxy, added);
        vm.stopPrank();
        _supply(aliceProxy, added);
        _withdrawAndBurn(aliceProxy, 2_750_000_000);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 2_750_000_000, new uint256[](2));
        _release(adapter);
        BackingRecord memory r = coll.getRecord(1);
        assertEq(r.originalUsdCharge, 1_100_000_000_000);
        assertEq(r.currentUsdCharge, 550_000_000_000);
        assertEq(coll.getCounters(vt, alice).regularUsed, 550_000_000_000);
        _withdraw(aliceProxy, KEY42, 2_750_000_000);
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.regularUsed, 0);
        assertEq(k.tokenUsed[0], 0);
        assertEq(k.depositorUsed, 0);
        assertEq(_gap(), 0);
    }

    // TEST-014 verifies: REQ-VAULT-038, SPEC-BACK-005, Q-157
    /// @notice Exposure leaves the slice bucket first: a slice top-up's release drains the slice before the regular
    /// bucket.
    function test_TEST_014_sliceFirst() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        riskModule.setSlice(200_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 1_500_000_000);
        _withdraw(aliceProxy, KEY7, 1_500_000_000);
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.sliceUsed, 0, "slice drained first");
        assertEq(k.regularUsed, 1_000_000_000_000 - 0, "regular keeps NFT 42's charge");
    }

    // TEST-150 verifies: REQ-VAULT-129, REQ-VAULT-130, REQ-VAULT-131, REQ-VAULT-134, REQ-VAULT-135, REQ-VAULT-136, REQ-VAULT-140, SPEC-BACK-011, SPEC-BACK-015, INV-008, INV-058, ATTACK-026, Q-201
    // Sources: 5.1 TEST-150, 2.3 worked example "reconcile on exit"
    /// @notice After a seize-and-keep LPVaultSwap took `c` units, alice's withdrawal of NFT 42 with
    /// `previewRelease(42)` reconciles `c` from the head record into the pending balance, then releases the rest; her
    /// supply equals her credited units and `totalSupply = totalCredited + pending.units`.
    function test_TEST_150_reconcileOnWithdrawal() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.6e8);
        uint256 c = _seizeAndKeep(aliceProxy, 2400e18);
        assertGt(c, 0);
        assertEq(coll.previewRelease(INTEGRATION, KEY42), 5_000_000_000 - c, "post-reconcile units");
        assertEq(coll.previewRelease(INTEGRATION, KEY7), 4_000_000_000, "shortfall taken from the head");
        vtPrice.set(2e8);
        debt.mint(aliceProxy, 13_000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();

        uint256 units = 5_000_000_000 - c;
        uint256 usdcBefore = usdc.balanceOf(address(coll));
        _acquire(adapter);
        _withdrawAndBurn(aliceProxy, units);
        uint256[] memory booked = new uint256[](2);
        booked[0] = c * 800_000 / 1e6;
        booked[1] = c * 1_250_000 / 1e6;
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.SeizureReconciled(aliceProxy, vt, c, booked);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, units);
        _release(adapter);
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c);
        assertEq(p.amounts[0], booked[0]);
        assertEq(p.amounts[1], booked[1]);
        assertEq(usdc.balanceOf(address(coll)) - usdcBefore, booked[0], "principal held by Collateralization");
        assertEq(_shares(aliceProxy), coll.getAccountCredited(aliceProxy, vt), "supply = credited");
        assertEq(coll.getAccountCredited(aliceProxy, vt), 4_000_000_000);
        assertEq(_gap(), 0, "totalSupply = totalCredited + pending");
        assertEq(lpVault.ownerOf(KEY42), alice);
    }

    // TEST-150 verifies: REQ-VAULT-130, REQ-VAULT-143, Q-189
    /// @notice While Hub added assets differ from added shares, reconciliation is skipped and the withdrawal of a
    /// record with a shortfall reverts `UnitsMismatch`.
    function test_TEST_150_skipWhileSharesDifferFromAssets() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.6e8);
        uint256 c = _seizeAndKeep(aliceProxy, 2400e18);
        uint256 shares = IAaveV4Hub(aave.hub).getAddedShares(vtAssetId);
        vm.mockCall(aave.hub, abi.encodeCall(IAaveV4Hub.getAddedAssets, (vtAssetId)), abi.encode(shares + 1));
        assertEq(coll.previewRelease(INTEGRATION, KEY42), 5_000_000_000, "no reconcile while unequal");
        vtPrice.set(2e8);
        _acquire(adapter);
        // The proxy has debt, so a withdrawal is only possible up to its health; the check under test is the
        // ledger's: the post-reconcile amount is refused while reconciliation is skipped.
        vm.expectRevert(ICollateralizationErrors.UnitsMismatch.selector);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, 5_000_000_000 - c);
        _release(adapter);
        vm.clearMockedCalls();
    }

    // TEST-020 verifies: REQ-VAULT-074, REQ-VAULT-075, REQ-VAULT-076, REQ-VAULT-121, REQ-VAULT-132, REQ-COLL-011, REQ-COLL-021, INV-058, Q-134
    // Sources: 5.1 TEST-020
    /// @notice A record whose credit an unsettled seizure took becomes a zero-credit record at the next reconcile; it
    /// cannot be re-credited, only its depositor releases it with `releaseZeroCredit` (no burn), and a credited record
    /// reverts `RecordHasCredit`.
    function test_TEST_020_zeroCreditRelease() public {
        _pledge(alice, aliceProxy, KEY42, 1_500_000_000);
        _pledge(alice, aliceProxy, KEY7, 2_000_000_000);
        _borrow(aliceProxy, 5000e18);
        vtPrice.set(1.5e8);
        uint256 c = _seizeAndKeep(aliceProxy, 4000e18);
        assertGt(c, 2_000_000_000, "seizure larger than the head record");
        assertLt(c, 3_500_000_000);
        assertEq(coll.previewRelease(INTEGRATION, KEY7), 0, "head record fully reconciled");
        _acquire(adapter);
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        vm.prank(adapter);
        coll.releaseZeroCredit(bob, vt, KEY7);
        vm.expectEmit(address(coll));
        emit ICollateralizationEvents.CollateralReleased(2, KEY7, alice, aliceProxy, vt, 0);
        vm.prank(adapter);
        coll.releaseZeroCredit(alice, vt, KEY7);
        vm.expectRevert(ICollateralizationErrors.RecordHasCredit.selector);
        vm.prank(adapter);
        coll.releaseZeroCredit(alice, vt, KEY42);
        _release(adapter);
        assertEq(lpVault.ownerOf(KEY7), alice);
        assertEq(coll.getAccountCredited(aliceProxy, vt), 3_500_000_000 - c);
        assertEq(coll.getPending(vt).units, c);
        assertEq(_shares(aliceProxy), coll.getAccountCredited(aliceProxy, vt));
    }

    // TEST-020 verifies: REQ-VAULT-074, REQ-COLL-021, REQ-COLL-032, REQ-VAULT-059, REQ-VAULT-076, FEE-001
    /// @notice A zero-credit record stays open, is never re-credited, and its depositor still collects fees.
    function test_TEST_020_zeroCreditRecordKeepsFees() public {
        _pledge(alice, aliceProxy, KEY7, 2_000_000_000);
        _pledge(alice, aliceProxy, KEY42, 1_500_000_000);
        _borrow(aliceProxy, 5000e18);
        vtPrice.set(1.5e8);
        _seizeAndKeep(aliceProxy, 4000e18);
        lpVault.accrueFees(KEY7, 1_650_000);
        lpVault.addUnits(KEY7, 1);
        // Reconcile through releaseZeroCredit's sibling: a re-credit reconciles first, then finds 0 credited units.
        _acquire(adapter);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.NothingToRecredit.selector, KEY7));
        vm.prank(adapter);
        coll.recredit(alice, aliceProxy, vt, KEY7, "", false);
        vm.expectRevert(ICollateralizationErrors.NotDepositor.selector);
        vm.prank(adapter);
        coll.collectFees(bob, vt, KEY7);
        vm.prank(adapter);
        uint256[] memory fees = coll.collectFees(alice, vt, KEY7);
        _release(adapter);
        assertEq(fees[0], 1_650_000);
        assertEq(usdc.balanceOf(alice), 1_650_000);
    }

    // TEST-016 verifies: REQ-VAULT-024, REQ-VAULT-072, SPEC-BACK-010, INV-002, ATTACK-016, Q-066, Q-067
    // Sources: 5.1 TEST-016
    /// @notice A third party's addition to a pledged position raises its live units only: credited units and supply
    /// are unchanged, and the withdrawal returns the position with the added units to its depositor.
    function test_TEST_016_donationsStayUncredited() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        lpVault.addUnits(KEY42, 100_000_000);
        assertEq(coll.getAccountCredited(aliceProxy, vt), 5_000_000_000);
        assertEq(coll.previewRelease(INTEGRATION, KEY42), 5_000_000_000);
        assertEq(token.totalSupply(), 5_000_000_000);
        _withdraw(aliceProxy, KEY42, 5_000_000_000);
        (,,, uint128 units,) = lpVault.positions(KEY42);
        assertEq(units, 5_100_000_000, "donated units go back with the position");
        assertEq(lpVault.ownerOf(KEY42), alice);
    }

    // TEST-150 verifies: REQ-VAULT-130, SPEC-BACK-011, INV-013, ATTACK-025
    /// @notice A third party's dust liquidation that seizes 0 units succeeds on Aave without touching the vault token,
    /// moves no supplied share and so leaves no shortfall: the next withdrawal reconciles nothing.
    function test_TEST_150_dustThirdPartyLiquidationLeavesNoShortfall() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _borrow(aliceProxy, 7000e18);
        vtPrice.set(1.5e8);
        uint256 sharesBefore = _shares(aliceProxy);
        debt.mint(attacker, 1);
        vm.startPrank(attacker);
        debt.approve(aave.cdpSpoke, 1);
        IAaveV4Spoke(aave.cdpSpoke).liquidationCall(vtReserveId, debtReserveId, aliceProxy, 1, false);
        vm.stopPrank();
        assertEq(_shares(aliceProxy), sharesBefore, "no share moved");
        assertEq(token.balanceOf(attacker), 0);
        assertEq(coll.previewRelease(INTEGRATION, KEY42), 5_000_000_000, "no shortfall");
        assertEq(coll.getPending(vt).units, 0);
    }

    // TEST-017 verifies: REQ-AMM-CORE-019, REQ-AMM-CORE-011, REQ-VAULT-064
    // Sources: 2.19 REQ-AMM-CORE-019 (collectFees on an integration whose fees compound reverts FeesRolledIn)
    /// @notice For an integration whose fees compound, the LPVault's `FeesRolledIn` reaches the caller of
    /// `Collateralization.collectFees` unchanged, and the record, the credit and the custody stay as they were; the
    /// fee claim of a separate-fee integration is then paid as usual.
    /// @dev Kills: Collateralization catching, re-wrapping or ignoring the LPVault's `FeesRolledIn`.
    function test_TEST_017_rolledInFeesRevertReachesTheCaller() public {
        uint256 id = _pledge(alice, aliceProxy, KEY7, 2_000_000_000);
        BackingRecord memory before = coll.getRecord(id);
        vm.mockCallRevert(
            address(lpVault),
            abi.encodeWithSelector(IAmmIntegration.collectFees.selector),
            abi.encodeWithSelector(ILPVaultErrors.FeesRolledIn.selector)
        );
        _acquire(adapter);
        vm.expectRevert(ILPVaultErrors.FeesRolledIn.selector);
        vm.prank(adapter);
        coll.collectFees(alice, vt, KEY7);
        _release(adapter);
        vm.clearMockedCalls();
        BackingRecord memory afterRevert = coll.getRecord(id);
        assertEq(afterRevert.credited, before.credited, "credit unchanged");
        assertEq(afterRevert.currentUsdCharge, before.currentUsdCharge, "charge unchanged");
        assertEq(coll.getTotalCredited(vt), 2_000_000_000, "total unchanged");
        lpVault.accrueFees(KEY7, 1_650_000);
        _acquire(adapter);
        vm.prank(adapter);
        uint256[] memory fees = coll.collectFees(alice, vt, KEY7);
        _release(adapter);
        assertEq(fees[0], 1_650_000, "a separate-fee collection pays");
    }
}
