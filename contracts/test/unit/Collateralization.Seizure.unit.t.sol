// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CollateralizationSeizureUnitTest
/// @notice LPVaultSwap's seizure and pending paths on the real local Aave V4: the snapshot, the share-drop and
/// supply-drop checks, the largest-first debit, reconcile inside a settlement, the pending settlement and its one-sided
/// supply check, and their caller, lock and snapshot rules.
/// forge-config: default.isolate = false
contract CollateralizationSeizureUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));
    bytes32 internal constant KEY9 = bytes32(uint256(9));

    function setUp() public {
        _deployCollateralization();
    }

    /// @dev $18,000 of collateral (NFT 42 5e9, NFT 7 4e9 units at $2), 13,000 GHO borrowed, price to $1.60.
    function _underwater() internal {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _borrow(aliceProxy, 13_000e18);
        vtPrice.set(1.6e8);
    }

    function _begin(
        address proxy
    ) internal {
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(proxy, vt);
    }

    function _endLock() internal {
        vm.prank(lpVaultSwap);
        lock.release();
    }

    // TEST-056 verifies: REQ-VAULT-046, REQ-VAULT-048, REQ-VAULT-049, REQ-VAULT-050, REQ-VAULT-051, REQ-VAULT-053, REQ-VAULT-060, REQ-VAULT-062, SPEC-BACK-007, INV-014, Q-160
    // Sources: 5.1 TEST-056, 2.3 SPEC-BACK-007
    /// @notice An honest liquidation: the share drop, the units LPVaultSwap received, the supply drop after the burn
    /// and the units debited and removed are all equal; the principal reaches LPVaultSwap; fees stay with the
    /// position.
    function test_TEST_056_honestSeizure() public {
        _underwater();
        lpVault.accrueFees(KEY42, 5000);
        uint256 sharesBefore = _shares(aliceProxy);
        (uint256 seized, uint256[] memory amounts) = _liquidate(aliceProxy, 2400e18);
        assertGt(seized, 0);
        assertEq(sharesBefore - _shares(aliceProxy), seized, "share drop");
        assertEq(coll.getAccountCredited(aliceProxy, vt), 9_000_000_000 - seized, "debit");
        assertEq(_record(KEY42).credited, 5_000_000_000 - seized, "head record debited");
        assertEq(_record(KEY7).credited, 4_000_000_000);
        assertEq(amounts[0], seized * 800_000 / 1e6);
        assertEq(usdc.balanceOf(lpVaultSwap), amounts[0], "principal to LPVaultSwap");
        (,,, uint128 live, uint256 fees) = lpVault.positions(KEY42);
        assertEq(live, 5_000_000_000 - seized, "live units fall by the debit");
        assertEq(fees, 5000, "fees untouched");
        assertEq(_gap(), 0);
        assertEq(_shares(aliceProxy), coll.getAccountCredited(aliceProxy, vt));
        assertEq(lock.holder(), address(0));
    }

    // TEST-208 verifies: REQ-VAULT-050, REQ-VAULT-051, REQ-VAULT-115, REQ-VAULT-116, SPEC-BACK-007, INV-014, ATTACK-025, ATTACK-079
    // Sources: 5.1 TEST-208 (Collateralization side)
    /// @notice A report of more units than the share drop reverts `DebitMismatch`; a settlement without the burn
    /// reverts `SupplyDropMismatch(units, 0)`; a settlement naming another proxy or no snapshot reverts
    /// `SeizureMismatch`.
    function test_TEST_208_dropChecks() public {
        _underwater();
        _begin(aliceProxy);
        uint256 seized = _seizeAndKeep(aliceProxy, 2400e18);
        vm.startPrank(lpVaultSwap);
        vm.expectRevert(ICollateralizationErrors.DebitMismatch.selector);
        coll.settleSeizure(aliceProxy, vt, seized + 1, new uint256[](2));
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.SupplyDropMismatch.selector, seized, 0));
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        vm.expectRevert(ICollateralizationErrors.SeizureMismatch.selector);
        coll.settleSeizure(bobProxy, vt, seized, new uint256[](2));
        vm.stopPrank();
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized - 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralizationErrors.SupplyDropMismatch.selector, seized, seized - 1)
        );
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        vm.prank(adapter);
        token.burn(lpVaultSwap, 1);
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        vm.expectRevert(ICollateralizationErrors.SeizureMismatch.selector);
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, 0, new uint256[](2));
        _endLock();
    }

    // TEST-056 verifies: REQ-VAULT-047, REQ-VAULT-048, REQ-VAULT-114, REQ-VAULT-115, REQ-COLL-010, Q-189
    /// @notice `beginSeizure` refuses a second snapshot, an unregistered proxy and a Hub asset whose shares differ
    /// from its assets.
    function test_TEST_056_beginSeizureChecks() public {
        _underwater();
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.startPrank(lpVaultSwap);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, bobProxy));
        coll.beginSeizure(bobProxy, vt);
        coll.beginSeizure(aliceProxy, vt);
        vm.expectRevert(ICollateralizationErrors.SeizureActive.selector);
        coll.beginSeizure(aliceProxy, vt);
        vm.expectRevert(ICollateralizationErrors.SeizureActive.selector);
        coll.settlePending(vt, 1);
        coll.settleSeizure(aliceProxy, vt, 0, new uint256[](2));
        uint256 shares = IAaveV4Hub(aave.hub).getAddedShares(vtAssetId);
        vm.mockCall(aave.hub, abi.encodeCall(IAaveV4Hub.getAddedAssets, (vtAssetId)), abi.encode(shares + 1));
        vm.expectRevert(ICollateralizationErrors.SharesNotEqualAssets.selector);
        coll.beginSeizure(aliceProxy, vt);
        vm.stopPrank();
        vm.clearMockedCalls();
        _endLock();
    }

    // TEST-208 verifies: REQ-VAULT-052, REQ-COLL-028, REQ-COLL-036
    /// @notice A zero-unit settlement checks the zero drops and changes nothing; a minimums array of the wrong length
    /// reverts `LengthMismatch`.
    function test_TEST_208_zeroUnitSettlement() public {
        _underwater();
        _begin(aliceProxy);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.LengthMismatch.selector, 2, 1));
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, 0, new uint256[](1));
        vm.prank(lpVaultSwap);
        uint256[] memory amounts = coll.settleSeizure(aliceProxy, vt, 0, new uint256[](2));
        _endLock();
        assertEq(amounts.length, 2);
        assertEq(amounts[0] + amounts[1], 0);
        assertEq(lpVault.unwindCalls(), 0);
        assertEq(coll.getAccountCredited(aliceProxy, vt), 9_000_000_000);
    }

    // TEST-056 verifies: REQ-VAULT-053, REQ-VAULT-105, REQ-AMM-CORE-007
    /// @notice The summed principal must meet LPVaultSwap's per-token minimums (`BelowMinimum`), and the pool lock
    /// stops the settlement.
    function test_TEST_056_minimumsAndPoolLock() public {
        _underwater();
        _begin(aliceProxy);
        uint256 seized = _seizeAndKeep(aliceProxy, 2400e18);
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
        uint256[] memory mins = new uint256[](2);
        mins[1] = seized * 1_250_000 / 1e6 + 1;
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.BelowMinimum.selector, 1, mins[1] - 1, mins[1]));
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, seized, mins);
        lpVault.setPoolLocked(true);
        vm.expectRevert(ILPVaultErrors.PoolLocked.selector);
        vm.prank(lpVaultSwap);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        _endLock();
    }

    // TEST-057 verifies: REQ-VAULT-054, REQ-VAULT-056, REQ-VAULT-074, SPEC-BACK-006, INV-015, ATTACK-013, Q-194
    // Sources: 5.1 TEST-057 example
    /// @notice List [NFT 42 (5e9), NFT 7 (4e9), third (4e9)]; a debit of 6e9 empties NFT 42 (unlinked, still open)
    /// and leaves [NFT 7 (3e9), third (4e9)].
    function test_TEST_057_debitOrder() public {
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(alice, aliceProxy, KEY7, 4_000_000_000);
        _pledge(alice, aliceProxy, KEY9, 4_000_000_000);
        _borrow(aliceProxy, 20_000e18);
        vtPrice.set(1.0e8);
        (uint256 seized,) = _liquidate(aliceProxy, 5714e18);
        assertGt(seized, 5_000_000_000, "the example needs more than the head");
        assertLt(seized, 9_000_000_000);
        (uint256[] memory ids, BackingRecord[] memory rs) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids.length, 3, "zero-credit record still listed");
        assertEq(ids[0], 2, "NFT 7 at the head");
        assertEq(rs[0].credited, 9_000_000_000 - seized);
        assertEq(ids[1], 3);
        assertEq(rs[1].credited, 4_000_000_000, "third record untouched");
        assertEq(ids[2], 1, "NFT 42 behind the list, at 0");
        assertEq(rs[2].credited, 0);
        assertFalse(rs[2].inList);
        assertEq(rs[2].depositor, alice, "still open");
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 3);
    }

    // TEST-057 verifies: REQ-VAULT-054, REQ-COLL-015, SPEC-BACK-005, SPEC-BACK-006, INV-015
    // Sources: 2.3 SPEC-BACK-006 (partial changes keep the stored order; per-record charge release)
    /// @notice A partial seizure leaves NFT 42 at the head with fewer units than NFT 7; a re-credit of NFT 7 grows it in
    /// place; the next seizure still debits NFT 42 first and releases NFT 42's own charge, leaving NFT 7 untouched.
    function test_TEST_057_recreditAfterPartialSeizureKeepsOrder() public {
        _underwater();
        (uint256 s1,) = _liquidate(aliceProxy, 2000e18);
        assertGt(s1, 1_000_000_000, "NFT 42 must fall below NFT 7");
        assertLt(s1, 5_000_000_000);
        (uint256[] memory ids, BackingRecord[] memory rs) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids[0], 1, "partly debited NFT 42 keeps the head");
        assertLt(rs[0].credited, rs[1].credited, "list no longer credited-descending");

        lpVault.addUnits(KEY7, 2_000_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        (uint128 added,) = coll.recredit(alice, aliceProxy, vt, KEY7, "", false);
        token.mint(aliceProxy, added);
        vm.stopPrank();
        _supply(aliceProxy, added);
        vm.prank(adapter);
        lock.release();
        assertEq(added, 2_000_000_000);
        (ids, rs) = coll.getAccountRecords(aliceProxy, vt, 0, 16);
        assertEq(ids[0], 1, "re-credit does not reorder");
        assertEq(rs[1].credited, 6_000_000_000);
        uint64 charge7 = rs[1].currentUsdCharge;
        uint64 charge42 = rs[0].currentUsdCharge;

        vtPrice.set(1.2e8);
        (uint256 s2,) = _liquidate(aliceProxy, 500e18);
        assertGt(s2, 0);
        BackingRecord memory r42 = coll.getRecord(1);
        BackingRecord memory r7 = coll.getRecord(2);
        assertEq(r42.credited, 5_000_000_000 - s1 - s2, "head debited first");
        assertEq(r7.credited, 6_000_000_000, "larger record behind it untouched");
        assertEq(r7.currentUsdCharge, charge7, "NFT 7's charge untouched");
        assertEq(
            r42.currentUsdCharge,
            uint64(Math.mulDiv(r42.originalUsdCharge, r42.credited, r42.originalUnits, Math.Rounding.Ceil)),
            "NFT 42 releases by its own basis"
        );
        assertLt(r42.currentUsdCharge, charge42);
    }

    // TEST-151 verifies: REQ-VAULT-133, REQ-VAULT-134, REQ-VAULT-135, REQ-VAULT-136, REQ-VAULT-140, SPEC-BACK-011, INV-058, Q-201
    // Sources: 5.1 TEST-151
    /// @notice After an unsettled seizure of `c` units, an honest liquidation reconciles `c` into the pending balance
    /// with the snapshot as supplied shares, then debits only its own seizure; supply and credit end equal.
    function test_TEST_151_reconcileInsideSettlement() public {
        _underwater();
        uint256 c = _seizeAndKeep(aliceProxy, 1000e18);
        uint256 pendingUsdc = c * 800_000 / 1e6;
        (uint256 seized, uint256[] memory amounts) = _liquidate(aliceProxy, 1000e18);
        assertGt(seized, 0);
        assertEq(amounts[0], seized * 800_000 / 1e6, "only the new seizure reaches LPVaultSwap");
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c);
        assertEq(p.amounts[0], pendingUsdc);
        assertEq(coll.getAccountCredited(aliceProxy, vt), 9_000_000_000 - c - seized);
        assertEq(_shares(aliceProxy), coll.getAccountCredited(aliceProxy, vt));
        assertEq(_gap(), 0, "units of the kept seizure are pending, still in circulation");
    }

    // TEST-057 verifies: REQ-VAULT-055, SPEC-BACK-006
    /// @notice A liquidation that covers all the debt seizes at most the account's credit, and the debit keeps
    /// credit + seized equal to the credit before.
    function test_TEST_057_creditCoversEverySeizure() public {
        _underwater();
        (uint256 seized,) = _liquidate(aliceProxy, 13_000e18);
        assertLe(seized, 9_000_000_000);
        assertEq(coll.getAccountCredited(aliceProxy, vt) + seized, 9_000_000_000);
    }

    // TEST-152 verifies: REQ-VAULT-137, REQ-VAULT-138, REQ-VAULT-139, REQ-VAULT-141, REQ-VAULT-145, REQ-COLL-012, REQ-LOCK-007, SPEC-BACK-012, ATTACK-113, Q-201, Q-257
    // Sources: 5.1 TEST-152, 2.3 SPEC-BACK-012
    /// @notice A pending balance from a reconcile is settled in two steps: pro-rata rounded down, then the exact
    /// remainder; a call above the balance, a zero call and a call without the burn revert; the supply bound holds.
    function test_TEST_152_pendingSettlement() public {
        _underwater();
        uint256 c = _seizeAndKeep(aliceProxy, 2400e18);
        _withdrawAfterRepay(c);
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c);

        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.startPrank(lpVaultSwap);
        vm.expectRevert(ICollateralizationErrors.PendingExceeded.selector);
        coll.settlePending(vt, c + 1);
        vm.expectRevert(ICollateralizationErrors.PendingExceeded.selector);
        coll.settlePending(vt, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICollateralizationErrors.SupplyDropMismatch.selector, token.totalSupply() - 1, token.totalSupply()
            )
        );
        coll.settlePending(vt, 1);
        vm.stopPrank();
        _endLock();

        uint256 first = c / 3;
        uint256[] memory out = _settlePending(first);
        assertEq(out[0], p.amounts[0] * first / c, "pro-rata, rounded down");
        assertEq(out[1], p.amounts[1] * first / c);
        Pending memory q = coll.getPending(vt);
        assertEq(q.units, c - first);
        out = _settlePending(c - first);
        assertEq(out[0], q.amounts[0], "exact remainder");
        assertEq(out[1], q.amounts[1]);
        q = coll.getPending(vt);
        assertEq(q.units, 0);
        assertEq(q.amounts[0] + q.amounts[1], 0, "nothing stranded");
        assertEq(usdc.balanceOf(lpVaultSwap), p.amounts[0]);
        assertEq(_gap(), 0);
    }

    // TEST-152 verifies: REQ-VAULT-138, REQ-COLL-003, REQ-LOCK-010, REQ-LOCK-023
    /// @notice The seizure and pending functions refuse every caller but LPVaultSwap and need its Lock.
    function test_TEST_152_callerAndLock() public {
        bytes[3] memory calls = [
            abi.encodeCall(coll.beginSeizure, (aliceProxy, vt)),
            abi.encodeCall(coll.settleSeizure, (aliceProxy, vt, 0, new uint256[](2))),
            abi.encodeCall(coll.settlePending, (vt, 1))
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            _expectFail(adapter, calls[i], abi.encodeWithSelector(ICollateralizationErrors.NotLPVaultSwap.selector));
            _expectFail(lpVaultSwap, calls[i], abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector));
            vm.prank(adapter);
            lock.acquire();
            _expectFail(lpVaultSwap, calls[i], abi.encodeWithSelector(ICollateralizationErrors.LockNotHeld.selector));
            vm.prank(adapter);
            lock.release();
        }
        vm.prank(lpVaultSwap);
        lock.acquire();
        _expectFail(
            lpVaultSwap,
            abi.encodeCall(coll.settlePending, (makeAddr("notAToken"), 1)),
            abi.encodeWithSelector(ICollateralizationErrors.InvalidVaultToken.selector)
        );
        _endLock();
    }

    // TEST-241 verifies: REQ-VAULT-029, REQ-COLL-007, SPEC-BACK-009, SPEC-BACK-012, INV-080, Q-257
    // Sources: 5.1 TEST-241 (Collateralization side)
    /// @notice An orphan burn of seized units opens a positive gap; pledges and withdrawals keep it, and a pending
    /// settlement up to the gap passes the one-sided supply check without a new burn.
    function test_TEST_241_backingGap() public {
        _underwater();
        uint256 c = _seizeAndKeep(aliceProxy, 2400e18);
        vm.prank(adapter);
        token.burn(lpVaultSwap, c);
        assertEq(_gap(), int256(c), "orphan burn opens the gap");
        _withdrawAfterRepay(c);
        assertEq(_gap(), int256(c), "a reconciled withdrawal keeps the gap");
        _pledge(bob, bobProxy, KEY9, 1_000_000_000);
        assertEq(_gap(), int256(c), "a pledge keeps the gap");
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.settlePending(vt, c);
        _endLock();
        assertEq(_gap(), 0, "settling the orphaned units closes it");
        assertEq(coll.getPending(vt).units, 0);
    }

    // TEST-177 verifies: REQ-VAULT-146, Q-217
    /// @notice A pending balance holding 0 of a token pays only the other one; the zero transfer is never attempted.
    function test_TEST_177_zeroTransferSkipped() public {
        _underwater();
        uint256 c = _seizeAndKeep(aliceProxy, 2400e18);
        _withdrawAfterRepay(c);
        // Drain USDC from the pending balance with a first small settlement, then arm the zero-transfer revert.
        Pending memory p = coll.getPending(vt);
        assertGt(p.amounts[0], 0);
        usdc.setRevertOnZero(true);
        usdt.setRevertOnZero(true);
        uint256[] memory out = _settlePending(1);
        assertEq(out[0], p.amounts[0] / c, "1 unit's share rounds to 0 or 1 raw unit");
        out = _settlePending(c - 1);
        assertEq(coll.getPending(vt).units, 0);
    }

    // TEST-151 verifies: REQ-VAULT-135, SPEC-BACK-015, REQ-VAULT-061, Q-271
    /// @notice A token whose issuer switched on a transfer fee is booked into the pending balance at the amount
    /// received, so the final settlement transfers exactly what Collateralization holds.
    function test_TEST_151_pendingBooksReceivedAmounts() public {
        _underwater();
        uint256 c = _seizeAndKeep(aliceProxy, 2400e18);
        usdt.setFeeBps(10);
        _withdrawAfterRepay(c);
        uint256 removed = c * 1_250_000 / 1e6;
        Pending memory p = coll.getPending(vt);
        assertEq(p.amounts[1], removed - removed * 10 / 10_000, "received, not removed");
        assertEq(usdt.balanceOf(address(coll)), p.amounts[1]);
        usdt.setFeeBps(0);
        _settlePending(c);
        assertEq(usdt.balanceOf(address(coll)), 0);
    }

    // ─── Helpers ───

    /// @notice Alice repays, then withdraws NFT 42 at its post-reconcile units, which moves the kept seizure `c` into
    /// the pending balance.
    function _withdrawAfterRepay(
        uint256 c
    ) internal {
        vtPrice.set(2e8);
        debt.mint(aliceProxy, 13_000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();
        _withdraw(aliceProxy, KEY42, 5_000_000_000 - c);
    }

    function _expectFail(
        address caller,
        bytes memory data,
        bytes memory err
    ) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(coll).call(data);
        assertFalse(ok, "call succeeded");
        assertEq(ret, err, "revert data");
    }
}
