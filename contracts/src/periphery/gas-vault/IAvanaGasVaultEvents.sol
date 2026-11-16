// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAvanaGasVaultEvents
/// @notice Events of the AvanaGasVault. Every amount is in wei of the chain's native gas token.
interface IAvanaGasVaultEvents {
    /// @notice ETH was added through `fund` or a plain transfer.
    /// @param from The sender.
    /// @param amount The amount added.
    /// @custom:spec REQ-GASV-003
    event Funded(address indexed from, uint256 amount);

    /// @notice A signer was topped up. `amount < requested` means the 24 h cap or the vault balance limited it (M-36).
    /// @param signer The allowlisted signer paid.
    /// @param caller `msg.sender`, who receives nothing.
    /// @param amount The ETH sent.
    /// @param requested `targetBalance − balance` before the send.
    /// @custom:spec REQ-GASV-004, REQ-GASV-005
    event ToppedUp(address indexed signer, address indexed caller, uint256 amount, uint256 requested);

    /// @notice `topUpAll` skipped a signer whose ETH transfer failed; nothing was sent or recorded for it.
    /// @param signer The signer.
    /// @param amount The amount that failed.
    /// @custom:spec REQ-GASV-006
    event TopUpFailed(address indexed signer, uint256 amount);

    /// @notice A signer was added to the allowlist.
    /// @param signer The signer.
    /// @param minBalance Refill trigger.
    /// @param targetBalance Refill level.
    /// @param periodCap Most ETH sent to it in any 24 h.
    /// @custom:spec REQ-GASV-007
    event SignerAdded(address indexed signer, uint256 minBalance, uint256 targetBalance, uint256 periodCap);

    /// @notice A signer's configuration changed through `setSignerConfig` or `tightenSigner`.
    /// @param signer The signer.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    /// @param minBalance New refill trigger.
    /// @param targetBalance New refill level.
    /// @param periodCap New 24 h cap.
    /// @custom:spec REQ-GASV-008, REQ-GASV-009
    event SignerConfigChanged(
        address indexed signer, address indexed by, uint256 minBalance, uint256 targetBalance, uint256 periodCap
    );

    /// @notice A signer was removed from the allowlist.
    /// @param signer The signer.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    /// @custom:spec REQ-GASV-010
    event SignerRemoved(address indexed signer, address indexed by);

    /// @notice Top-ups were paused or unpaused.
    /// @param paused The new state.
    /// @param by `TIMELOCK` or `GUARDIAN`.
    /// @custom:spec REQ-GASV-011
    event PauseChanged(bool paused, address indexed by);

    /// @notice ETH was withdrawn to `TREASURY`.
    /// @param amount The amount.
    /// @custom:spec REQ-GASV-012
    event Withdrawn(uint256 amount);
}
