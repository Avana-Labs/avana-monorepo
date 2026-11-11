// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../lock/lock/ILock.sol";
import {IPayoutEscrow} from "./IPayoutEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title PayoutEscrow
/// @notice The payout escrow (2.18): holds each liquidation payout LPVaultSwap could not deliver, credited to its
/// recipient and token, until that recipient claims the whole credit to an address it names.
/// @dev Immutable, with no owner, role, setter, pause, sweep, rescue, fallback, `receive`, `delegatecall` or
/// `selfdestruct`. Deposits come only from `LP_VAULT_SWAP` while it holds the Lock and credit the measured balance
/// rise, capped at the requested amount; claims run only while the Lock is free and revert if the escrow's balance
/// falls by more than the amount paid. Both hold a transient reentrancy flag at `REENTRANCY_SLOT` (OpenZeppelin
/// `TransientSlot`), checked first. External calls: `LOCK.holder()` and `LOCK.isLocked()` (views of the immutable
/// Lock), and `balanceOf`, `transferFrom` and `transfer` of the deposited or claimed token. Conservation: for every token
/// `t`, `totalClaimable[t] == Σ_a claimable[t][a]`, and `t.balanceOf(this) >= totalClaimable[t]` while no one but the
/// escrow moves its balance (INV-061); if the token's issuer burns from the escrow or a negative rebase lowers its
/// balance, claims are paid first come, first served and the last ones revert until the balance is restored.
/// @custom:spec REQ-ESCROW-001, REQ-ESCROW-005, REQ-ESCROW-006, REQ-ESCROW-007, REQ-ESCROW-008, REQ-ESCROW-017, REQ-ESCROW-018, INV-061, Q-214, Q-401
contract PayoutEscrow is IPayoutEscrow {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.BooleanSlot;

    /// @notice ERC-7201 transient slot of the reentrancy flag:
    /// `keccak256(abi.encode(uint256(keccak256("avana.escrow.reentrancy")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant REENTRANCY_SLOT = 0xa75fff4cb584554d1fc59956357ed91e22a866262ee7022db6d589f2ebdb4400;

    /// @inheritdoc IPayoutEscrow
    address public immutable override LP_VAULT_SWAP;

    /// @inheritdoc IPayoutEscrow
    address public immutable override LOCK;

    /// @inheritdoc IPayoutEscrow
    mapping(address token => mapping(address account => uint256 amount)) public override claimable;

    /// @inheritdoc IPayoutEscrow
    mapping(address token => uint256 amount) public override totalClaimable;

    /// @notice Fixes the only depositor and the Lock, which must already be deployed and name `lpVaultSwap` as its
    /// LPVaultSwap member.
    /// @dev Reverts `ZeroAddress` for a zero argument and `LockMismatch` unless `lock` has code and
    /// `ILock(lock).LP_VAULT_SWAP() == lpVaultSwap`, so a mis-wired escrow (another LPVaultSwap, or the AaveAdapter)
    /// cannot be deployed. `lpVaultSwap` needs no code (a predicted proxy address).
    /// @param lpVaultSwap The chain's LPVaultSwap fixed proxy address.
    /// @param lock The chain's Lock.
    /// @custom:spec REQ-ESCROW-001, REQ-ESCROW-019
    constructor(
        address lpVaultSwap,
        address lock
    ) {
        if (lpVaultSwap == address(0) || lock == address(0)) revert ZeroAddress();
        LP_VAULT_SWAP = lpVaultSwap;
        LOCK = lock;
        // A view of the Lock, deployed before the escrow; a Lock without code, or one naming another LPVaultSwap, fails.
        if (lock.code.length == 0 || ILock(lock).LP_VAULT_SWAP() != lpVaultSwap) revert LockMismatch();
    }

    /// @notice Holds the transient reentrancy flag for the whole call; the first check of `deposit` and `claim`.
    /// @custom:spec REQ-ESCROW-007, REQ-ESCROW-016
    modifier nonReentrant() {
        TransientSlot.BooleanSlot flag = REENTRANCY_SLOT.asBoolean();
        if (flag.tload()) revert Reentrancy();
        flag.tstore(true);
        _;
        flag.tstore(false);
    }

    /// @inheritdoc IPayoutEscrow
    /// @custom:spec REQ-ESCROW-002, REQ-ESCROW-003, REQ-ESCROW-007, REQ-ESCROW-009, REQ-ESCROW-010, REQ-ESCROW-011, REQ-ESCROW-016, REQ-ESCROW-017, REQ-ESCROW-018, REQ-SWAP-076, REQ-SWAP-082, REQ-LOCK-023, INV-021, INV-054, Q-148, Q-214, Q-217, Q-271
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
        // A balance that did not rise (or fell) credits nothing. A rise above the request credits only the request: the
        // surplus is an unattributed donation, never a payout, and never reverts the liquidation.
        if (balanceAfter <= balanceBefore) revert TransferMismatch();
        uint256 received = balanceAfter - balanceBefore;
        if (received > amount) received = amount;

        // Checked sums: each credit is at most its own measured balance rise, so the totals stay within the token amounts
        // that ever reached the escrow.
        claimable[token][account] += received;
        totalClaimable[token] += received;
        emit RemainderEscrowed(token, account, received);
    }

    /// @inheritdoc IPayoutEscrow
    /// @custom:spec REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-007, REQ-ESCROW-008, REQ-ESCROW-012, REQ-ESCROW-013, REQ-ESCROW-014, REQ-ESCROW-015, REQ-ESCROW-016, INV-021, INV-053, INV-081, Q-214, Q-217, Q-241, Q-242
    function claim(
        address token,
        address recipient
    ) external override nonReentrant returns (uint256 amount) {
        if (ILock(LOCK).isLocked()) revert LockHeld();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        amount = claimable[token][msg.sender];
        if (amount == 0) revert NothingToClaim();

        // Effects before the transfer: a callback during it finds the credit cleared (and the flag set).
        claimable[token][msg.sender] = 0;
        totalClaimable[token] -= amount;

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransfer(recipient, amount);
        // A token that takes a fee from the sender on top of `amount` would pay this claim out of other credits. A balance
        // that did not fall by more (a recipient-side fee, a rebase up) passes.
        if (asset.balanceOf(address(this)) + amount < balanceBefore) revert TransferMismatch();
        emit RemainderClaimed(token, msg.sender, recipient, amount);
    }
}
