// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {PayoutEscrow} from "../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {Test} from "forge-std/Test.sol";

/// @title PayoutEscrowHalmosTest
/// @notice Symbolic checks of the payout escrow (2.18) for every caller, account, recipient, amount and Lock state:
/// a deposit succeeds only from LPVaultSwap while it holds the Lock and credits exactly what arrived; a claim succeeds
/// only for the caller's own non-zero credit, outside the Lock, and pays all of it to the named recipient; every
/// refusal carries the error of the first failing check and changes nothing; conservation holds across a sequence with
/// a donation.
/// @dev LPVaultSwap and the AaveAdapter are fixed concrete addresses driven by `vm.prank`; the token is a plain
/// `PayoutToken` (every switch off) unless a check turns on its fee. Amounts are bounded to uint128, the realistic
/// range of a token balance. A Halmos run is one transaction, so the Lock state carries across the calls of one check.
contract PayoutEscrowHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    address internal constant B1 = address(0xB1);
    address internal constant B2 = address(0xB2);
    address internal constant DONOR = address(0xD0);

    Lock internal lock;
    PayoutEscrow internal escrow;
    PayoutToken internal token;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
        escrow = new PayoutEscrow(SWAP, address(lock));
        token = new PayoutToken("USDC", 6);
    }

    /// @notice LPVaultSwap's production deposit: acquire, exact approval, deposit, release.
    function _deposit(
        address account,
        uint256 amount
    ) internal {
        token.mint(SWAP, amount);
        vm.startPrank(SWAP);
        lock.acquire();
        token.approve(address(escrow), amount);
        escrow.deposit(address(token), account, amount);
        lock.release();
        vm.stopPrank();
    }

    /// @notice Lock state 0 free, 1 held by LPVaultSwap, 2 held by the AaveAdapter.
    function _setLock(
        uint8 state
    ) internal {
        if (state % 3 == 1) {
            vm.prank(SWAP);
            lock.acquire();
        } else if (state % 3 == 2) {
            vm.prank(ADAPTER);
            lock.acquire();
        }
    }

    function _is(
        bytes memory ret,
        bytes4 selector
    ) internal pure returns (bool) {
        return keccak256(ret) == keccak256(abi.encodeWithSelector(selector));
    }

    // PROP-037 verifies: REQ-ESCROW-002, REQ-ESCROW-009, REQ-ESCROW-010, REQ-LOCK-023, INV-054, Q-148
    // PROP-052 verifies: REQ-ESCROW-003, INV-061, Q-214, Q-217
    function check_PROP_037_depositOnlyFromLpVaultSwapUnderLock(
        address caller,
        address account,
        uint256 amount,
        uint256 prior,
        uint8 lockState
    ) public {
        vm.assume(amount <= type(uint128).max && prior > 0 && prior <= type(uint128).max);
        _deposit(B1, prior);
        token.mint(SWAP, amount);
        vm.prank(SWAP);
        token.approve(address(escrow), amount);
        _setLock(lockState);
        address holder = lock.holder();
        uint256 creditBefore = escrow.claimable(address(token), account);
        uint256 totalBefore = escrow.totalClaimable(address(token));
        uint256 balanceBefore = token.balanceOf(address(escrow));

        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IPayoutEscrow.deposit, (address(token), account, amount)));

        uint256 creditAfter = escrow.claimable(address(token), account);
        if (ok) {
            assert(caller == SWAP && holder == SWAP && amount > 0 && account != address(0));
            assert(creditAfter == creditBefore + amount);
            assert(escrow.totalClaimable(address(token)) == totalBefore + amount);
            assert(token.balanceOf(address(escrow)) == balanceBefore + amount);
        } else {
            assert(creditAfter == creditBefore && escrow.totalClaimable(address(token)) == totalBefore);
            assert(token.balanceOf(address(escrow)) == balanceBefore);
            if (caller != SWAP) assert(_is(ret, IPayoutEscrow.NotLPVaultSwap.selector));
            else if (holder != SWAP) assert(_is(ret, IPayoutEscrow.NotLocked.selector));
            else if (amount == 0) assert(_is(ret, IPayoutEscrow.ZeroAmount.selector));
            else if (account == address(0)) assert(_is(ret, IPayoutEscrow.InvalidAccount.selector));
            else assert(false);
        }
    }

    // PROP-052 verifies: REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-012, REQ-ESCROW-013, REQ-ESCROW-014, ATTACK-118, INV-061, Q-214, Q-217
    function check_PROP_052_claimPaysWholeOwnCreditToNamedRecipient(
        address caller,
        address recipient,
        uint256 a1,
        uint256 a2,
        uint8 lockState
    ) public {
        vm.assume(a1 > 0 && a1 <= type(uint128).max && a2 > 0 && a2 <= type(uint128).max);
        _deposit(B1, a1);
        _deposit(B2, a2);
        _setLock(lockState);
        Snap memory before = _snap(caller, recipient);

        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IPayoutEscrow.claim, (address(token), recipient)));

        if (ok) _assertPaid(before, caller, recipient, ret);
        else _assertRefused(before, caller, recipient, ret);
    }

    /// @notice State a claim reads or changes, taken before it.
    struct Snap {
        bool locked;
        uint256 credit;
        uint256 creditB1;
        uint256 creditB2;
        uint256 total;
        uint256 recipientBalance;
        uint256 escrowBalance;
    }

    function _snap(
        address caller,
        address recipient
    ) internal view returns (Snap memory s) {
        s.locked = lock.isLocked();
        s.credit = escrow.claimable(address(token), caller);
        s.creditB1 = escrow.claimable(address(token), B1);
        s.creditB2 = escrow.claimable(address(token), B2);
        s.total = escrow.totalClaimable(address(token));
        s.recipientBalance = token.balanceOf(recipient);
        s.escrowBalance = token.balanceOf(address(escrow));
    }

    function _assertPaid(
        Snap memory s,
        address caller,
        address recipient,
        bytes memory ret
    ) internal view {
        assert(!s.locked && recipient != address(0) && recipient != address(escrow) && s.credit > 0);
        assert(abi.decode(ret, (uint256)) == s.credit);
        assert(escrow.claimable(address(token), caller) == 0);
        assert(escrow.totalClaimable(address(token)) == s.total - s.credit);
        assert(token.balanceOf(recipient) == s.recipientBalance + s.credit);
        assert(token.balanceOf(address(escrow)) == s.escrowBalance - s.credit);
        if (caller != B1) assert(escrow.claimable(address(token), B1) == s.creditB1);
        if (caller != B2) assert(escrow.claimable(address(token), B2) == s.creditB2);
    }

    function _assertRefused(
        Snap memory s,
        address caller,
        address recipient,
        bytes memory ret
    ) internal view {
        assert(escrow.claimable(address(token), caller) == s.credit);
        assert(escrow.totalClaimable(address(token)) == s.total);
        assert(token.balanceOf(address(escrow)) == s.escrowBalance);
        if (s.locked) {
            assert(_is(ret, IPayoutEscrow.LockHeld.selector));
        } else if (recipient == address(0) || recipient == address(escrow)) {
            assert(_is(ret, IPayoutEscrow.InvalidRecipient.selector));
        } else if (s.credit == 0) {
            assert(_is(ret, IPayoutEscrow.NothingToClaim.selector));
        } else {
            assert(false);
        }
    }

    /// @notice Deposits for two accounts, a donation, a claim and a second claim: `totalClaimable` is always the sum
    /// of the credits, each credit is at most the total, the balance covers the total, and the excess is the donation.
    // PROP-052 verifies: REQ-ESCROW-006, REQ-ESCROW-013, INV-061, Q-214
    // PROP-043 verifies: Q-049, Q-226
    function check_PROP_052_conservationAcrossSequence(
        uint256 a1,
        uint256 a2,
        uint256 a3,
        uint256 dust,
        address recipient
    ) public {
        vm.assume(a1 > 0 && a1 <= type(uint128).max && a2 > 0 && a2 <= type(uint128).max);
        vm.assume(a3 > 0 && a3 <= type(uint128).max && dust <= type(uint128).max);
        vm.assume(recipient != address(0) && recipient != address(escrow));
        _deposit(B1, a1);
        token.mint(address(escrow), dust);
        _deposit(B2, a2);
        _deposit(B1, a3);
        _conserved(dust);

        vm.prank(B1);
        uint256 paid = escrow.claim(address(token), recipient);
        assert(paid == a1 + a3);
        _conserved(dust);

        vm.prank(B1);
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IPayoutEscrow.claim, (address(token), recipient)));
        assert(!ok && _is(ret, IPayoutEscrow.NothingToClaim.selector));

        vm.prank(B2);
        assert(escrow.claim(address(token), recipient) == a2);
        _conserved(dust);
    }

    function _conserved(
        uint256 dust
    ) internal view {
        uint256 c1 = escrow.claimable(address(token), B1);
        uint256 c2 = escrow.claimable(address(token), B2);
        uint256 total = escrow.totalClaimable(address(token));
        assert(total == c1 + c2);
        assert(c1 <= total && c2 <= total);
        assert(token.balanceOf(address(escrow)) == total + dust);
    }

    /// @notice With an issuer fee of `bps` (up to 1%), the credit is exactly the amount that arrived, or the deposit
    /// reverts with `TransferMismatch` when nothing arrived.
    // PROP-052 verifies: REQ-ESCROW-003, REQ-ESCROW-011, INV-061, Q-271
    function check_PROP_052_feeTokenCreditsReceived(
        uint256 amount,
        uint256 bps
    ) public {
        vm.assume(amount > 0 && amount <= type(uint64).max && bps <= 100);
        token.setFeeBps(bps);
        token.mint(SWAP, amount);
        vm.startPrank(SWAP);
        lock.acquire();
        token.approve(address(escrow), amount);
        (bool ok, bytes memory ret) =
            address(escrow).call(abi.encodeCall(IPayoutEscrow.deposit, (address(token), B1, amount)));
        vm.stopPrank();
        uint256 arrived = amount - amount * bps / 10_000;
        if (ok) {
            assert(escrow.claimable(address(token), B1) == arrived && arrived > 0);
            assert(token.balanceOf(address(escrow)) == escrow.totalClaimable(address(token)));
        } else {
            assert(arrived == 0 && _is(ret, IPayoutEscrow.TransferMismatch.selector));
        }
    }
}
