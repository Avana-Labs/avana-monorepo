// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @title CollateralizationViewsUnitTest
/// @notice Views under the Lock, the immutable getters the VaultTokenFactory reads, the rescue-unit exception for the
/// AaveAdapter, market paging, constructor validation and the indebted mark.
/// forge-config: default.isolate = false
contract CollateralizationViewsUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    // TEST-060 verifies: REQ-VAULT-091, REQ-VAULT-125, REQ-VAULT-145, REQ-LOCK-016, ATTACK-093
    // Sources: 2.3 REQ-VAULT-091, 2.16 REQ-LOCK-016
    /// @notice Every ledger view reverts `Locked` while a member holds the Lock, for any caller but the holder; the
    /// holder reads them; the immutable getters and `lpVaultOf` always answer.
    function test_TEST_060_viewsLockedForOthers() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        bytes[13] memory views = [
            abi.encodeCall(coll.getRecord, (1)),
            abi.encodeCall(coll.recordIdOf, (INTEGRATION, KEY42)),
            abi.encodeCall(coll.nextRecordId, ()),
            abi.encodeCall(coll.getAccountRecords, (aliceProxy, vt, 0, 16)),
            abi.encodeCall(coll.getOpenRecordCount, (aliceProxy, vt)),
            abi.encodeCall(coll.getAccountCredited, (aliceProxy, vt)),
            abi.encodeCall(coll.getTotalCredited, (vt)),
            abi.encodeCall(coll.getPending, (vt)),
            abi.encodeCall(coll.getMarketRecords, (vt, 0, 10)),
            abi.encodeCall(coll.getMarketRecordCount, (vt)),
            abi.encodeCall(coll.getMarketDebtFree, (vt)),
            abi.encodeCall(coll.getCounters, (vt, alice)),
            abi.encodeCall(coll.previewRelease, (INTEGRATION, KEY42))
        ];
        address[2] memory members = [adapter, lpVaultSwap];
        for (uint256 m = 0; m < 2; ++m) {
            vm.prank(members[m]);
            lock.acquire();
            for (uint256 i = 0; i < views.length; ++i) {
                (bool ok, bytes memory ret) = address(coll).staticcall(views[i]);
                assertFalse(ok, "readable by an outsider under the Lock");
                assertEq(ret, abi.encodeWithSelector(ICollateralizationErrors.Locked.selector));
                vm.prank(members[m]);
                (ok,) = address(coll).staticcall(views[i]);
                assertTrue(ok, "holder reads");
            }
            (bool okR,) = address(coll).staticcall(abi.encodeCall(coll.previewRecredit, (INTEGRATION, KEY42)));
            assertFalse(okR);
            assertEq(coll.ADAPTER(), adapter);
            assertEq(coll.LP_VAULT_SWAP(), lpVaultSwap);
            assertEq(coll.RISK_MODULE(), address(riskModule));
            assertEq(coll.LOCK(), address(lock));
            assertEq(coll.VAULT_TOKEN_FACTORY(), address(factory));
            assertEq(coll.lpVaultOf(INTEGRATION), address(lpVault));
            vm.prank(members[m]);
            lock.release();
        }
    }

    // TEST-236 verifies: REQ-COLL-018, REQ-LOCK-016, SPEC-BACK-014, Q-253
    // Sources: 2.3 REQ-COLL-018 example
    /// @notice `getAccountRescueUnits` and `poolUnits` answer any caller while the Lock is free or held by the
    /// AaveAdapter (the RiskModule reads them inside a borrow) and revert `Locked` while LPVaultSwap holds it, for
    /// LPVaultSwap itself too.
    function test_TEST_236_rescueUnitsReadableUnderAdapter() public {
        riskModule.setRescue(true);
        _pledge(alice, aliceProxy, KEY42, 1_000_000_000);
        bytes32 key = keccak256(abi.encode(INTEGRATION, pool, bytes32(0)));
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 1_000_000_000);
        assertEq(coll.poolUnits(key), 1_000_000_000);
        vm.prank(adapter);
        lock.acquire();
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 1_000_000_000, "readable under the Adapter");
        assertEq(coll.poolUnits(key), 1_000_000_000, "pool units readable under the Adapter");
        vm.prank(adapter);
        lock.release();
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.expectRevert(ICollateralizationErrors.Locked.selector);
        coll.getAccountRescueUnits(aliceProxy, vt);
        vm.expectRevert(ICollateralizationErrors.Locked.selector);
        coll.poolUnits(key);
        vm.prank(lpVaultSwap);
        vm.expectRevert(ICollateralizationErrors.Locked.selector);
        coll.poolUnits(key);
        vm.prank(lpVaultSwap);
        lock.release();
    }

    // TEST-236 verifies: REQ-COLL-016, SPEC-BACK-014, INV-082
    /// @notice Rescue units are capped at credited units after a debit and leave the account sum when the record
    /// closes.
    function test_TEST_236_rescueUnitsCappedAndDropped() public {
        riskModule.setRescue(true);
        _pledge(alice, aliceProxy, KEY42, 1_000_000_000);
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, 700_000_000);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 700_000_000, new uint256[](2));
        vm.prank(adapter);
        lock.release();
        assertEq(_record(KEY42).rescueUnits, 300_000_000, "min(rescue, credited)");
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 300_000_000);
        _withdraw(aliceProxy, KEY42, 300_000_000);
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 0, "closed record drops its rescue units");
    }

    // TEST-010 verifies: REQ-VAULT-128, REQ-VAULT-016
    /// @notice Market paging returns every open record once, and a close moves the last record into the closed one's
    /// place.
    function test_TEST_010_marketPaging() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(bob, bobProxy, KEY7, 4_000_000_000);
        _pledge(alice, aliceProxy, _key(9), 1_000_000_000);
        assertEq(coll.getMarketRecordCount(vt), 3);
        (uint256[] memory ids, BackingRecord[] memory rs) = coll.getMarketRecords(vt, 1, 5);
        assertEq(ids.length, 2);
        assertEq(ids[0], 2);
        assertEq(rs[0].depositor, bob);
        _withdraw(aliceProxy, KEY42, 5_000_000_000);
        (ids,) = coll.getMarketRecords(vt, 0, 5);
        assertEq(ids.length, 2);
        assertEq(ids[0], 3, "last record moved into the closed slot");
        assertEq(ids[1], 2);
        (ids,) = coll.getMarketRecords(vt, 0, 0);
        assertEq(ids.length, 0, "limit 0");
    }

    // TEST-236 verifies: REQ-COLL-018, REQ-VAULT-128
    // Sources: 2.3 REQ-COLL-018 (0 for a record at 0 credited units), REQ-VAULT-128 (seizure list then zero-credit list)
    /// @notice `previewRecredit` is 0 for a record with no live units above its credit and for a record a seizure
    /// took to 0 credited units; account paging walks the seizure list, then the zero-credit list, and an offset past
    /// the end returns nothing.
    function test_TEST_236_previewRecreditZeroCasesAndAccountPaging() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        assertEq(coll.previewRecredit(INTEGRATION, KEY7), 0, "no live units above credit");
        lpVault.addUnits(KEY7, 1000);
        assertEq(coll.previewRecredit(INTEGRATION, KEY7), 1000);
        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.6e8);
        (uint256 seized,) = _liquidate(aliceProxy, 8000e18);
        assertGt(seized, 5_000_000_000, "the head record is emptied");
        assertEq(coll.previewRecredit(INTEGRATION, KEY42), 0, "a record at 0 credited units");
        (uint256[] memory ids,) = coll.getAccountRecords(aliceProxy, vt, 0, 1);
        assertEq(ids.length, 1);
        assertEq(ids[0], 2, "seizure list first");
        (ids,) = coll.getAccountRecords(aliceProxy, vt, 1, 16);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1, "then the zero-credit list");
        (ids,) = coll.getAccountRecords(aliceProxy, vt, 2, 16);
        assertEq(ids.length, 0, "offset past the end");
    }

    // TEST-150 verifies: REQ-VAULT-119, REQ-COLL-018
    /// @notice The previews revert `RecordNotFound` without an open record.
    function test_TEST_150_previewsNeedARecord() public {
        vm.expectRevert(ICollateralizationErrors.RecordNotFound.selector);
        coll.previewRelease(INTEGRATION, KEY42);
        vm.expectRevert(ICollateralizationErrors.RecordNotFound.selector);
        coll.previewRecredit(INTEGRATION, KEY42);
    }

    // TEST-272 verifies: REQ-COLL-038, REQ-COLL-039, REQ-COLL-040, Q-355, Q-396
    // Sources: 2.3 REQ-COLL-039, REQ-COLL-040
    /// @notice The indebted mark: set once per account on borrow, cleared by the Adapter or LPVaultSwap only when the
    /// Spoke reports no borrow; an unbound proxy is refused; a stale mark only keeps `getMarketDebtFree` false.
    function test_TEST_272_debtMark() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        assertTrue(coll.getMarketDebtFree(vt));
        vm.startPrank(adapter);
        lock.acquire();
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, bobProxy));
        coll.markIndebted(bobProxy);
        coll.markIndebted(aliceProxy);
        coll.markIndebted(aliceProxy);
        vm.stopPrank();
        _borrow(aliceProxy, 1000e18);
        vm.startPrank(adapter);
        coll.markDebtFree(aliceProxy);
        lock.release();
        vm.stopPrank();
        assertFalse(coll.getMarketDebtFree(vt), "still indebted");
        debt.mint(aliceProxy, 1000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ICollateralizationErrors.NotAdapter.selector);
        coll.markDebtFree(aliceProxy);
        vm.prank(lpVaultSwap);
        vm.expectRevert(ICollateralizationErrors.LockNotHeld.selector);
        coll.markDebtFree(aliceProxy);
        vm.startPrank(lpVaultSwap);
        lock.acquire();
        coll.markDebtFree(aliceProxy);
        coll.markDebtFree(aliceProxy);
        lock.release();
        vm.stopPrank();
        assertTrue(coll.getMarketDebtFree(vt), "count back to 0");
    }

    // TEST-272 verifies: REQ-COLL-040
    /// @notice A failing Spoke read leaves the mark and never reverts for an authorized caller.
    function test_TEST_272_debtFreeNeverReverts() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        coll.markIndebted(aliceProxy);
        vm.mockCallRevert(
            aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy)), abi.encode("down")
        );
        coll.markDebtFree(aliceProxy);
        lock.release();
        vm.stopPrank();
        vm.clearMockedCalls();
        assertFalse(coll.getMarketDebtFree(vt));
    }

    // TEST-108 verifies: REQ-COLL-001, REQ-COLL-002
    // Sources: 2.3 REQ-COLL-002, deployment checks
    /// @notice The constructor refuses a zero or repeated address.
    function test_TEST_108_constructorFailsClosed() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        address c = makeAddr("c");
        address d = makeAddr("d");
        address e = makeAddr("e");
        bytes memory code = vm.getCode("Collateralization.sol:Collateralization");
        address[5][3] memory bad = [[address(0), b, c, d, e], [a, b, c, d, a], [a, b, b, d, e]];
        for (uint256 i = 0; i < bad.length; ++i) {
            bytes memory init = bytes.concat(code, abi.encode(bad[i][0], bad[i][1], bad[i][2], bad[i][3], bad[i][4]));
            address deployed;
            assembly ("memory-safe") {
                deployed := create(0, add(init, 0x20), mload(init))
            }
            assertEq(deployed, address(0), "deployment must fail");
        }
    }
}
