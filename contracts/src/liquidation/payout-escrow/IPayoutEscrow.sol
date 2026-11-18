// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IPayoutEscrow
/// @notice Holds liquidation payouts LPVaultSwap could not deliver until each credited recipient claims them.
/// @dev Immutable, with no owner or admin function. Tokens leave only through `claim` by the credited account.
interface IPayoutEscrow {
    /// @notice Emitted when `deposit` credits a payout to an account.
    /// @param amount Amount credited: the measured amount received.
    event RemainderEscrowed(address indexed token, address indexed account, uint256 amount);

    /// @notice Emitted when `claim` pays an account's whole credit of a token, or the amount it named.
    event RemainderClaimed(address indexed token, address indexed account, address recipient, uint256 amount);

    error NotLPVaultSwap();

    /// @notice `deposit` ran while `LOCK.holder()` is not `LP_VAULT_SWAP`.
    error NotLocked();

    /// @notice `deposit` or the amount-limited `claim` with `amount == 0`.
    error ZeroAmount();

    error InvalidAccount();

    /// @notice In `deposit`, the balance did not rise; in `claim`, it fell by more than the amount paid.
    error TransferMismatch();

    /// @notice `claim` ran while `LOCK.isLocked()` is true.
    error LockHeld();

    /// @notice `claim` named `address(0)` or the escrow itself as recipient.
    error InvalidRecipient();

    error NothingToClaim();

    error AmountExceedsCredit();

    error Reentrancy();

    error ZeroAddress();

    /// @notice The constructor's `lock` has no code or its `LP_VAULT_SWAP()` is not `lpVaultSwap`.
    error LockMismatch();

    /// @notice Pulls `amount` of `token` from LPVaultSwap and credits it to `account`.
    /// @dev Only `LP_VAULT_SWAP`, while it holds the Lock. Credits the measured balance rise, capped at `amount`.
    function deposit(
        address token,
        address account,
        uint256 amount
    ) external;

    /// @notice Pays the caller's whole credit of `token` to `recipient`.
    /// @dev Only while the Lock is free. Reverts `TransferMismatch` if the escrow's balance fell by more than `amount`.
    function claim(
        address token,
        address recipient
    ) external returns (uint256 amount);

    /// @notice Pays `amount` of the caller's credit of `token` to `recipient`, leaving the rest of the credit standing.
    /// @dev Same rules as the whole-credit `claim`; reverts `AmountExceedsCredit` if `amount` is above the credit.
    function claim(
        address token,
        address recipient,
        uint256 amount
    ) external returns (uint256 paid);

    /// @notice Amount of `token` credited to `account` and not yet claimed.
    function claimable(
        address token,
        address account
    ) external view returns (uint256 amount);

    /// @notice Sum of `claimable[token][b]` over all accounts.
    function totalClaimable(
        address token
    ) external view returns (uint256 amount);

    /// @notice LPVaultSwap's fixed proxy address, the only depositor.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Protocol Lock.
    function LOCK() external view returns (address lock);
}
