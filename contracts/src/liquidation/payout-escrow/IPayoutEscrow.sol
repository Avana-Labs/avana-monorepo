// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IPayoutEscrow
/// @notice The payout escrow: holds a liquidation payout that LPVaultSwap cannot deliver to its recipient, which is
/// its only job (Q-401; the contract keeps its `PayoutEscrow` name, though there is no in-kind settlement). LPVaultSwap
/// sends each payout with a gas-limited call that cannot revert the liquidation: the borrower's surplus, Avana's fee to
/// `feeRecipient` and the `settlePending` route residue. If a transfer reverts,
/// returns `false` or runs out of its gas (for example a recipient blocklisted by the token's issuer), LPVaultSwap
/// deposits the amount here, credited to that account and token, so a failed payout never reverts a liquidation
/// (REQ-SWAP-076, AMMN N2a). The credited account later claims its whole credit to any recipient it names.
/// @dev Immutable: no proxy, `delegatecall`, `selfdestruct`, owner, role, setter, pause, sweep, rescue or
/// arbitrary-call function. Constructor arguments, both immutable: `lpVaultSwap` (LPVaultSwap's fixed proxy address,
/// the only depositor) and `lock` (the protocol Lock, deployed before the escrow); the constructor reverts with
/// `ZeroAddress` unless both are non-zero and with `LockMismatch` unless `lock` has code and its `LP_VAULT_SWAP()` is
/// `lpVaultSwap`. Storage: `claimable[token][account]` and `totalClaimable[token]` in token base units, plus a transient
/// (EIP-1153) reentrancy flag at `avana.escrow.reentrancy` held for the whole of `deposit` and `claim`. Tokens leave the escrow only through `claim`, to the
/// recipient the credited account names, so a compromised Avana or Aave key or a hostile LPVaultSwap upgrade cannot
/// take a credited payout. For every token, `totalClaimable[token]` equals the sum of `claimable[token][b]` over
/// all accounts and, while only the escrow moves its own balance, the balance is at least `totalClaimable[token]`;
/// tokens sent by plain transfer, and any rise of a deposit above its request, raise the balance without any credit
/// and no function moves them. If the issuer burns from the escrow or a negative rebase lowers its balance, claims are
/// paid first come, first served and the last ones revert until the balance is restored. The escrow checks no price, price state, Hub pause
/// state or reason, circuit breaker, address freeze, market status or token listing and calls no Avana contract other
/// than the Lock views, so a claim runs in every application state (None, Frozen, Paused for either reason), under every
/// breaker and for a frozen account; the escrow is in the address-freeze protected set. Example: deposits of 1,627,460 raw USDC for `b1` and 3,100,000 for `b2` give
/// `totalClaimable[USDC] = 4,727,460`; a direct 10 USDC transfer makes the balance 14,727,460 with `totalClaimable`
/// unchanged; after `b1` claims, both fall by 1,627,460.
/// @custom:spec REQ-ESCROW-001, REQ-ESCROW-005, REQ-ESCROW-006, REQ-ESCROW-007, REQ-ESCROW-008, REQ-ACCESS-066, REQ-ROLE-099, REQ-ROLE-100, REQ-ARCH-047, REQ-ARCH-149, REQ-ARCH-150, INV-052, INV-061, Q-124, Q-148, Q-214, Q-217, Q-226, Q-227, Q-241, Q-242, Q-271, Q-401
interface IPayoutEscrow {
    /// @notice Emitted when `deposit` credits a payout to an account.
    /// @param token The token: the debt asset, or a pool token for route residue.
    /// @param account The credited account: the borrower's wallet, the keeper or `feeRecipient`.
    /// @param amount Amount credited, the measured amount received, token base units.
    /// @custom:spec REQ-ESCROW-003, Q-214, Q-271
    event RemainderEscrowed(address indexed token, address indexed account, uint256 amount);

    /// @notice Emitted when `claim` pays an account's whole credit of a token.
    /// @param token The token.
    /// @param account The credited account (`msg.sender`).
    /// @param recipient The recipient the account named.
    /// @param amount Amount paid, token base units.
    /// @custom:spec REQ-ESCROW-004, Q-214
    event RemainderClaimed(address indexed token, address indexed account, address recipient, uint256 amount);

    /// @notice `deposit` was called by an address other than `LP_VAULT_SWAP`.
    /// @custom:spec REQ-ESCROW-002, REQ-ESCROW-009
    error NotLPVaultSwap();

    /// @notice `deposit` ran while `LOCK.holder()` is not `LP_VAULT_SWAP`.
    /// @custom:spec REQ-ESCROW-002, REQ-ESCROW-009
    error NotLocked();

    /// @notice `deposit` with `amount == 0`; LPVaultSwap never deposits a zero payout, so only a faulty caller
    /// reaches it.
    /// @custom:spec REQ-ESCROW-002, REQ-ESCROW-010, Q-217
    error ZeroAmount();

    /// @notice `deposit` with `account == address(0)`.
    /// @custom:spec REQ-ESCROW-002, REQ-ESCROW-010
    error InvalidAccount();

    /// @notice In `deposit`, the escrow's balance of `token` did not rise; in `claim`, it fell by more than the amount
    /// paid (a sender-side fee).
    /// @custom:spec REQ-ESCROW-003, REQ-ESCROW-004, REQ-ESCROW-011
    error TransferMismatch();

    /// @notice `claim` ran while `LOCK.isLocked()` is true, so a claim never runs inside an Avana call tree.
    /// @custom:spec REQ-ESCROW-004, REQ-ESCROW-012
    error LockHeld();

    /// @notice `claim` named `address(0)` or the escrow itself as recipient.
    /// @custom:spec REQ-ESCROW-004, REQ-ESCROW-014
    error InvalidRecipient();

    /// @notice `claim` found `claimable[token][msg.sender] == 0`.
    /// @custom:spec REQ-ESCROW-004, REQ-ESCROW-008, REQ-ESCROW-013
    error NothingToClaim();

    /// @notice `deposit` or `claim` was entered while the transient reentrancy flag is set.
    /// @dev The first check of both functions, so a reentrant call reverts with it whatever its caller and arguments.
    /// @custom:spec REQ-ESCROW-007, REQ-ESCROW-016
    error Reentrancy();

    /// @notice The constructor was given `address(0)` for `lpVaultSwap` or `lock`.
    /// @custom:spec REQ-ESCROW-001
    error ZeroAddress();

    /// @notice The constructor's `lock` has no code or its `LP_VAULT_SWAP()` is not `lpVaultSwap`.
    /// @custom:spec REQ-ESCROW-001, REQ-ESCROW-019
    error LockMismatch();

    /// @notice Pulls `amount` of `token` from LPVaultSwap and credits it to `account`.
    /// @dev Caller: `LP_VAULT_SWAP` only (`NotLPVaultSwap`), only while `LOCK.holder() == LP_VAULT_SWAP` (`NotLocked`),
    /// after the gas-limited transfer of a payout to `account` failed; LPVaultSwap approves exactly `amount`
    /// beforehand. The call reverts with `ZeroAmount` if `amount == 0` and `InvalidAccount` if `account ==
    /// address(0)`. Holds the reentrancy flag (`Reentrancy`). Requests `amount` from `LP_VAULT_SWAP` with
    /// `SafeERC20.safeTransferFrom`, measures the rise of its own balance of `token`, reverts with `TransferMismatch`
    /// if the balance did not rise, sets `received = min(rise, amount)`, adds `received` to `claimable[token][account]`
    /// and `totalClaimable[token]` and emits `RemainderEscrowed` with `received`: a fee-taking token credits what
    /// arrived, and a rise above the request (a rounding-up or positive-rebase token) credits `amount` and leaves the
    /// surplus as an unattributed donation.
    /// A revert here (including a token that blocks the escrow's own address) reverts the whole liquidation; that case
    /// is a token blocking an Avana contract, handled by the token-issuer playbook.
    /// @param token The debt asset (fee or payout) or a pool token (route residue); one deposit per undelivered
    /// payout.
    /// @param account The intended recipient: the borrower's wallet (`PositionProxy.WALLET()`), the keeper or
    /// `feeRecipient`.
    /// @param amount The payout that could not be delivered, token base units.
    /// @custom:spec REQ-ESCROW-002, REQ-ESCROW-003, REQ-ESCROW-007, REQ-ESCROW-009, REQ-ESCROW-010, REQ-ESCROW-011, REQ-ESCROW-016, REQ-SWAP-076, REQ-SWAP-082, REQ-LOCK-023, Q-214, Q-217, Q-271
    function deposit(
        address token,
        address account,
        uint256 amount
    ) external;

    /// @notice Pays the caller's whole credit of `token` to `recipient`.
    /// @dev Callable only by a credited account as `msg.sender`; there is no claim-on-behalf, signature path or way to
    /// move a credit, and credits never expire. The call reverts with `LockHeld` while `LOCK.isLocked()` is true, with
    /// `InvalidRecipient` for `address(0)` or the escrow itself and with `NothingToClaim` if the credit is 0. Holds the
    /// reentrancy flag (`Reentrancy`) and follows checks-effects-interactions: sets `amount` to the credit, clears the
    /// credit and subtracts `amount` from `totalClaimable[token]` before transferring `amount` to `recipient` with
    /// `SafeERC20.safeTransfer`, reverts with `TransferMismatch` if its own balance fell by more than `amount` (a
    /// sender-side fee would otherwise be paid from other credits), then emits `RemainderClaimed` with `amount`, the
    /// amount sent (a recipient-side fee lowers what arrives, not what the escrow pays). If the token refuses
    /// `recipient`, the call reverts, the credit stays and the account claims again to another recipient. If the
    /// escrow's balance is below the credit (an issuer burn or a negative rebase), the transfer reverts and the credit
    /// stays.
    /// @param token The token.
    /// @param recipient Address that receives the tokens.
    /// @return amount Amount paid, token base units.
    /// @custom:spec REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-007, REQ-ESCROW-008, REQ-ESCROW-012, REQ-ESCROW-013, REQ-ESCROW-014, REQ-ESCROW-015, REQ-ESCROW-016, Q-214
    function claim(
        address token,
        address recipient
    ) external returns (uint256 amount);

    /// @notice Amount of `token` credited to `account` and not yet claimed.
    /// @param token The token.
    /// @param account The account.
    /// @return amount Credit, token base units.
    /// @custom:spec REQ-ESCROW-006, REQ-LENS-027
    function claimable(
        address token,
        address account
    ) external view returns (uint256 amount);

    /// @notice Sum of `claimable[token][b]` over all accounts.
    /// @param token The token.
    /// @return amount Total credit, token base units; at most the escrow's balance of `token`.
    /// @custom:spec REQ-ESCROW-006, INV-061
    function totalClaimable(
        address token
    ) external view returns (uint256 amount);

    /// @notice LPVaultSwap's fixed proxy address, the only depositor (immutable).
    /// @return lpVaultSwap Address.
    /// @custom:spec REQ-ESCROW-001, REQ-ESCROW-002
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Protocol Lock (immutable), read through `holder()` and `isLocked()`.
    /// @return lock Address.
    /// @custom:spec REQ-ESCROW-001, REQ-ESCROW-002, REQ-ESCROW-004
    function LOCK() external view returns (address lock);
}
