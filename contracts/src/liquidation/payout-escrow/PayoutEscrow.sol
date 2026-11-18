// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../lock/lock/ILock.sol";
import {IPayoutEscrow} from "./IPayoutEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title PayoutEscrow
/// @notice Holds each liquidation payout LPVaultSwap could not deliver until its recipient claims it.
contract PayoutEscrow is IPayoutEscrow {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /// @notice ERC-7201 transient slot of the reentrancy flag.
    bytes32 private constant REENTRANCY_SLOT = 0xa75fff4cb584554d1fc59956357ed91e22a866262ee7022db6d589f2ebdb4400;

    /// @inheritdoc IPayoutEscrow
    address public immutable override LP_VAULT_SWAP;

    /// @inheritdoc IPayoutEscrow
    address public immutable override LOCK;

    /// @inheritdoc IPayoutEscrow
    mapping(address token => mapping(address account => uint256 amount)) public override claimable;

    /// @inheritdoc IPayoutEscrow
    mapping(address token => uint256 amount) public override totalClaimable;

    /// @notice Fixes the only depositor and the Lock.
    constructor(
        address lpVaultSwap,
        address lock
    ) {
        if (lpVaultSwap == address(0) || lock == address(0)) revert ZeroAddress();
        LP_VAULT_SWAP = lpVaultSwap;
        LOCK = lock;
        if (lock.code.length == 0 || ILock(lock).LP_VAULT_SWAP() != lpVaultSwap) revert LockMismatch();
    }

    modifier nonReentrant() {
        TransientSlot.BooleanSlot flag = REENTRANCY_SLOT.asBoolean();
        if (flag.tload()) revert Reentrancy();
        flag.tstore(true);
        _;
        flag.tstore(false);
    }

    /// @inheritdoc IPayoutEscrow
    function deposit(
        address token,
        address account,
        uint256 amount
    ) external override nonReentrant {
        if (msg.sender != LP_VAULT_SWAP) revert NotLPVaultSwap();
        if (ILock(LOCK).holder() != LP_VAULT_SWAP) revert NotLocked();
        if (amount == 0) revert ZeroAmount();
        if (account == address(0)) revert InvalidAccount();

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(LP_VAULT_SWAP, address(this), amount);
        uint256 balanceAfter = asset.balanceOf(address(this));
        // A rise above the request credits only the request; the surplus is an unattributed donation.
        if (balanceAfter <= balanceBefore) revert TransferMismatch();
        uint256 received = balanceAfter - balanceBefore;
        if (received > amount) received = amount;

        // Checked sums: each credit is at most its measured balance rise.
        claimable[token][account] += received;
        totalClaimable[token] += received;
        emit RemainderEscrowed(token, account, received);
    }

    /// @inheritdoc IPayoutEscrow
    function claim(
        address token,
        address recipient
    ) external override nonReentrant returns (uint256 amount) {
        _checkClaim(recipient);
        amount = claimable[token][msg.sender];
        if (amount == 0) revert NothingToClaim();
        _pay(token, recipient, amount);
    }

    /// @inheritdoc IPayoutEscrow
    function claim(
        address token,
        address recipient,
        uint256 amount
    ) external override nonReentrant returns (uint256 paid) {
        _checkClaim(recipient);
        if (amount == 0) revert ZeroAmount();
        uint256 credit = claimable[token][msg.sender];
        if (credit == 0) revert NothingToClaim();
        if (amount > credit) revert AmountExceedsCredit();
        _pay(token, recipient, amount);
        paid = amount;
    }

    function _checkClaim(
        address recipient
    ) private view {
        if (ILock(LOCK).isLocked()) revert LockHeld();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
    }

    /// @dev `amount` is non-zero and at most `claimable[token][msg.sender]`, checked by the caller.
    function _pay(
        address token,
        address recipient,
        uint256 amount
    ) private {
        // Effects before the transfer: a callback during it finds the credit lowered (and the flag set).
        claimable[token][msg.sender] -= amount;
        totalClaimable[token] -= amount;

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransfer(recipient, amount);
        // A sender-side fee would pay this claim out of other credits.
        if (asset.balanceOf(address(this)) + amount < balanceBefore) revert TransferMismatch();
        emit RemainderClaimed(token, msg.sender, recipient, amount);
    }
}
