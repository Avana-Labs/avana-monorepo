// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {PayoutEscrow} from "../../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {LockMember} from "../../utils/mocks/LockMember.sol";
import {PayoutActor, PayoutDepositor} from "../../utils/mocks/PayoutEscrowActors.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";

/// @title PayoutEscrowProperties
/// @notice Echidna and Medusa properties of the payout escrow (2.18). Between transactions: `totalClaimable` is the
/// sum of the credits, the balance is that sum plus donations, every account's credited amount equals its claims plus
/// its credit, the immutables are fixed and the Lock is free. Inside one transaction: LPVaultSwap's deposit under the
/// Lock credits exactly the amount; a claim pays the whole credit to the named recipient or reverts with the first
/// failing check; a claim under the Lock, a deposit by anyone else and a reentrant claim all revert and change nothing.
/// @dev `property_` functions run in property mode; `deposit`, `claim`, `claimWhileLocked`, `outsiderDeposit`,
/// `reenterClaim` and `donate` run in assertion mode, each selecting among concrete cases with `if` branches.
contract PayoutEscrowProperties {
    Lock internal immutable LOCK;
    PayoutEscrow internal immutable ESCROW;
    PayoutDepositor internal immutable SWAP;
    LockMember internal immutable ADAPTER;
    PayoutToken internal immutable TOKEN;
    PayoutActor internal immutable A0;
    PayoutActor internal immutable A1;
    PayoutActor internal immutable A2;
    address internal constant EOA_RECIPIENT = address(0xBEEF);

    uint256[3] internal credited;
    uint256[3] internal claimed;
    uint256 internal donated;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        ADAPTER = new LockMember();
        SWAP = new PayoutDepositor();
        LOCK = new Lock(address(ADAPTER), address(SWAP));
        ESCROW = new PayoutEscrow(address(SWAP), address(LOCK));
        SWAP.setUp(LOCK, ESCROW);
        ADAPTER.setLock(LOCK);
        TOKEN = new PayoutToken("USDC", 6);
        A0 = new PayoutActor();
        A1 = new PayoutActor();
        A2 = new PayoutActor();
    }

    function _actor(
        uint8 who
    ) internal view returns (PayoutActor) {
        if (who % 3 == 0) return A0;
        if (who % 3 == 1) return A1;
        return A2;
    }

    function _credit(
        PayoutActor a
    ) internal view returns (uint256) {
        return ESCROW.claimable(address(TOKEN), address(a));
    }

    // ─── Properties (between transactions) ───

    function property_totalIsSumOfCredits() external view returns (bool) {
        return ESCROW.totalClaimable(address(TOKEN)) == _credit(A0) + _credit(A1) + _credit(A2);
    }

    function property_balanceIsCreditsPlusDonations() external view returns (bool) {
        return TOKEN.balanceOf(address(ESCROW)) == ESCROW.totalClaimable(address(TOKEN)) + donated;
    }

    function property_creditedEqualsClaimedPlusHeld() external view returns (bool) {
        return credited[0] == claimed[0] + _credit(A0) && credited[1] == claimed[1] + _credit(A1)
            && credited[2] == claimed[2] + _credit(A2);
    }

    function property_immutablesFixedAndLockFree() external view returns (bool) {
        return ESCROW.LP_VAULT_SWAP() == address(SWAP) && ESCROW.LOCK() == address(LOCK) && !LOCK.isLocked();
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice LPVaultSwap's deposit under the Lock credits exactly `amount` (no fee on this token); zero is refused.
    function deposit(
        uint8 who,
        uint128 amount
    ) external {
        PayoutActor a = _actor(who);
        uint256 before = _credit(a);
        TOKEN.mint(address(SWAP), amount);
        try SWAP.depositUnderLock(address(TOKEN), address(a), amount) {
            assert(amount > 0 && _credit(a) == before + amount);
            credited[who % 3] += amount;
        } catch (bytes memory reason) {
            assert(
                amount == 0 && keccak256(reason) == keccak256(abi.encodeWithSelector(IPayoutEscrow.ZeroAmount.selector))
            );
            assert(_credit(a) == before);
        }
        ++sequences;
    }

    /// @notice A credited actor claims to another actor, an EOA, `address(0)` or the escrow.
    function claim(
        uint8 who,
        uint8 to
    ) external {
        PayoutActor a = _actor(who);
        address recipient;
        if (to % 4 == 0) recipient = address(_actor(uint8(who % 3) + 1));
        else if (to % 4 == 1) recipient = EOA_RECIPIENT;
        else if (to % 4 == 2) recipient = address(0);
        else recipient = address(ESCROW);
        uint256 credit = _credit(a);
        uint256 recipientBefore = TOKEN.balanceOf(recipient);
        try a.claim(ESCROW, address(TOKEN), recipient) returns (uint256 paid) {
            assert(credit > 0 && paid == credit && to % 4 < 2);
            assert(_credit(a) == 0 && TOKEN.balanceOf(recipient) == recipientBefore + paid);
            claimed[who % 3] += paid;
        } catch (bytes memory reason) {
            assert(_credit(a) == credit);
            bytes4 expected =
                to % 4 >= 2 ? IPayoutEscrow.InvalidRecipient.selector : IPayoutEscrow.NothingToClaim.selector;
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(expected)));
        }
        ++sequences;
    }

    /// @notice A claim while either member holds the Lock reverts with `LockHeld` and changes nothing.
    function claimWhileLocked(
        uint8 who,
        bool swapHolds
    ) external {
        PayoutActor a = _actor(who);
        uint256 credit = _credit(a);
        bytes memory call = abi.encodeCall(PayoutActor.claim, (ESCROW, address(TOKEN), EOA_RECIPIENT));
        bytes memory reason;
        if (swapHolds) {
            try SWAP.callUnderLock(address(a), call) {
                assert(false);
            } catch (bytes memory r) {
                reason = r;
            }
        } else {
            bool ok;
            (ok, reason) = ADAPTER.acquireCallRelease(address(a), call);
            assert(!ok);
        }
        assert(keccak256(reason) == keccak256(abi.encodeWithSelector(IPayoutEscrow.LockHeld.selector)));
        assert(_credit(a) == credit && !LOCK.isLocked());
        ++sequences;
    }

    /// @notice Anyone other than LPVaultSwap (an actor, the AaveAdapter under its own Lock) is refused.
    function outsiderDeposit(
        uint8 who,
        uint128 amount
    ) external {
        PayoutActor a = _actor(who);
        uint256 total = ESCROW.totalClaimable(address(TOKEN));
        bytes memory dep = abi.encodeCall(IPayoutEscrow.deposit, (address(TOKEN), address(a), amount));
        try a.execute(address(ESCROW), dep) {
            assert(false);
        } catch (bytes memory reason) {
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(IPayoutEscrow.NotLPVaultSwap.selector)));
        }
        (bool ok,) = ADAPTER.acquireCallRelease(address(ESCROW), dep);
        assert(!ok && ESCROW.totalClaimable(address(TOKEN)) == total);
        ++sequences;
    }

    /// @notice A token callback through the credited actor during its claim cannot claim again.
    function reenterClaim(
        uint8 who
    ) external {
        PayoutActor a = _actor(who);
        uint256 credit = _credit(a);
        if (credit == 0) return;
        TOKEN.setHook(address(a), abi.encodeCall(PayoutActor.claim, (ESCROW, address(TOKEN), EOA_RECIPIENT)));
        try a.claim(ESCROW, address(TOKEN), EOA_RECIPIENT) {
            assert(false);
        } catch (bytes memory reason) {
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(IPayoutEscrow.Reentrancy.selector)));
        }
        TOKEN.setHook(address(0), "");
        assert(_credit(a) == credit);
        ++sequences;
    }

    /// @notice A plain transfer to the escrow credits nobody.
    function donate(
        uint32 dust
    ) external {
        uint256 total = ESCROW.totalClaimable(address(TOKEN));
        TOKEN.mint(address(ESCROW), dust);
        donated += dust;
        assert(ESCROW.totalClaimable(address(TOKEN)) == total);
        ++sequences;
    }
}
