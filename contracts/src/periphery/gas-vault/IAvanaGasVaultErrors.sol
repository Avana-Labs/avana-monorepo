// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaGasVaultErrors
/// @notice Errors of the AvanaGasVault. Every amount is in wei of the chain's native gas token.
interface IAvanaGasVaultErrors {
    /// @notice A constructor address is `address(0)`, or `TREASURY` equals `TIMELOCK` or `GUARDIAN`.
    /// @custom:spec REQ-GASV-002
    error InvalidAddress();

    /// @notice The constructor's `maxSigners` is 0 or above `MAX_SIGNERS_LIMIT`.
    /// @param maxSigners The rejected value.
    /// @custom:spec REQ-GASV-002
    error InvalidMaxSigners(uint256 maxSigners);

    /// @notice The caller is not `TIMELOCK`.
    /// @custom:spec REQ-GASV-007, REQ-GASV-008, REQ-GASV-011, REQ-GASV-012
    error NotTimelock();

    /// @notice The caller is neither `GUARDIAN` nor `TIMELOCK`.
    /// @custom:spec REQ-GASV-009, REQ-GASV-010, REQ-GASV-011
    error NotGuardianOrTimelock();

    /// @notice `addSigner` named `address(0)`, the vault, `TREASURY`, `TIMELOCK`, `GUARDIAN` or a listed signer.
    /// @param signer The rejected address.
    /// @custom:spec REQ-GASV-007
    error InvalidSigner(address signer);

    /// @notice The signer is not on the allowlist.
    /// @param signer The address named.
    /// @custom:spec REQ-GASV-004, REQ-GASV-008, REQ-GASV-009, REQ-GASV-010
    error UnknownSigner(address signer);

    /// @notice The allowlist already holds `MAX_SIGNERS` signers.
    /// @custom:spec REQ-GASV-007
    error TooManySigners();

    /// @notice A signer configuration breaks `minBalance ≤ targetBalance`, has a value above `2^80 − 1`, or (outside
    /// `tightenSigner`) a zero `minBalance` or `periodCap`.
    /// @param minBalance The rejected refill trigger.
    /// @param targetBalance The rejected refill level.
    /// @param periodCap The rejected 24 h cap.
    /// @custom:spec REQ-GASV-007, REQ-GASV-008, REQ-GASV-009
    error InvalidConfig(uint256 minBalance, uint256 targetBalance, uint256 periodCap);

    /// @notice `tightenSigner` would raise one of the three values.
    /// @custom:spec REQ-GASV-009
    error NotTighter();

    /// @notice `topUp` named a signer whose balance is not below its `minBalance`.
    /// @param signer The signer.
    /// @param balance Its balance.
    /// @param minBalance Its refill trigger.
    /// @custom:spec REQ-GASV-004
    error NotBelowMinimum(address signer, uint256 balance, uint256 minBalance);

    /// @notice `topUp` is due but would send 0: the signer's 24 h cap is used up or the vault holds nothing.
    /// @param signer The signer.
    /// @param requested `targetBalance − balance`.
    /// @param capRoom What the 24 h cap still allows.
    /// @param held The vault's balance.
    /// @custom:spec REQ-GASV-004, REQ-GASV-005
    error NothingToSend(address signer, uint256 requested, uint256 capRoom, uint256 held);

    /// @notice The ETH transfer to the signer or to `TREASURY` failed.
    /// @param to The recipient.
    /// @param amount The amount.
    /// @custom:spec REQ-GASV-004, REQ-GASV-012
    error SendFailed(address to, uint256 amount);

    /// @notice A top-up was called while the vault is paused.
    /// @custom:spec REQ-GASV-011
    error VaultPaused();

    /// @notice `withdraw` asked for 0 or for more than the vault holds.
    /// @param amount The amount asked.
    /// @param held The vault's balance.
    /// @custom:spec REQ-GASV-012
    error InvalidWithdrawal(uint256 amount, uint256 held);
}
