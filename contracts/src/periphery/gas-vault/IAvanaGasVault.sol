// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaGasVaultErrors} from "./IAvanaGasVaultErrors.sol";
import {IAvanaGasVaultEvents} from "./IAvanaGasVaultEvents.sol";

/// @title IAvanaGasVault
/// @notice One vault per chain holding that chain's native gas token for Avana's own keeper signers (2.23). Anyone can
/// trigger a top-up, which pays only an allowlisted signer, only while it is below its `minBalance`, and at most
/// `min(targetBalance − balance, periodCap − sent in the last 24 h, vault balance)`. `TIMELOCK` adds signers, raises
/// values, unpauses and withdraws to `TREASURY`; `GUARDIAN` (or `TIMELOCK`) removes a signer, lowers values and pauses
/// at once.
/// @dev Periphery outside the audited core: immutable, no owner, no role storage, no upgrade; it holds no ERC-20,
/// reads neither `tx.gasprice` nor `gasleft()`, and calls no Avana contract; no Avana contract calls or reads it. Any
/// number of chains and Hubs share the design: one vault per chain serves every Hub on it.
/// @custom:spec REQ-GASV-001, REQ-GASV-014
interface IAvanaGasVault is IAvanaGasVaultErrors, IAvanaGasVaultEvents {
    /// @notice A signer's refill rule. Values fit 80 bits (about 1.2 million ETH).
    /// @param minBalance A top-up is allowed only while the signer's balance is below this.
    /// @param targetBalance A top-up fills the signer to this, at most.
    /// @param periodCap Most ETH sent to the signer in any 24 h.
    struct SignerConfig {
        uint80 minBalance;
        uint80 targetBalance;
        uint80 periodCap;
    }

    // ─── Immutables and constants ───

    /// @notice The only withdrawal destination: the chain's `feeRecipient` treasury Safe (never `FUNDING_SAFE`).
    /// @custom:spec REQ-GASV-002, REQ-GASV-012
    function TREASURY() external view returns (address);

    /// @notice The chain's AvanaTimelock.
    /// @custom:spec REQ-GASV-002
    function TIMELOCK() external view returns (address);

    /// @notice The chain's Emergency Guardian Safe: removes, lowers and pauses at once; cannot raise or withdraw.
    /// @custom:spec REQ-GASV-002
    function GUARDIAN() external view returns (address);

    /// @notice Most signers on the allowlist, `1 ≤ MAX_SIGNERS ≤ MAX_SIGNERS_LIMIT`.
    /// @custom:spec REQ-GASV-002, REQ-GASV-007
    function MAX_SIGNERS() external view returns (uint256);

    /// @notice Hard bound on `MAX_SIGNERS`: 8, which bounds `topUpAll`'s gas.
    /// @custom:spec REQ-GASV-002
    function MAX_SIGNERS_LIMIT() external view returns (uint256);

    /// @notice The rolling window of the cap: 86,400 s.
    /// @custom:spec REQ-GASV-005
    function PERIOD() external view returns (uint256);

    /// @notice Most top-ups recorded per signer in any `PERIOD`: 4.
    /// @custom:spec REQ-GASV-005
    function MAX_SENDS_PER_PERIOD() external view returns (uint256);

    // ─── Anyone ───

    /// @notice Adds ETH to the vault (as does a plain transfer).
    /// @custom:spec REQ-GASV-003
    function fund() external payable;

    /// @notice Tops `signer` up toward its `targetBalance`; pays `signer`, never the caller.
    /// @dev Reverts `VaultPaused` while paused, `UnknownSigner` if not listed, `NotBelowMinimum` unless
    /// `signer.balance < minBalance`, `NothingToSend` if the amount is 0, `SendFailed` if the transfer fails.
    /// @param signer An allowlisted signer.
    /// @return amount The ETH sent.
    /// @custom:spec REQ-GASV-004, REQ-GASV-005, REQ-GASV-013
    function topUp(
        address signer
    ) external returns (uint256 amount);

    /// @notice Tops up every listed signer below its `minBalance` with a non-zero amount; skips the rest and any signer
    /// whose transfer fails (`TopUpFailed`). Reverts only `VaultPaused`.
    /// @return count Signers paid.
    /// @return total ETH sent.
    /// @custom:spec REQ-GASV-006, REQ-GASV-013
    function topUpAll() external returns (uint256 count, uint256 total);

    // ─── TIMELOCK ───

    /// @notice Adds an Avana keeper signer (D7: Avana's own signers only, primary and standby per chain).
    /// @custom:spec REQ-GASV-007
    function addSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Sets a listed signer's three values, in either direction.
    /// @custom:spec REQ-GASV-008
    function setSignerConfig(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Unpauses top-ups.
    /// @custom:spec REQ-GASV-011
    function unpause() external;

    /// @notice Sends `amount` to `TREASURY`.
    /// @custom:spec REQ-GASV-012, REQ-GASV-013
    function withdraw(
        uint256 amount
    ) external;

    // ─── GUARDIAN or TIMELOCK ───

    /// @notice Lowers a listed signer's values; each new value must be at most the current one.
    /// @custom:spec REQ-GASV-009
    function tightenSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Removes a listed signer; it receives nothing afterwards.
    /// @custom:spec REQ-GASV-010
    function removeSigner(
        address signer
    ) external;

    /// @notice Pauses top-ups (funding and withdrawal stay open).
    /// @custom:spec REQ-GASV-011
    function pause() external;

    // ─── Views ───

    /// @notice Whether top-ups are paused.
    /// @custom:spec REQ-GASV-014
    function paused() external view returns (bool);

    /// @notice The allowlist, in storage order.
    /// @custom:spec REQ-GASV-014
    function signers() external view returns (address[] memory);

    /// @notice Whether `account` is listed.
    /// @custom:spec REQ-GASV-014
    function isSigner(
        address account
    ) external view returns (bool);

    /// @notice A listed signer's values (zeros if not listed).
    /// @custom:spec REQ-GASV-014
    function signerConfig(
        address signer
    ) external view returns (SignerConfig memory);

    /// @notice ETH sent to `signer` in the last `PERIOD` (`(now − PERIOD, now]`).
    /// @custom:spec REQ-GASV-005, REQ-GASV-014
    function sentInPeriod(
        address signer
    ) external view returns (uint256);

    /// @notice What `topUp(signer)` would send now and what it would request; `(0, 0)` when not due or not listed, and
    /// an amount of 0 while paused.
    /// @custom:spec REQ-GASV-014
    function quoteTopUp(
        address signer
    ) external view returns (uint256 amount, uint256 requested);
}
