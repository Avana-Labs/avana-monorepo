// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaGasVaultEvents
/// @notice Events of the AvanaGasVault. Every amount is in wei of the chain's native gas token.
interface IAvanaGasVaultEvents {
    /// @notice ETH was added through `fund` or a plain transfer.
    event Funded(address indexed from, uint256 amount);

    /// @notice A signer was topped up. `amount < requested` means the cap or the vault balance limited it.
    /// @param caller `msg.sender`, who receives nothing.
    /// @param requested `targetBalance − balance` before the send.
    event ToppedUp(address indexed signer, address indexed caller, uint256 amount, uint256 requested);

    /// @notice `topUpAll` skipped a signer whose ETH transfer failed; nothing was sent or recorded for it.
    event TopUpFailed(address indexed signer, uint256 amount);

    /// @notice A signer was added to the allowlist.
    /// @param periodCap Most ETH sent to it in any 24 h.
    event SignerAdded(address indexed signer, uint256 minBalance, uint256 targetBalance, uint256 periodCap);

    /// @notice A signer's configuration changed through `setSignerConfig` or `tightenSigner`.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    event SignerConfigChanged(
        address indexed signer, address indexed by, uint256 minBalance, uint256 targetBalance, uint256 periodCap
    );

    /// @notice A signer was removed from the allowlist.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    event SignerRemoved(address indexed signer, address indexed by);

    /// @notice Top-ups were paused or unpaused.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    event PauseChanged(bool paused, address indexed by);

    /// @notice ETH was withdrawn to `TREASURY`.
    event Withdrawn(uint256 amount);
}
