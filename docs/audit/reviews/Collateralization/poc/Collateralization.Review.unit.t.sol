// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationDebtMark} from "../../src/custody/collateralization/ICollateralizationDebtMark.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {console2} from "forge-std/console2.sol";

/// forge-config: default.isolate = false
contract CollateralizationReviewTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
    }

    /// SPEC-BACK-006 / INV-015 claim a debit equals the credited-descending order (Q-194). After a partial removal of
    /// the head record, a seizure still takes the smaller head record first.
    function test_POC_orderDivergesFromCreditedDescending() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000); // id 1, head
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000); // id 2
        // Partial removal of 2e9 from record 1: 3e9 left, still at the head.
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, 2_000_000_000);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 2_000_000_000, new uint256[](2));
        vm.prank(adapter);
        lock.release();
        (uint256[] memory ids,) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids[0], 1);
        assertEq(_record(KEY42).credited, 3_000_000_000);
        assertEq(_record(KEY7).credited, 4_000_000_000);

        _borrow(aliceProxy, 10_500e18);
        vtPrice.set(1.6e8);
        (uint256 seized,) = _liquidate(aliceProxy, 2_000e18);
        assertGt(seized, 0);
        assertLt(seized, 3_000_000_000);
        // Q-194 order would debit record 2 (4e9 > 3e9); the list debits record 1.
        assertEq(_record(KEY42).credited, 3_000_000_000 - seized, "smaller head record debited");
        assertEq(_record(KEY7).credited, 4_000_000_000, "larger record untouched");
    }

    /// `markDebtFree` swallows an out-of-gas inside its staticcall: with a gas budget in a window the call succeeds and
    /// the mark stays although the account has no debt.
    function test_POC_markDebtFreeSilentUnderGasLimit() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        vm.prank(adapter);
        lock.acquire();
        vm.prank(adapter);
        coll.markIndebted(aliceProxy);
        uint256 silentAt;
        uint256 clearsAt;
        for (uint256 g = 2_000; g < 400_000; g += 250) {
            vm.prank(adapter);
            (bool ok,) = address(coll).call{gas: g}(abi.encodeCall(ICollateralizationDebtMark.markDebtFree, (aliceProxy)));
            if (!ok) continue;
            // Read the mark through storage: slot of `indebted` is not needed, use the view after the loop.
            if (silentAt == 0) silentAt = g;
            // Did this call clear it? Probe by calling again with ample gas inside a snapshot.
            uint256 snap = vm.snapshotState();
            vm.prank(adapter);
            lock.release();
            bool free = coll.getMarketDebtFree(vt);
            vm.revertToState(snap);
            if (free) {
                clearsAt = g;
                break;
            }
            // Not cleared: undo nothing (no state changed) and continue.
        }
        console2.log("first successful gas (mark kept)", silentAt);
        console2.log("first gas that clears the mark", clearsAt);
        assertGt(silentAt, 0);
        assertGt(clearsAt, silentAt, "a window exists where markDebtFree returns without clearing");
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).borrowCount, 0);
    }

    /// Collateralization's own cost of a worst-shaped settlement: 16 records, a reconcile that walks most of the list,
    /// then a seizure debit (mock LPVault, so AMM costs are excluded).
    function test_POC_settleSeizureGas16Records() public {
        for (uint256 i = 1; i <= 16; ++i) {
            _pledge(alice, aliceProxy, _key(100 + i), 1_000_000_000);
        }
        _borrow(aliceProxy, 25_000e18);
        vtPrice.set(1.5e8);
        // Non-conforming seizure: units left with LPVaultSwap, never settled.
        uint256 kept = _seizeAndKeep(aliceProxy, 9_000e18);
        console2.log("kept units", kept);
        vtPrice.set(1.0e8);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        uint256 seized = _seizeAndKeep(aliceProxy, 3_000e18);
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
        uint256 g0 = gasleft();
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        uint256 used = g0 - gasleft();
        vm.prank(lpVaultSwap);
        lock.release();
        console2.log("seized units", seized);
        console2.log("settleSeizure gas (mock LPVault)", used);
        (uint256[] memory ids,) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        console2.log("open records", ids.length);
        assertEq(_shares(aliceProxy), coll.getAccountCredited(aliceProxy, vt));
    }
}

/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 200
contract CollateralizationReviewFuzz is CollateralizationFixture {
    function setUp() public {
        _deployCollateralization();
    }

    function _check(address proxy) internal view {
        (uint256[] memory ids,) = coll.getAccountRecords(proxy, vt, 0, 16);
        uint256 sum;
        uint256 prevPos = type(uint256).max;
        for (uint256 i = 0; i < ids.length; ++i) {
            (uint128 credited, uint128 rescue) = (coll.getRecord(ids[i]).credited, coll.getRecord(ids[i]).rescueUnits);
            sum += credited;
            assertLe(rescue, credited, "rescue <= credited");
            if (credited == 0) prevPos = 0; // zero-credit tail
            else assertTrue(prevPos != 0, "credited record after a zero-credit one");
        }
        assertEq(sum, coll.getAccountCredited(proxy, vt), "account sum");
        assertEq(coll.getAccountCredited(proxy, vt), coll.getTotalCredited(vt), "one account");
        assertEq(_gap(), 0, "gap");
        assertEq(_shares(proxy), coll.getAccountCredited(proxy, vt), "shares == credited");
    }

    function testFuzz_POC_backingSequence(uint32[6] memory sizes, uint8 partialIdx, uint32 partialAmt, uint16 keepDebt, uint16 liqDebt) public {
        uint256 n = 6;
        uint256 total;
        for (uint256 i = 0; i < n; ++i) {
            uint128 u = uint128(bound(sizes[i], 100_000_000, 3_000_000_000));
            _pledge(alice, aliceProxy, _key(1000 + i), u);
            total += u;
        }
        _check(aliceProxy);
        // Partial removal of one record.
        bytes32 pk = _key(1000 + (partialIdx % n));
        uint128 cr = _record(pk).credited;
        uint128 amt = uint128(bound(partialAmt, 1, cr - 1));
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, amt);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, pk, amt, new uint256[](2));
        vm.prank(adapter);
        lock.release();
        total -= amt;
        _check(aliceProxy);
        // Borrow and make liquidatable.
        uint256 debtAmt = total * 2 * 1e12 * 75 / 100; // 75% of $2 value, 18-dec
        _borrow(aliceProxy, debtAmt);
        vtPrice.set(1.7e8);
        // Non-conforming seizure, kept and never settled.
        uint256 kd = bound(keepDebt, 1, 2000) * 1e18;
        uint256 kept = _seizeAndKeep(aliceProxy, kd);
        // Honest liquidation reconciles the shortfall first.
        vtPrice.set(1.4e8);
        uint256 ld = bound(liqDebt, 1, 2000) * 1e18;
        _liquidate(aliceProxy, ld);
        assertEq(coll.getPending(vt).units, kept, "pending = kept");
        // Gap: kept units still circulate (held by LPVaultSwap) and are backed by pending.
        _check(aliceProxy);
        if (kept != 0) {
            _settlePending(kept);
            _check(aliceProxy);
        }
    }
}
