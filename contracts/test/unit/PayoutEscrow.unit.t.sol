// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {PayoutEscrow} from "../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {LockMember} from "../utils/mocks/LockMember.sol";
import {PayoutActor, PayoutDepositor} from "../utils/mocks/PayoutEscrowActors.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title PayoutEscrowUnitTest
/// @notice The payout escrow on its own (2.18) with the real Lock and a stand-in LPVaultSwap: deposits only from
/// LPVaultSwap under the Lock and only of the measured amount, claims only by the credited account, of the whole credit,
/// to the recipient it names, outside the Lock; the reentrancy flag; conservation; the worked examples of 2.18.
/// @dev Escrow side of TEST-179 (the liquidation side joins with LPVaultSwap), TEST-177, TEST-229, TEST-080, TEST-032
/// and TEST-061. Isolation is off so the calls of one test share a transaction, as one Avana call tree does: a later
/// call in the same transaction then also shows the transient flag was cleared by the earlier one.
/// forge-config: default.isolate = false
contract PayoutEscrowUnitTest is AvanaTest {
    /// @notice ERC-7201 id of the reentrancy flag (2.18 Storage).
    bytes32 internal constant REENTRANCY_SLOT = 0xa75fff4cb584554d1fc59956357ed91e22a866262ee7022db6d589f2ebdb4400;

    Lock internal lock;
    PayoutEscrow internal escrow;
    LockMember internal adapter;
    PayoutDepositor internal swap;
    PayoutToken internal usdc;
    PayoutToken internal usdt;
    PayoutActor internal actor;

    function setUp() public {
        adapter = new LockMember();
        swap = new PayoutDepositor();
        lock = new Lock(address(adapter), address(swap));
        escrow = new PayoutEscrow(address(swap), address(lock));
        adapter.setLock(lock);
        swap.setUp(lock, escrow);
        usdc = new PayoutToken("USDC", 6);
        usdt = new PayoutToken("USDT", 6);
        actor = new PayoutActor();
        vm.label(address(lock), "Lock");
        vm.label(address(escrow), "PayoutEscrow");
        vm.label(address(adapter), "AaveAdapter");
        vm.label(address(swap), "LPVaultSwap");
        vm.label(address(usdc), "USDC");
        vm.label(address(usdt), "USDT");
        vm.label(address(actor), "PayoutActor");
    }

    function _deposit(
        PayoutToken token,
        address account,
        uint256 amount
    ) internal {
        token.mint(address(swap), amount);
        swap.depositUnderLock(address(token), account, amount);
    }

    // ─── Construction and shape ───

    // TEST-179 verifies: REQ-ESCROW-001, Q-214, Q-124
    // Sources: 5.1 TEST-179 (escrow side), 2.18
    function test_TEST_179_immutablesFixedAtConstruction() public view {
        assertEq(escrow.LP_VAULT_SWAP(), address(swap), "LP_VAULT_SWAP");
        assertEq(escrow.LOCK(), address(lock), "LOCK");
        assertEq(escrow.totalClaimable(address(usdc)), 0, "no credit at deployment");
    }

    // TEST-179 verifies: REQ-ESCROW-001
    function testFuzz_TEST_179_constructorRefusesZeroAddresses(
        address a,
        address b
    ) public {
        vm.assume(a != address(0) && b != address(0));
        vm.expectRevert(IPayoutEscrow.ZeroAddress.selector);
        new PayoutEscrow(address(0), b);
        vm.expectRevert(IPayoutEscrow.ZeroAddress.selector);
        new PayoutEscrow(a, address(0));
        vm.expectRevert(IPayoutEscrow.ZeroAddress.selector);
        new PayoutEscrow(address(0), address(0));
    }

    // TEST-179 verifies: REQ-ESCROW-001, REQ-ESCROW-019
    // Sources: PayoutEscrow review 2026-11-10 (Low-1)
    /// @notice The escrow is deployed after the Lock and only against it: a Lock without code, a Lock naming another
    /// LPVaultSwap, and the AaveAdapter passed as depositor all revert `LockMismatch`; LPVaultSwap itself needs no code.
    function test_TEST_179_constructorRequiresTheLocksLPVaultSwap() public {
        vm.expectRevert(IPayoutEscrow.LockMismatch.selector);
        new PayoutEscrow(address(swap), makeAddr("codelessLock"));
        vm.expectRevert(IPayoutEscrow.LockMismatch.selector);
        new PayoutEscrow(makeAddr("otherLPVaultSwap"), address(lock));
        vm.expectRevert(IPayoutEscrow.LockMismatch.selector);
        new PayoutEscrow(address(adapter), address(lock));
        address predictedSwap = makeAddr("predictedLPVaultSwap");
        Lock other = new Lock(address(adapter), predictedSwap);
        PayoutEscrow ok = new PayoutEscrow(predictedSwap, address(other));
        assertEq(ok.LP_VAULT_SWAP(), predictedSwap);
        assertEq(ok.LOCK(), address(other));
    }

    /// @notice The runtime code has no DELEGATECALL, CALLCODE, SELFDESTRUCT or CREATE opcode, so no path can run
    /// foreign code in the escrow's context, destroy it or deploy from it.
    // TEST-032 verifies: REQ-ESCROW-001, INV-053, Q-124, Q-214
    // Sources: 5.1 TEST-032 (escrow side)
    function test_TEST_032_noDelegatecallSelfdestructOrCreate() public view {
        bytes memory code = address(escrow).code;
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff && op != 0xf0 && op != 0xf5, "forbidden opcode");
            // PUSH1..PUSH32 carry 1..32 bytes of data that are not opcodes.
            i += (op >= 0x60 && op <= 0x7f) ? uint256(op) - 0x5e : 1;
        }
    }

    /// @notice The escrow answers only its six selectors: no fallback, `receive`, sweep, rescue or admin entry.
    // TEST-032 verifies: REQ-ESCROW-001, INV-053, Q-124, Q-214, REQ-ACCESS-066, REQ-ACCESS-022, REQ-ACCESS-113
    function testFuzz_TEST_032_onlyInterfaceSelectors(
        bytes4 selector,
        bytes calldata tail
    ) public {
        vm.assume(
            selector != IPayoutEscrow.deposit.selector && selector != IPayoutEscrow.claim.selector
                && selector != IPayoutEscrow.claimable.selector && selector != IPayoutEscrow.totalClaimable.selector
                && selector != IPayoutEscrow.LP_VAULT_SWAP.selector && selector != IPayoutEscrow.LOCK.selector
        );
        (bool ok,) = address(escrow).call(abi.encodePacked(selector, tail));
        assertFalse(ok, "unknown selector accepted");
        vm.deal(address(this), 1 ether);
        (ok,) = address(escrow).call{value: 1}("");
        assertFalse(ok, "ETH accepted");
        (ok,) = address(escrow).call{value: 1}(abi.encodeCall(IPayoutEscrow.claim, (address(usdc), bob)));
        assertFalse(ok, "payable claim");
    }

    // ─── deposit ───

    // TEST-179 verifies: REQ-ESCROW-002, REQ-ESCROW-003, REQ-ESCROW-006, REQ-ESCROW-017, REQ-SWAP-076, INV-061, Q-214, Q-401
    // TEST-061 verifies: REQ-ESCROW-003, Q-214
    function test_TEST_179_depositCreditsAccountAndToken() public {
        usdc.mint(address(swap), 1_627_460);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IPayoutEscrow.RemainderEscrowed(address(usdc), alice, 1_627_460);
        swap.depositUnderLock(address(usdc), alice, 1_627_460);
        assertEq(escrow.claimable(address(usdc), alice), 1_627_460, "credit");
        assertEq(escrow.totalClaimable(address(usdc)), 1_627_460, "total");
        assertEq(usdc.balanceOf(address(escrow)), 1_627_460, "held");
        assertEq(usdc.balanceOf(address(swap)), 0, "LPVaultSwap keeps nothing");
        assertEq(usdc.allowance(address(swap), address(escrow)), 0, "exact allowance consumed");
        assertEq(escrow.claimable(address(usdt), alice), 0, "credit keyed by token");
        assertFalse(lock.isLocked(), "lock freed");
    }

    // TEST-179 verifies: REQ-ESCROW-002, REQ-ESCROW-009, INV-054, Q-148, Q-214
    function testFuzz_TEST_179_depositOnlyFromLpVaultSwap(
        address caller
    ) public {
        vm.assume(caller != address(swap));
        vm.prank(caller);
        vm.expectRevert(IPayoutEscrow.NotLPVaultSwap.selector);
        escrow.deposit(address(usdc), alice, 100);
        assertEq(escrow.totalClaimable(address(usdc)), 0);
    }

    /// @notice LPVaultSwap without the Lock, and LPVaultSwap while the AaveAdapter holds it, are both refused.
    // TEST-179 verifies: REQ-ESCROW-002, REQ-ESCROW-009, REQ-LOCK-023, INV-054, Q-148, Q-214
    function test_TEST_179_depositOnlyWhileLpVaultSwapHoldsLock() public {
        usdc.mint(address(swap), 200);
        vm.expectRevert(IPayoutEscrow.NotLocked.selector);
        swap.depositUnlocked(address(usdc), alice, 100);

        bytes memory call = abi.encodeCall(PayoutDepositor.depositUnlocked, (address(usdc), alice, 100));
        (bool ok, bytes memory ret) = adapter.acquireCallRelease(address(swap), call);
        assertFalse(ok, "deposit under the Adapter's lock");
        assertEq(ret, abi.encodeWithSelector(IPayoutEscrow.NotLocked.selector));
        assertEq(escrow.totalClaimable(address(usdc)), 0);
    }

    // TEST-179 verifies: REQ-ESCROW-002, REQ-ESCROW-010, Q-217
    // TEST-177 verifies: REQ-ESCROW-002, REQ-ESCROW-010, INV-021, Q-217
    // Sources: 5.1 TEST-177 (escrow side: a zero deposit is rejected before the token is called)
    function test_TEST_177_zeroDepositRejectedWithoutTokenCall() public {
        usdc.setRevertOnZero(true);
        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectRevert(IPayoutEscrow.ZeroAmount.selector);
        swap.depositUnderLock(address(usdc), alice, 0);
    }

    // TEST-179 verifies: REQ-ESCROW-002, REQ-ESCROW-010
    function test_TEST_179_depositRefusesZeroAccount() public {
        usdc.mint(address(swap), 100);
        vm.expectRevert(IPayoutEscrow.InvalidAccount.selector);
        swap.depositUnderLock(address(usdc), address(0), 100);
    }

    /// @notice A call failing several checks reverts with the first: Reentrancy, NotLPVaultSwap, NotLocked,
    /// ZeroAmount, InvalidAccount.
    // TEST-179 verifies: REQ-ESCROW-002, REQ-ESCROW-007, REQ-ESCROW-009, REQ-ESCROW-010
    function test_TEST_179_depositCheckOrder() public {
        vm.prank(attacker);
        vm.expectRevert(IPayoutEscrow.NotLPVaultSwap.selector);
        escrow.deposit(address(usdc), address(0), 0);

        vm.expectRevert(IPayoutEscrow.NotLocked.selector);
        swap.depositUnlocked(address(usdc), address(0), 0);

        vm.expectRevert(IPayoutEscrow.ZeroAmount.selector);
        swap.depositUnderLock(address(usdc), address(0), 0);
    }

    /// @notice USDT switches on its 10 bps fee after listing: 1,612,848 requested arrive as 1,611,236, which is the
    /// credit (2.18 REQ-ESCROW-003 example).
    // TEST-179 verifies: REQ-ESCROW-003, REQ-ESCROW-006, INV-061, Q-271
    // TEST-061 verifies: REQ-ESCROW-003
    function test_TEST_179_feeTakingTokenCreditsMeasuredAmount() public {
        usdt.setFeeBps(10);
        usdt.mint(address(swap), 1_612_848);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IPayoutEscrow.RemainderEscrowed(address(usdt), bob, 1_611_236);
        swap.depositUnderLock(address(usdt), bob, 1_612_848);
        assertEq(escrow.claimable(address(usdt), bob), 1_611_236, "credit = received");
        assertEq(escrow.totalClaimable(address(usdt)), 1_611_236);
        assertEq(usdt.balanceOf(address(escrow)), 1_611_236, "held = credit");
        assertEq(usdt.balanceOf(usdt.FEE_SINK()), 1612, "issuer fee");
    }

    // TEST-179 verifies: REQ-ESCROW-003, REQ-ESCROW-011, Q-271
    function test_TEST_179_transferMismatchWhenNothingArrives() public {
        usdt.setFeeBps(10_000);
        usdt.mint(address(swap), 100);
        vm.expectRevert(IPayoutEscrow.TransferMismatch.selector);
        swap.depositUnderLock(address(usdt), bob, 100);
    }

    // TEST-179 verifies: REQ-ESCROW-003, REQ-ESCROW-011, INV-061
    // Sources: PayoutEscrow review 2026-11-10 (Low-3)
    /// @notice A deposit whose balance rises by more than requested (a rounding-up or positive-rebase token) credits the
    /// request and keeps the liquidation going; the surplus stays as an unattributed donation.
    function test_TEST_179_moreArrivingCreditsTheRequest() public {
        usdc.setBonus(1);
        usdc.mint(address(swap), 100);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IPayoutEscrow.RemainderEscrowed(address(usdc), bob, 100);
        swap.depositUnderLock(address(usdc), bob, 100);
        assertEq(escrow.claimable(address(usdc), bob), 100, "credit = request");
        assertEq(escrow.totalClaimable(address(usdc)), 100, "total");
        assertEq(usdc.balanceOf(address(escrow)), 101, "surplus held uncredited");
    }

    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-011, INV-061
    // Sources: PayoutEscrow review 2026-11-10 (Low-2)
    /// @notice A token that charges the sender a fee on top of the amount would pay a claim out of other credits: the
    /// claim reverts `TransferMismatch` and every credit stays; with the fee off again the claim succeeds.
    function test_TEST_179_senderFeeClaimReverts() public {
        _deposit(usdc, bob, 1000);
        _deposit(usdc, carol, 1000);
        usdc.setSenderFeeBps(100);
        vm.prank(bob);
        vm.expectRevert(IPayoutEscrow.TransferMismatch.selector);
        escrow.claim(address(usdc), bob);
        assertEq(escrow.claimable(address(usdc), bob), 1000, "credit kept");
        assertEq(usdc.balanceOf(address(escrow)), 2000, "balance kept");
        usdc.setSenderFeeBps(0);
        vm.prank(bob);
        assertEq(escrow.claim(address(usdc), bob), 1000, "claim after the fee is off");
        assertEq(usdc.balanceOf(address(escrow)), escrow.totalClaimable(address(usdc)), "carol still backed");
    }

    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-015, INV-061
    // Sources: PayoutEscrow review 2026-11-10 (Info-1)
    /// @notice After an issuer burns part of the escrow's balance (or a negative rebase), claims are paid first come,
    /// first served: the first is paid in full, the last reverts and keeps its credit until the balance is restored.
    function test_TEST_179_balanceFallPaysFirstComeFirstServed() public {
        _deposit(usdc, bob, 1000);
        _deposit(usdc, carol, 1000);
        usdc.issuerBurn(address(escrow), 500);
        vm.prank(bob);
        assertEq(escrow.claim(address(usdc), bob), 1000, "first claim in full");
        vm.prank(carol);
        vm.expectRevert();
        escrow.claim(address(usdc), carol);
        assertEq(escrow.claimable(address(usdc), carol), 1000, "credit kept");
        usdc.mint(address(escrow), 500);
        vm.prank(carol);
        assertEq(escrow.claim(address(usdc), carol), 1000, "paid once restored");
    }

    /// @notice A transfer that leaves the escrow's balance lower reverts with the named error, not an underflow.
    // TEST-179 verifies: REQ-ESCROW-003, REQ-ESCROW-011
    function test_TEST_179_transferMismatchWhenBalanceFalls() public {
        usdc.mint(address(escrow), 500);
        usdc.setDrain(150);
        usdc.mint(address(swap), 100);
        vm.expectRevert(IPayoutEscrow.TransferMismatch.selector);
        swap.depositUnderLock(address(usdc), bob, 100);
    }

    /// @notice A token that refuses the escrow (false return, or a blocklist of the escrow's own address) reverts the
    /// deposit and so the liquidation.
    // TEST-179 verifies: REQ-ESCROW-003, REQ-ESCROW-011, Q-227
    function test_TEST_179_tokenRefusingEscrowRevertsDeposit() public {
        usdc.mint(address(swap), 100);
        usdc.setReturnFalse(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        swap.depositUnderLock(address(usdc), bob, 100);
        usdc.setReturnFalse(false);
        usdc.setBlocked(address(escrow), true);
        vm.expectRevert(abi.encodeWithSelector(PayoutToken.Blocked.selector, address(escrow)));
        swap.depositUnderLock(address(usdc), bob, 100);
        assertEq(escrow.totalClaimable(address(usdc)), 0);
    }

    // ─── claim ───

    /// @notice 2.18 worked example: `b1` is on USDC's blocklist, its 1,627,460 surplus is escrowed, and `b1` claims
    /// it to a second wallet `b2`; a second claim reverts.
    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-013, REQ-ESCROW-017, INV-061, Q-214, Q-337
    // TEST-061 verifies: REQ-ESCROW-004, Q-214
    function test_TEST_179_claimPaysWholeCreditToNamedRecipient() public {
        address b1 = alice;
        address b2 = makeAddr("b2");
        usdc.setBlocked(b1, true);
        _deposit(usdc, b1, 1_627_460);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit IPayoutEscrow.RemainderClaimed(address(usdc), b1, b2, 1_627_460);
        vm.prank(b1);
        uint256 paid = escrow.claim(address(usdc), b2);
        assertEq(paid, 1_627_460, "whole credit");
        assertEq(usdc.balanceOf(b2), 1_627_460, "recipient paid");
        assertEq(escrow.claimable(address(usdc), b1), 0, "credit cleared");
        assertEq(escrow.totalClaimable(address(usdc)), 0, "total cleared");
        assertEq(usdc.balanceOf(address(escrow)), 0);

        vm.prank(b1);
        vm.expectRevert(IPayoutEscrow.NothingToClaim.selector);
        escrow.claim(address(usdc), b2);
    }

    /// @notice Only the credited account claims, as `msg.sender`; any other caller finds no credit, and a credit in
    /// one token cannot be claimed in another.
    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-013, ATTACK-118, INV-061, Q-214
    function testFuzz_TEST_179_onlyCreditedAccountClaims(
        address caller,
        uint256 amount
    ) public {
        vm.assume(caller != alice);
        amount = bound(amount, 1, 1e30);
        _deposit(usdc, alice, amount);
        vm.prank(caller);
        vm.expectRevert(IPayoutEscrow.NothingToClaim.selector);
        escrow.claim(address(usdc), bob);
        vm.prank(alice);
        vm.expectRevert(IPayoutEscrow.NothingToClaim.selector);
        escrow.claim(address(usdt), alice);
        assertEq(escrow.claimable(address(usdc), alice), amount, "credit untouched");
    }

    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-014
    function test_TEST_179_claimRefusesZeroOrSelfRecipient() public {
        _deposit(usdc, alice, 100);
        vm.prank(alice);
        vm.expectRevert(IPayoutEscrow.InvalidRecipient.selector);
        escrow.claim(address(usdc), address(0));
        vm.prank(alice);
        vm.expectRevert(IPayoutEscrow.InvalidRecipient.selector);
        escrow.claim(address(usdc), address(escrow));
        assertEq(escrow.claimable(address(usdc), alice), 100);
    }

    /// @notice A claim inside any locked Avana call reverts, whichever member holds the Lock.
    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-012, INV-054, Q-148
    function test_TEST_179_claimRevertsWhileLockHeld() public {
        _deposit(usdc, address(actor), 100);
        bytes memory call = abi.encodeCall(PayoutActor.claim, (escrow, address(usdc), bob));
        (bool ok, bytes memory ret) = adapter.acquireCallRelease(address(actor), call);
        assertFalse(ok, "claim under the Adapter's lock");
        assertEq(ret, abi.encodeWithSelector(IPayoutEscrow.LockHeld.selector));

        vm.expectRevert(IPayoutEscrow.LockHeld.selector);
        swap.callUnderLock(address(actor), call);
        assertEq(escrow.claimable(address(usdc), address(actor)), 100);

        // Lock free again: the same account claims.
        assertEq(actor.claim(escrow, address(usdc), bob), 100);
    }

    /// @notice A claim failing several checks reverts with the first: LockHeld, InvalidRecipient, NothingToClaim.
    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-007, REQ-ESCROW-012, REQ-ESCROW-013, REQ-ESCROW-014
    function test_TEST_179_claimCheckOrder() public {
        bytes memory call = abi.encodeCall(PayoutActor.claim, (escrow, address(usdc), address(0)));
        vm.expectRevert(IPayoutEscrow.LockHeld.selector);
        swap.callUnderLock(address(actor), call);
        vm.prank(attacker);
        vm.expectRevert(IPayoutEscrow.InvalidRecipient.selector);
        escrow.claim(address(usdc), address(0));
    }

    /// @notice The token refuses the recipient: the claim reverts, the credit stays, and the account claims again to
    /// another recipient.
    // TEST-179 verifies: REQ-ESCROW-004, REQ-ESCROW-015, INV-061, Q-214
    function test_TEST_179_refusedRecipientKeepsCredit() public {
        _deposit(usdc, alice, 4_500_000);
        usdc.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PayoutToken.Blocked.selector, alice));
        escrow.claim(address(usdc), alice);
        usdc.setReturnFalse(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc)));
        escrow.claim(address(usdc), bob);
        assertEq(escrow.claimable(address(usdc), alice), 4_500_000, "credit kept");
        assertEq(escrow.totalClaimable(address(usdc)), 4_500_000, "total kept");

        usdc.setReturnFalse(false);
        vm.prank(alice);
        assertEq(escrow.claim(address(usdc), bob), 4_500_000);
        assertEq(usdc.balanceOf(bob), 4_500_000);
    }

    /// @notice Circle blocklists the treasury Safe that is `feeRecipient`: its fee `A = 19.305` USDC is escrowed and
    /// the Safe later claims it to the new treasury (REQ-ESCROW-018 example); credits never expire.
    // TEST-179 verifies: REQ-ESCROW-005, REQ-ESCROW-018, INV-061, Q-389
    // TEST-229 verifies: REQ-ESCROW-018, Q-389
    function test_TEST_229_blockedFeeRecipientClaimsToNewTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        usdc.setBlocked(feeRecipient, true);
        _deposit(usdc, feeRecipient, 19_305_000);
        vm.warp(block.timestamp + 3650 days);
        vm.prank(feeRecipient);
        assertEq(escrow.claim(address(usdc), newTreasury), 19_305_000);
        assertEq(usdc.balanceOf(newTreasury), 19_305_000);
    }

    /// @notice LIFECYCLE step 5: forty 7.8 USDC fee deposits add to one credit of 312 USDC, paid in one claim.
    // TEST-179 verifies: REQ-ESCROW-003, REQ-ESCROW-004, REQ-ESCROW-006, INV-061
    function test_TEST_179_depositsAccumulateIntoOneCredit() public {
        for (uint256 i = 0; i < 40; ++i) {
            _deposit(usdc, feeRecipient, 7_800_000);
        }
        assertEq(escrow.claimable(address(usdc), feeRecipient), 312_000_000);
        assertEq(escrow.totalClaimable(address(usdc)), 312_000_000);
        vm.prank(feeRecipient);
        assertEq(escrow.claim(address(usdc), bob), 312_000_000);
    }

    // ─── Conservation and donations ───

    /// @notice 2.18 REQ-ESCROW-006 example: credits for `b1` and `b2`, a direct 10 USDC transfer, then `b1` claims.
    // TEST-179 verifies: REQ-ESCROW-006, INV-061, Q-214
    function test_TEST_179_conservationWorkedExample() public {
        address b1 = alice;
        address b2 = feeRecipient;
        _deposit(usdc, b1, 1_627_460);
        _deposit(usdc, b2, 3_100_000);
        assertEq(escrow.totalClaimable(address(usdc)), 4_727_460);
        usdc.mint(address(this), 10_000_000);
        usdc.transfer(address(escrow), 10_000_000);
        assertEq(usdc.balanceOf(address(escrow)), 14_727_460, "balance with donation");
        assertEq(escrow.totalClaimable(address(usdc)), 4_727_460, "donation not credited");
        vm.prank(b1);
        escrow.claim(address(usdc), bob);
        assertEq(usdc.balanceOf(address(escrow)), 13_100_000);
        assertEq(escrow.totalClaimable(address(usdc)), 3_100_000);
        assertEq(escrow.claimable(address(usdc), b2), 3_100_000, "other credit unchanged");
    }

    /// @notice Dust donations before and between calls change no credit and block no deposit or claim.
    // TEST-080 verifies: REQ-ESCROW-006, INV-021, INV-061, Q-124
    // Sources: 5.1 TEST-080 (escrow side)
    function testFuzz_TEST_080_donationsBlockNothing(
        uint256 dust,
        uint256 amount
    ) public {
        dust = bound(dust, 1, 1e6);
        amount = bound(amount, 1, 1e30);
        usdc.mint(address(escrow), dust);
        _deposit(usdc, alice, amount);
        assertEq(escrow.claimable(address(usdc), alice), amount, "credit = deposit, not balance");
        usdc.mint(address(escrow), dust);
        vm.prank(alice);
        assertEq(escrow.claim(address(usdc), bob), amount);
        assertEq(escrow.totalClaimable(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(escrow)), 2 * dust, "donations stay");
    }

    /// @notice Random deposits (with an issuer fee) and claims over three accounts: credited = claimed + held per
    /// account, `totalClaimable` is the sum of credits and the balance covers it.
    // TEST-179 verifies: REQ-ESCROW-003, REQ-ESCROW-004, REQ-ESCROW-006, INV-061, Q-214
    function testFuzz_TEST_179_conservationOverSequence(
        uint256[6] memory amounts,
        uint8[6] memory who,
        bool[6] memory isClaim,
        uint256 feeBps
    ) public {
        address[3] memory accounts = [alice, bob, feeRecipient];
        uint256[3] memory credited;
        uint256[3] memory claimed;
        usdt.setFeeBps(bound(feeBps, 0, 20));
        for (uint256 k = 0; k < 6; ++k) {
            uint256 j = who[k] % 3;
            address a = accounts[j];
            if (isClaim[k]) {
                uint256 credit = escrow.claimable(address(usdt), a);
                if (credit == 0) continue;
                vm.prank(a);
                claimed[j] += escrow.claim(address(usdt), carol);
            } else {
                uint256 before = escrow.claimable(address(usdt), a);
                _deposit(usdt, a, bound(amounts[k], 10_000, 1e24));
                credited[j] += escrow.claimable(address(usdt), a) - before;
            }
        }
        uint256 sum;
        for (uint256 j = 0; j < 3; ++j) {
            uint256 held = escrow.claimable(address(usdt), accounts[j]);
            assertEq(credited[j], claimed[j] + held, "credited = claimed + held");
            sum += held;
        }
        assertEq(escrow.totalClaimable(address(usdt)), sum, "total = sum");
        assertGe(usdt.balanceOf(address(escrow)), sum, "balance covers total");
    }

    // ─── Reentrancy ───

    /// @notice A token callback during a claim, through the credited account, cannot claim the credit again.
    // TEST-179 verifies: REQ-ESCROW-007, REQ-ESCROW-016, ATTACK-118, Q-148
    function test_TEST_179_claimReentryIntoClaimReverts() public {
        _deposit(usdc, address(actor), 100);
        usdc.setHook(address(actor), abi.encodeCall(PayoutActor.claim, (escrow, address(usdc), bob)));
        vm.expectRevert(IPayoutEscrow.Reentrancy.selector);
        actor.claim(escrow, address(usdc), carol);
        assertEq(escrow.claimable(address(usdc), address(actor)), 100, "credit kept");
    }

    // TEST-179 verifies: REQ-ESCROW-007, REQ-ESCROW-016, Q-148
    function test_TEST_179_claimReentryIntoDepositReverts() public {
        _deposit(usdc, address(actor), 100);
        usdc.mint(address(swap), 50);
        bytes memory dep = abi.encodeCall(PayoutDepositor.depositUnlocked, (address(usdc), alice, 50));
        usdc.setHook(address(swap), dep);
        vm.expectRevert(IPayoutEscrow.Reentrancy.selector);
        actor.claim(escrow, address(usdc), carol);
    }

    // TEST-179 verifies: REQ-ESCROW-007, REQ-ESCROW-016, Q-148
    function test_TEST_179_depositReentryReverts() public {
        usdc.mint(address(swap), 300);
        bytes memory dep = abi.encodeCall(IPayoutEscrow.deposit, (address(usdc), alice, 50));
        usdc.setHook(address(swap), abi.encodeCall(PayoutDepositor.execute, (address(escrow), dep)));
        vm.expectRevert(IPayoutEscrow.Reentrancy.selector);
        swap.depositUnderLock(address(usdc), bob, 100);

        // A claim reached from a deposit's callback fails on the flag first, before LockHeld.
        bytes memory cl = abi.encodeCall(PayoutActor.claim, (escrow, address(usdc), carol));
        usdc.setHook(address(actor), cl);
        vm.expectRevert(IPayoutEscrow.Reentrancy.selector);
        swap.depositUnderLock(address(usdc), bob, 100);

        // The flag is cleared after every completed call: deposit and claim run again in this transaction.
        usdc.setHook(address(0), "");
        swap.depositUnderLock(address(usdc), bob, 100);
        vm.prank(bob);
        escrow.claim(address(usdc), carol);
        swap.depositUnderLock(address(usdc), bob, 100);
        assertEq(escrow.claimable(address(usdc), bob), 100);
    }

    /// @notice The flag lives at the ERC-7201 slot of `avana.escrow.reentrancy`.
    // TEST-179 verifies: REQ-ESCROW-007
    function test_TEST_179_reentrancySlotDerivation() public pure {
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("avana.escrow.reentrancy")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(derived, REENTRANCY_SLOT);
    }

    // ─── No other Avana state ───

    /// @notice A claim touches only the claimant, the escrow, the Lock (one view) and the token: no pause state,
    /// breaker, freeze list, market status or listing is read, so a frozen account claims in every application state.
    // TEST-229 verifies: REQ-ESCROW-008, REQ-MREG-023, INV-081, Q-241, Q-242
    // Sources: 5.1 TEST-229 (escrow claim by a frozen account), PROP-066
    function test_TEST_229_claimTouchesOnlyTokenAndLock() public {
        _deposit(usdc, address(actor), 100);
        vm.startStateDiffRecording();
        actor.claim(escrow, address(usdc), bob);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _assertOnly(accesses, address(actor));
    }

    /// @notice A deposit touches only LPVaultSwap, the escrow, the Lock and the token.
    // TEST-179 verifies: REQ-ESCROW-008
    function test_TEST_179_depositTouchesOnlyTokenAndLock() public {
        usdc.mint(address(swap), 100);
        vm.startStateDiffRecording();
        swap.depositUnderLock(address(usdc), alice, 100);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _assertOnly(accesses, address(swap));
    }

    function _assertOnly(
        Vm.AccountAccess[] memory accesses,
        address caller
    ) internal view {
        bool sawLock;
        bool sawToken;
        for (uint256 i = 0; i < accesses.length; ++i) {
            address a = accesses[i].account;
            assertTrue(
                a == caller || a == address(escrow) || a == address(lock) || a == address(usdc), "unexpected account"
            );
            sawLock = sawLock || a == address(lock);
            sawToken = sawToken || a == address(usdc);
        }
        assertTrue(sawLock && sawToken, "recording saw the Lock and the token");
    }

    /// @notice A claim of nothing never calls the token, so a token that reverts on zero transfers is not reached.
    // TEST-177 verifies: REQ-ESCROW-004, REQ-ESCROW-013, INV-021, Q-217
    function test_TEST_177_noZeroClaimTransfer() public {
        usdc.setRevertOnZero(true);
        vm.expectCall(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.prank(alice);
        vm.expectRevert(IPayoutEscrow.NothingToClaim.selector);
        escrow.claim(address(usdc), bob);
    }
}
