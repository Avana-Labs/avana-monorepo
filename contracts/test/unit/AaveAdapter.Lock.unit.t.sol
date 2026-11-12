// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationUser} from "../../src/custody/collateralization/ICollateralizationUser.sol";
import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IAaveAdapterCollateral} from "../../src/policy/aave-adapter/IAaveAdapterCollateral.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterSettlement} from "../../src/policy/aave-adapter/IAaveAdapterSettlement.sol";
import {IAaveAdapterUser} from "../../src/policy/aave-adapter/IAaveAdapterUser.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title AaveAdapterLockUnitTest
/// @notice The Adapter side of the protocol Lock (2.16) on the real Lock, Collateralization and Aave V4 Spoke: every
/// user entry point takes the Lock before any other external call and frees it as its last step; the Lock is held by
/// the Adapter during every inner call (custody, unwind, token transfers, LPVaultSwap's callbacks); a re-entry from a
/// token or position callback reverts `LockHeld`; Collateralization's rescue-unit view answers inside the Adapter's calls
/// and refuses LPVaultSwap's; `burnSeized` and the deleverage callbacks run only under the right holder.
/// forge-config: default.isolate = false
contract AaveAdapterLockUnitTest is AaveAdapterFixture {
    bytes32 internal kA;
    bytes32 internal kA2;
    address internal pA;

    function setUp() public override {
        super.setUp();
        (kA, pA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (kA2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 2000e18);
        debt.mint(alice, 1e24);
        vm.prank(alice);
        ERC20(address(debt)).approve(adapter, type(uint256).max);
    }

    function _holderCall() internal pure returns (bytes memory) {
        return abi.encodeCall(ILock.holder, ());
    }

    /// @dev One call of each user entry point, with arguments that would fail later checks (expired deadline, unknown
    /// market, zero amounts): the Lock refuses each first.
    function _entryPoints() internal view returns (bytes[] memory calls) {
        uint256 past = block.timestamp - 1;
        calls = new bytes[](11);
        calls[0] = abi.encodeCall(IAaveAdapterUser.pledge, (99, _ref(kA), past));
        calls[1] = abi.encodeCall(IAaveAdapterUser.borrow, (99, 0, 0, address(0), past, 0, 7));
        calls[2] = abi.encodeCall(IAaveAdapterUser.repay, (attacker, 99, 0, 0, false, past));
        calls[3] = abi.encodeCall(IAaveAdapterUser.withdraw, (99, _ref(kA), 0, past, 0));
        calls[4] = abi.encodeCall(
            IAaveAdapterUser.repayAllAndWithdraw, (99, _ref(kA), 0, new uint256[](1), new uint256[](2), past)
        );
        calls[5] = abi.encodeCall(IAaveAdapterUser.collectFees, (99, _ref(kA), past));
        calls[6] = abi.encodeCall(IAaveAdapterUser.releaseZeroCredit, (99, _ref(kA), past));
        calls[7] = abi.encodeCall(IAaveAdapterUser.refreshDebtMark, (pA));
        calls[8] = abi.encodeCall(IAaveAdapterCollateral.removeLiquidity, (99, _ref(kA), 0, _mins(), past, 0));
        calls[9] = abi.encodeCall(IAaveAdapterCollateral.recredit, (99, _ref(kA), "", past));
        calls[10] = abi.encodeCall(IAaveAdapterCollateral.repayWithCollateral, (_rwc(99, kA, 0, debtReserveId)));
    }

    // TEST-060 verifies: REQ-PROXY-048, REQ-PROXY-076, REQ-LOCK-007, REQ-ADAPTER-050, INV-054, INV-091
    // Sources: 5.1 TEST-060
    /// @notice Every user entry point acquires the Lock before any other external call: with LPVaultSwap holding the
    /// Lock each reverts the Lock's `LockHeld(LPVaultSwap)`, whatever its other arguments, and reaches neither the
    /// MarketRegistry, Collateralization nor the RiskModule.
    function test_TEST_060_everyEntryPointAcquiresFirst() public {
        bytes[] memory calls = _entryPoints();
        vm.expectCall(address(registry), "", 0);
        vm.expectCall(address(coll), "", 0);
        vm.expectCall(address(risk), "", 0);
        for (uint256 i = 0; i < calls.length; ++i) {
            bytes memory err = swap.callUnderLock(adapter, calls[i]);
            assertEq(err, abi.encodeWithSelector(ILock.LockHeld.selector, address(swap)), vm.toString(i));
        }
        assertFalse(lock.isLocked(), "free afterwards");
    }

    // TEST-060 verifies: REQ-PROXY-048, REQ-LOCK-007, REQ-LOCK-030, INV-054
    /// @notice With no Lock held, the same calls fail on their own checks (not on the Lock), and every revert leaves
    /// the Lock free: the acquisition is undone with the call.
    function test_TEST_060_failedCallsLeaveLockFree() public {
        bytes[] memory calls = _entryPoints();
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory err) = adapter.call(calls[i]);
            // `refreshDebtMark` has no check of its own: it passes and frees the Lock too.
            assertEq(ok, i == 7, "fails on its own check");
            if (!ok) assertTrue(bytes4(err) != ILock.LockHeld.selector, "not a Lock error");
            assertFalse(lock.isLocked(), "lock free afterwards");
        }
    }

    // TEST-060 verifies: REQ-LOCK-007, REQ-LOCK-030, REQ-ADAPTER-050, REQ-PROXY-048
    /// @notice Inside a pledge the Lock is held by the Adapter when the LPVault takes custody, and it is free once the
    /// pledge returns.
    function test_TEST_060_heldDuringPledgeCustody() public {
        lpVault.armReceiveHook(address(lock), _holderCall());
        _pledgeAs(bob, MARKET_ID, UNITS);
        assertTrue(lpVault.receiveHookSucceeded(), "hook ran");
        assertEq(abi.decode(lpVault.receiveHookReturn(), (address)), adapter, "Adapter holds the Lock in custody");
        assertFalse(lock.isLocked(), "released last");
    }

    // TEST-060 verifies: REQ-LOCK-007, REQ-LOCK-030, REQ-PROXY-048
    /// @notice Inside a borrow and a repay the Lock is held by the Adapter when the debt asset moves.
    function test_TEST_060_heldDuringBorrowAndRepayTransfers() public {
        debt.armHook(address(lock), _holderCall());
        _borrowAs(alice, MARKET_ID, debtReserveId, 10e18);
        assertTrue(debt.hookFired(), "borrow hook ran");
        assertEq(abi.decode(debt.hookReturn(), (address)), adapter, "held during the borrow's transfer");
        assertFalse(lock.isLocked(), "free after borrow");
        debt.armHook(address(lock), _holderCall());
        vm.prank(carol);
        debt.approve(adapter, 0);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 10e18, false, _deadline());
        assertEq(abi.decode(debt.hookReturn(), (address)), adapter, "held during the repay's pull");
        assertFalse(lock.isLocked(), "free after repay");
    }

    // TEST-060 verifies: REQ-LOCK-007, REQ-LOCK-028, REQ-ADAPTER-096, REQ-ADAPTER-097
    /// @notice The LPVault's position return, its unwind and its fee payment all run while the Adapter holds the Lock.
    function test_TEST_060_heldDuringCustodyMoves() public {
        lpVault.setObserver(address(lock), _holderCall());
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(kA), 1_000_000_000, _mins(), _deadline(), 0);
        assertEq(abi.decode(lpVault.observed(), (address)), adapter, "held during the unwind");
        lpVault.accrueFees(kA, 5000);
        usdc.armHook(address(lock), _holderCall());
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(kA), _deadline());
        assertEq(abi.decode(usdc.hookReturn(), (address)), adapter, "held while fees are paid");
        uint256 n = lpVault.observations();
        _repayAll();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(kA2), UNITS / 2, _deadline(), 0);
        assertEq(lpVault.observations(), n + 1, "position return observed");
        assertEq(abi.decode(lpVault.observed(), (address)), adapter, "held during the position return");
        assertFalse(lock.isLocked(), "free");
    }

    function _repayAll() internal {
        uint256 g = _debtOf(pA, debtReserveId);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, _deadline());
    }

    // TEST-060 verifies: REQ-LOCK-007, REQ-LOCK-016, ATTACK-007, ATTACK-092
    // Sources: 5.1 TEST-060 (re-entry from callbacks)
    /// @notice A position callback re-entering `pledge` and a token callback re-entering `withdraw` or `borrow` during
    /// a repay, a removal or fee collection all revert `LockHeld(Adapter)`; the outer call completes.
    function test_TEST_060_reentryFromCallbacksReverts() public {
        bytes32 keyB = _newKey();
        lpVault.mintPosition(keyB, bob, MARKET_ID, UNITS);
        bytes32 keyC = _newKey();
        lpVault.mintPosition(keyC, bob, MARKET_ID, UNITS);
        bytes memory lockHeld = abi.encodeWithSelector(ILock.LockHeld.selector, adapter);
        lpVault.armReceiveHook(adapter, abi.encodeCall(IAaveAdapterUser.pledge, (MARKET_ID, _ref(keyC), _deadline())));
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(keyB), _deadline());
        assertFalse(lpVault.receiveHookSucceeded(), "re-entered pledge refused");
        assertEq(lpVault.receiveHookReturn(), lockHeld, "LockHeld during pledge");
        assertEq(lpVault.ownerOf(keyC), bob, "re-entry moved nothing");

        debt.armHook(adapter, abi.encodeCall(IAaveAdapterUser.withdraw, (MARKET_ID, _ref(kA), UNITS, _deadline(), 0)));
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 5e18, false, _deadline());
        assertTrue(debt.hookFired() && !debt.hookSucceeded(), "re-entered withdraw refused");
        assertEq(debt.hookReturn(), lockHeld, "LockHeld during repay");

        usdc.armHook(
            adapter, abi.encodeCall(IAaveAdapterUser.borrow, (MARKET_ID, debtReserveId, 1e18, alice, _deadline(), 0, 1))
        );
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(kA), 1_000_000_000, _mins(), _deadline(), 0);
        assertFalse(usdc.hookSucceeded(), "re-entered borrow refused");
        assertEq(usdc.hookReturn(), lockHeld, "LockHeld during removal");
        assertEq(adapterC.borrowNonce(pA), 1, "no borrow happened");
    }

    // TEST-060 verifies: REQ-LOCK-016, REQ-COLL-018, SPEC-CF-005
    // Sources: 5.1 TEST-060 (rescue-unit view under each holder)
    /// @notice Collateralization's `getAccountRescueUnits` answers the RiskModule's health check inside the Adapter's
    /// borrow and withdrawal (the stand-in reads it there), answers with the Lock free, and reverts `Locked` while
    /// LPVaultSwap holds the Lock.
    function test_TEST_060_rescueUnitsViewByHolder() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(kA2), UNITS / 2, _deadline(), 0);
        assertEq(coll.getAccountRescueUnits(pA, vt), 0, "free Lock: answers");
        bytes memory err =
            swap.callUnderLock(address(coll), abi.encodeCall(ICollateralizationViews.getAccountRescueUnits, (pA, vt)));
        assertEq(err, abi.encodeWithSelector(ICollateralizationErrors.Locked.selector), "Locked under LPVaultSwap");
    }

    // TEST-270 verifies: REQ-LOCK-028, REQ-ADAPTER-096, REQ-ADAPTER-097, REQ-ADAPTER-050
    // Sources: 5.1 TEST-270
    /// @notice Fee collection and zero-credit release reach Collateralization only through the Adapter: a direct call
    /// by the depositor reverts `NotAdapter`, and one from the Adapter's address without the Lock reverts
    /// `LockNotHeld`.
    function test_TEST_270_feesAndZeroCreditOnlyThroughAdapter() public {
        vm.expectRevert(ICollateralizationErrors.NotAdapter.selector);
        vm.prank(alice);
        ICollateralizationUser(address(coll)).collectFees(alice, vt, kA);
        vm.expectRevert(ICollateralizationErrors.NotAdapter.selector);
        vm.prank(alice);
        ICollateralizationUser(address(coll)).releaseZeroCredit(alice, vt, kA);
        vm.expectRevert(ICollateralizationErrors.LockNotHeld.selector);
        vm.prank(adapter);
        ICollateralizationUser(address(coll)).collectFees(alice, vt, kA);
        lpVault.accrueFees(kA, 7);
        vm.prank(alice);
        uint256[] memory fees = adapterC.collectFees(MARKET_ID, _ref(kA), _deadline());
        assertEq(fees[0], 7, "through the Adapter");
    }

    // TEST-270 verifies: REQ-LOCK-023, REQ-ADAPTER-070, REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-PROXY-075
    /// @notice The inner callees answer only under the right holder: `burnSeized` only LPVaultSwap under its own Lock,
    /// the deleverage callbacks only LPVaultSwap under the Adapter's Lock.
    function test_TEST_270_innerCalleesCheckHolder() public {
        bytes memory notSwap = abi.encodeWithSelector(IAaveAdapterErrors.NotLPVaultSwap.selector);
        (bool ok, bytes memory ret) =
            swap.callUnlocked(adapter, abi.encodeCall(IAaveAdapterSettlement.burnSeized, (MARKET_ID, vt, 1)));
        assertFalse(ok, "burnSeized without the Lock");
        assertEq(ret, notSwap, "NotLPVaultSwap");
        bytes memory err = swap.callUnderLock(
            adapter, abi.encodeCall(IAaveAdapterSettlement.deleverageRepay, (pA, debtReserveId, 1e18))
        );
        assertEq(err, notSwap, "callback under LPVaultSwap's Lock");
        vm.expectRevert(IAaveAdapterErrors.NotLPVaultSwap.selector);
        vm.prank(alice);
        IAaveAdapterSettlement(adapter).burnSeized(MARKET_ID, vt, 1);
    }

    // TEST-060 verifies: REQ-LOCK-030, REQ-ADAPTER-081, REQ-PROXY-048
    /// @notice After LPVaultSwap's `deleverageRepay` and `deleverageRelease` return, the Lock is still held by the
    /// Adapter (no inner callee releases it); the Adapter frees it only as the last step of `repayWithCollateral`.
    function test_TEST_060_callbacksDoNotRelease() public {
        swap.setDeleverage(1000e18, 2e12, 0);
        vm.prank(alice);
        adapterC.repayWithCollateral(_rwc(MARKET_ID, kA, 500_000_000, debtReserveId));
        assertEq(swap.holderAfterCallbacks(), adapter, "held after both callbacks");
        assertFalse(lock.isLocked(), "freed at the end");
    }

    // TEST-270 verifies: REQ-ADAPTER-050, REQ-LOCK-028, INV-091
    // Sources: 5.1 TEST-270
    /// @notice The Lock's members are exactly the Adapter and LPVaultSwap, fixed at construction; a market listed after
    /// the Lock was deployed (market B) completes pledge, borrow, withdrawal and liquidation with the same Lock, and a
    /// non-member cannot acquire it.
    function test_TEST_270_membersFixedNewMarketWorks() public {
        assertEq(lock.AAVE_ADAPTER(), adapter, "Adapter member");
        assertEq(lock.LP_VAULT_SWAP(), address(swap), "LPVaultSwap member");
        vm.expectRevert(abi.encodeWithSelector(ILock.NotMember.selector, attacker));
        vm.prank(attacker);
        lock.acquire();
        vm.expectRevert(abi.encodeWithSelector(ILock.NotMember.selector, address(coll)));
        vm.prank(address(coll));
        lock.acquire();
        (bytes32 kb1, address pb) = _pledgeAs(bob, MARKET_B, UNITS);
        _pledgeAs(bob, MARKET_B, UNITS / 2);
        _borrowAs(bob, MARKET_B, debtReserveId, 20_000e18);
        vtPrice.set(1.5e8);
        uint256 seized = swap.liquidate(aave.cdpSpoke, MARKET_B, vtB, vtReserveIdB, debtReserveId, pb, 2000e18, 2);
        assertGt(seized, 0, "liquidated in the later market");
        vtPrice.set(2e8);
        uint256 g = _debtOf(pb, debtReserveId);
        debt.mint(bob, g);
        vm.prank(bob);
        ERC20(address(debt)).approve(adapter, g);
        vm.prank(bob);
        adapterC.repay(bob, MARKET_B, debtReserveId, g, true, _deadline());
        uint256 units = coll.previewRelease(INTEGRATION, kb1);
        vm.prank(bob);
        adapterC.withdraw(MARKET_B, _ref(kb1), units, _deadline(), 0);
        assertEq(lpVault.ownerOf(kb1), bob, "withdrawn in the later market");
        assertEq(lock.AAVE_ADAPTER(), adapter, "members unchanged");
    }
}
