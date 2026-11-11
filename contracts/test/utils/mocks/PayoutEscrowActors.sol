// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PayoutDepositor
/// @notice Test stand-in for LPVaultSwap on the escrow side of a failed payout: it holds the payout, takes the Lock,
/// approves the escrow for exactly the amount, calls `deposit` and frees the Lock, as `REQ-SWAP-076` describes. It can
/// also deposit without the Lock, or make any call while holding it, so suites reach every Lock state in one call.
/// @dev The Lock and escrow are set once after deployment, because both constructors need this contract's address.
contract PayoutDepositor {
    ILock public lock;
    IPayoutEscrow public escrow;

    function setUp(
        ILock lock_,
        IPayoutEscrow escrow_
    ) external {
        require(address(lock) == address(0), "set");
        lock = lock_;
        escrow = escrow_;
    }

    /// @notice The production path: acquire, exact approval, deposit, release.
    function depositUnderLock(
        address token,
        address account,
        uint256 amount
    ) external {
        lock.acquire();
        IERC20(token).approve(address(escrow), amount);
        escrow.deposit(token, account, amount);
        lock.release();
    }

    /// @notice A deposit while LPVaultSwap does not hold the Lock.
    function depositUnlocked(
        address token,
        address account,
        uint256 amount
    ) external {
        IERC20(token).approve(address(escrow), amount);
        escrow.deposit(token, account, amount);
    }

    /// @notice Any call while holding the Lock; the inner revert is bubbled.
    function callUnderLock(
        address target,
        bytes calldata data
    ) external returns (bytes memory ret) {
        lock.acquire();
        ret = _call(target, data);
        lock.release();
    }

    /// @notice Any call without the Lock (a token hook re-entering through LPVaultSwap); the inner revert is bubbled.
    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory ret) {
        ret = _call(target, data);
    }

    function _call(
        address target,
        bytes calldata data
    ) private returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @title PayoutActor
/// @notice A credited account that is a contract (a keeper contract, a Safe, a borrower wallet): it claims as
/// `msg.sender`, forwards any call (a token hook re-entering through it) and bubbles every revert.
contract PayoutActor {
    function claim(
        IPayoutEscrow escrow,
        address token,
        address recipient
    ) external returns (uint256 amount) {
        amount = escrow.claim(token, recipient);
    }

    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
