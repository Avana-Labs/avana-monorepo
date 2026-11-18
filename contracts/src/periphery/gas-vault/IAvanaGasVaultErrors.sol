// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaGasVaultErrors
/// @notice Errors of the AvanaGasVault. Every amount is in wei of the chain's native gas token.
interface IAvanaGasVaultErrors {
    /// @notice A constructor address is `address(0)`, or `TREASURY` equals `TIMELOCK` or `GUARDIAN`.
    error InvalidAddress();

    /// @notice The constructor's `maxSigners` is 0 or above `MAX_SIGNERS_LIMIT`.
    error InvalidMaxSigners(uint256 maxSigners);

    /// @notice The caller is not `TIMELOCK`.
    error NotTimelock();

    /// @notice The caller is neither `GUARDIAN` nor `TIMELOCK`.
    error NotGuardianOrTimelock();

    /// @notice `addSigner` named `address(0)`, the vault, `TREASURY`, `TIMELOCK`, `GUARDIAN` or a listed signer.
    error InvalidSigner(address signer);

    /// @notice The signer is not on the allowlist.
    error UnknownSigner(address signer);

    /// @notice The allowlist already holds `MAX_SIGNERS` signers.
    error TooManySigners();

    /// @notice Config breaks `minBalance ≤ targetBalance`, exceeds 80 bits or has a zero outside `tightenSigner`.
    error InvalidConfig(uint256 minBalance, uint256 targetBalance, uint256 periodCap);

    /// @notice `tightenSigner` would raise one of the three values.
    error NotTighter();

    /// @notice `topUp` named a signer whose balance is not below its `minBalance`.
    error NotBelowMinimum(address signer, uint256 balance, uint256 minBalance);

    /// @notice `topUp` is due but would send 0: the signer's 24 h cap is used up or the vault holds nothing.
    /// @param requested `targetBalance − balance`.
    /// @param capRoom What the 24 h cap still allows.
    error NothingToSend(address signer, uint256 requested, uint256 capRoom, uint256 held);

    /// @notice The ETH transfer to the signer or to `TREASURY` failed.
    error SendFailed(address to, uint256 amount);

    /// @notice A top-up was called while the vault is paused.
    error VaultPaused();

    /// @notice `withdraw` asked for 0 or for more than the vault holds.
    error InvalidWithdrawal(uint256 amount, uint256 held);
}
