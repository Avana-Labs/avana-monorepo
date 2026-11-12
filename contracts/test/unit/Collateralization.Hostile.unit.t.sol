// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {Pending} from "../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollateralizationLedgerModel} from "./Collateralization.LedgerModel.sol";

/// @title CollateralizationHostileUnitTest
/// @notice A hostile LPVaultSwap against the real ledger (the Collateralization side of TEST-131 and TEST-154): the
/// C-QNT-1 regression (records of 1,000 and 800 units, 315 units seized and kept, then reconciled at the borrower's
/// exits and settled by an honest LPVaultSwap), a settlement that names another account's records or more units than
/// the share drop, and a settlement that claims a seizure after the borrower's own withdrawal.
/// forge-config: default.isolate = false
contract CollateralizationHostileUnitTest is CollateralizationLedgerModel {
    uint128 internal constant U1000 = 1_000_000_000;
    uint128 internal constant U800 = 800_000_000;

    function setUp() public {
        _deployCollateralization();
    }

    // TEST-154 verifies: INV-001, INV-008, INV-058, REQ-VAULT-129, REQ-VAULT-131, REQ-VAULT-134, REQ-VAULT-136, REQ-VAULT-139, SPEC-BACK-011, SPEC-BACK-012, Q-201
    // Sources: 5.1 TEST-154 (C-QNT-1), QNT-07, QNT-T09
    /// @notice Records of 1,000 and 800 units; a hostile LPVaultSwap seizes about 315 units and keeps them. The
    /// borrower repays and withdraws NFT 42: the 315-unit shortfall is reconciled into pending and NFT 42 returns with
    /// its remaining 685 units of liquidity; NFT 7 returns with all 800. An honest LPVaultSwap then settles the 315
    /// pending units, after which the market's supply, credit and pending balance are all 0 and no position is left
    /// in custody.
    function test_TEST_154_cQnt1Regression() public {
        uint256 r42 = _doPledge(alice, aliceProxy, _key(42), U1000);
        uint256 r7 = _doPledge(alice, aliceProxy, _key(7), U800);
        _borrow(aliceProxy, 1600e18);
        vtPrice.set(1.05e8);
        uint256 c = _doKeep(aliceProxy, 315e18);
        assertApproxEqAbs(c, 315_000_000, 1, "about 315 units seized and kept");
        _check("kept by the hostile LPVaultSwap");
        assertEq(token.balanceOf(lpVaultSwap), c, "the hostile LPVaultSwap holds the units");

        vtPrice.set(2e8);
        _repayAll(aliceProxy);
        assertEq(coll.previewRelease(INTEGRATION, _key(42)), U1000 - c, "NFT 42 previews 685 units");
        _doWithdraw(r42);
        _check("NFT 42 withdrawn");
        (,,, uint128 live42,) = lpVault.positions(_key(42));
        assertEq(live42, U1000 - c, "NFT 42 returns with its remaining liquidity");
        assertEq(lpVault.ownerOf(_key(42)), alice);
        Pending memory p = coll.getPending(vt);
        assertEq(p.units, c, "315 pending");
        assertEq(p.amounts[0], c * 800_000 / 1e6);
        assertEq(p.amounts[1], c * 1_250_000 / 1e6);

        _doWithdraw(r7);
        _check("NFT 7 withdrawn");
        (,,, uint128 live7,) = lpVault.positions(_key(7));
        assertEq(live7, U800, "NFT 7 untouched by the reconcile");
        assertEq(lpVault.ownerOf(_key(7)), alice);

        _doSettlePending(c);
        _check("pending settled by an honest LPVaultSwap");
        assertEq(token.totalSupply(), 0, "market supply 0");
        assertEq(coll.getTotalCredited(vt), 0);
        assertEq(coll.getPending(vt).units, 0);
        assertEq(usdc.balanceOf(address(coll)) + usdt.balanceOf(address(coll)), 0, "no pool token left behind");
        assertEq(usdc.balanceOf(lpVaultSwap), p.amounts[0], "the reconciled principal reached LPVaultSwap");
    }

    // TEST-131 verifies: REQ-VAULT-049, REQ-VAULT-050, REQ-VAULT-051, REQ-VAULT-140, REQ-VAULT-043, SPEC-BACK-007, ATTACK-025, ATTACK-079
    // Sources: 5.1 TEST-131 (cannot debit another account's records)
    /// @notice With a snapshot of alice, a hostile LPVaultSwap seizes bob instead: settling bob reverts
    /// `SeizureMismatch`, settling alice for bob's units reverts `DebitMismatch` (alice's shares did not drop), and
    /// after the Lock session both ledgers are unchanged; bob's own next exit reconciles the kept units.
    function test_TEST_131_cannotDebitAnotherAccount() public {
        _doPledge(alice, aliceProxy, _key(1), 5_000_000_000);
        uint256 b2 = _doPledge(bob, bobProxy, _key(2), 5_000_000_000);
        _borrow(aliceProxy, 7000e18);
        _borrow(bobProxy, 7000e18);
        vtPrice.set(1.6e8);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        uint256 seized = _seizeAndKeep(bobProxy, 1000e18);
        mKept[bobProxy] += seized;
        mKeptHeld += seized;
        vm.prank(adapter);
        token.burn(lpVaultSwap, seized);
        vm.startPrank(lpVaultSwap);
        vm.expectRevert(ICollateralizationErrors.SeizureMismatch.selector);
        coll.settleSeizure(bobProxy, vt, seized, new uint256[](2));
        vm.expectRevert(ICollateralizationErrors.DebitMismatch.selector);
        coll.settleSeizure(aliceProxy, vt, seized, new uint256[](2));
        lock.release();
        vm.stopPrank();
        // The orphan burn lowered the supply with no debit: the gap is the units burned.
        assertEq(_gap(), int256(seized), "orphan burn opens a gap of the burned units");
        assertEq(coll.getAccountCredited(aliceProxy, vt), 5_000_000_000, "alice untouched");
        assertEq(coll.getAccountCredited(bobProxy, vt), 5_000_000_000, "bob not debited by a mismatched settlement");

        vtPrice.set(2e8);
        _repayAll(bobProxy);
        uint256 rest = coll.previewRelease(INTEGRATION, _key(2));
        assertEq(rest, 5_000_000_000 - seized, "bob's exit reconciles the kept units");
        _withdraw(bobProxy, _key(2), rest);
        assertEq(coll.getPending(vt).units, seized, "the burned units sit as pending");
        assertEq(_shares(bobProxy), 0);
        assertEq(lpVault.ownerOf(_key(2)), bob, "no position stranded");
        assertEq(b2, 2);
    }

    // TEST-131 verifies: REQ-VAULT-051, REQ-VAULT-116, SPEC-BACK-007, ATTACK-079
    // Sources: 5.1 TEST-131 (no release without the matching share drop)
    /// @notice A snapshot taken, then the borrower's own withdrawal (an Adapter call between the two) lowers the
    /// proxy's shares: a settlement claiming those units as seized reverts `SupplyDropMismatch` without the burn and
    /// cannot be completed by LPVaultSwap, which holds no units to burn.
    function test_TEST_131_withdrawalIsNotASeizure() public {
        _doPledge(alice, aliceProxy, _key(1), 5_000_000_000);
        vm.prank(lpVaultSwap);
        lock.acquire();
        vm.prank(lpVaultSwap);
        coll.beginSeizure(aliceProxy, vt);
        // The proxy's own withdrawal under the LPVaultSwap Lock: shares fall, the vault token supply does not.
        vm.prank(aliceProxy);
        IAaveV4Spoke(aave.cdpSpoke).withdraw(vtReserveId, 1_000_000_000, aliceProxy);
        vm.prank(lpVaultSwap);
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.SupplyDropMismatch.selector, 1_000_000_000, 0));
        coll.settleSeizure(aliceProxy, vt, 1_000_000_000, new uint256[](2));
        assertEq(token.balanceOf(lpVaultSwap), 0, "LPVaultSwap holds nothing it could have burned");
        vm.prank(lpVaultSwap);
        vm.expectRevert(ICollateralizationErrors.DebitMismatch.selector);
        coll.settleSeizure(aliceProxy, vt, 0, new uint256[](2));
        vm.prank(lpVaultSwap);
        lock.release();
        assertEq(coll.getAccountCredited(aliceProxy, vt), 5_000_000_000, "no debit");
    }
}

/// @notice A Lock member stand-in etched at LPVaultSwap's address: one call is one Lock session of one transaction.
contract SnapshotMemberSim {
    function exec(
        address lock,
        address target,
        bytes calldata first,
        bytes calldata second
    ) external returns (bool ok1, bytes memory ret1, bool ok2, bytes memory ret2) {
        ILockMember(lock).acquire();
        (ok1, ret1) = target.call(first);
        if (second.length != 0) (ok2, ret2) = target.call(second);
        ILockMember(lock).release();
    }

    /// @notice One Lock session that makes one call and requires it to succeed.
    function run(
        address lock,
        address target,
        bytes calldata data
    ) external {
        ILockMember(lock).acquire();
        (bool ok,) = target.call(data);
        require(ok, "session call failed");
        ILockMember(lock).release();
    }
}

interface ILockMember {
    function acquire() external;
    function release() external;
}

/// @title CollateralizationSnapshotScopeUnitTest
/// @notice The seizure snapshot lives in transient storage (EIP-1153): with each test call its own transaction (the
/// default isolation), a snapshot taken in one transaction is gone in the next, so a settlement can never use another
/// transaction's snapshot; a reverted `beginSeizure` leaves none; and inside one transaction an active snapshot blocks
/// `settlePending`.
contract CollateralizationSnapshotScopeUnitTest is CollateralizationFixture {
    function setUp() public {
        _deployCollateralization();
        bytes memory sim = address(new SnapshotMemberSim()).code;
        vm.etch(lpVaultSwap, sim);
        vm.etch(adapter, sim);
        // Each test call is its own transaction here, and the Lock is transient: register the proxy in one session.
        SnapshotMemberSim(adapter).run(address(lock), vt, abi.encodeWithSignature("addValidProxy(address)", aliceProxy));
    }

    // TEST-056 verifies: REQ-VAULT-048, REQ-VAULT-049, REQ-VAULT-115, REQ-VAULT-138
    // Sources: 2.3 REQ-VAULT-049 (snapshot taken and used inside one Lock session of one transaction)
    /// @notice A snapshot from a previous transaction does not exist: `settleSeizure` reverts `SeizureMismatch` and a
    /// new `beginSeizure` succeeds without `SeizureActive`; within one transaction the snapshot blocks `settlePending`
    /// (`SeizureActive`) and a second `beginSeizure`.
    function test_TEST_056_snapshotDoesNotOutliveItsTransaction() public {
        bytes memory begin = abi.encodeCall(coll.beginSeizure, (aliceProxy, vt));
        bytes memory settleZero = abi.encodeCall(coll.settleSeizure, (aliceProxy, vt, 0, new uint256[](2)));
        (bool ok1,,,) = _session(begin, "");
        assertTrue(ok1, "snapshot taken");
        (bool ok2, bytes memory ret2,,) = _session(settleZero, "");
        assertFalse(ok2, "a later transaction finds no snapshot");
        assertEq(ret2, abi.encodeWithSelector(ICollateralizationErrors.SeizureMismatch.selector));
        (bool ok3,, bool ok4, bytes memory ret4) = _session(begin, abi.encodeCall(coll.settlePending, (vt, 1)));
        assertTrue(ok3, "a new snapshot in a new transaction");
        assertFalse(ok4);
        assertEq(ret4, abi.encodeWithSelector(ICollateralizationErrors.SeizureActive.selector), "pending blocked");
        (,, bool ok6, bytes memory ret6) = _session(begin, begin);
        assertFalse(ok6);
        assertEq(
            ret6, abi.encodeWithSelector(ICollateralizationErrors.SeizureActive.selector), "one snapshot at a time"
        );
        (,, bool ok7,) = _session(begin, settleZero);
        assertTrue(ok7, "same-transaction settlement of a zero seizure");
    }

    // TEST-056 verifies: REQ-VAULT-048, REQ-COLL-010
    /// @notice A `beginSeizure` that reverts (an unregistered proxy) stores no snapshot: a settlement after it in the
    /// same transaction reverts `SeizureMismatch`.
    function test_TEST_056_revertedBeginLeavesNoSnapshot() public {
        address stranger = makeAddr("strangerProxy");
        (bool ok1, bytes memory ret1, bool ok2, bytes memory ret2) = _session(
            abi.encodeCall(coll.beginSeizure, (stranger, vt)),
            abi.encodeCall(coll.settleSeizure, (stranger, vt, 0, new uint256[](2)))
        );
        assertFalse(ok1);
        assertEq(ret1, abi.encodeWithSelector(ICollateralizationErrors.UnknownProxy.selector, stranger));
        assertFalse(ok2);
        assertEq(ret2, abi.encodeWithSelector(ICollateralizationErrors.SeizureMismatch.selector));
    }

    function _session(
        bytes memory first,
        bytes memory second
    ) internal returns (bool ok1, bytes memory ret1, bool ok2, bytes memory ret2) {
        (ok1, ret1, ok2, ret2) = SnapshotMemberSim(lpVaultSwap).exec(address(lock), address(coll), first, second);
    }
}
