// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaGasVaultErrors} from "./IAvanaGasVaultErrors.sol";
import {IAvanaGasVaultEvents} from "./IAvanaGasVaultEvents.sol";

/// @title IAvanaGasVault
/// @notice Per-chain vault of native gas for Avana's keeper signers; anyone may top up a signer below its minimum.
/// @dev `TIMELOCK` raises and withdraws; `GUARDIAN` (or `TIMELOCK`) removes, lowers and pauses.
interface IAvanaGasVault is IAvanaGasVaultErrors, IAvanaGasVaultEvents {
    /// @notice A signer's refill rule: top up below `minBalance`, to `targetBalance`, at most `periodCap` per `PERIOD`.
    struct SignerConfig {
        uint80 minBalance;
        uint80 targetBalance;
        uint80 periodCap;
    }

    /// @notice The only withdrawal destination: the chain's `feeRecipient` treasury Safe.
    function TREASURY() external view returns (address);

    /// @notice The chain's AvanaTimelock.
    function TIMELOCK() external view returns (address);

    /// @notice The chain's Emergency Guardian Safe: removes, lowers and pauses at once; cannot raise or withdraw.
    function GUARDIAN() external view returns (address);

    /// @notice Most signers on the allowlist, `1 ≤ MAX_SIGNERS ≤ MAX_SIGNERS_LIMIT`.
    function MAX_SIGNERS() external view returns (uint256);

    /// @notice Hard bound on `MAX_SIGNERS`, which bounds `topUpAll`'s gas.
    function MAX_SIGNERS_LIMIT() external view returns (uint256);

    /// @notice The rolling window of the cap.
    function PERIOD() external view returns (uint256);

    /// @notice Most top-ups recorded per signer in any `PERIOD`.
    function MAX_SENDS_PER_PERIOD() external view returns (uint256);

    /// @notice Most gas forwarded with each ETH transfer; bounds what a recipient's code can burn.
    function TRANSFER_GAS() external view returns (uint256);

    /// @notice Accepts ETH from anyone, as `fund` does.
    receive() external payable;

    /// @notice Adds ETH to the vault (as does a plain transfer).
    function fund() external payable;

    /// @notice Tops `signer` up toward its `targetBalance`; pays `signer`, never the caller.
    /// @dev Reverts `NotBelowMinimum` unless `signer.balance < minBalance`.
    function topUp(
        address signer
    ) external returns (uint256 amount);

    /// @notice Tops up every listed signer below its minimum, skipping failed transfers; reverts only `VaultPaused`.
    function topUpAll() external returns (uint256 count, uint256 total);

    /// @notice Adds an Avana keeper signer.
    function addSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Sets a listed signer's three values, in either direction.
    function setSignerConfig(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Unpauses top-ups.
    function unpause() external;

    /// @notice Sends `amount` to `TREASURY`.
    function withdraw(
        uint256 amount
    ) external;

    /// @notice Lowers a listed signer's values; each new value must be at most the current one.
    function tightenSigner(
        address signer,
        uint256 minBalance,
        uint256 targetBalance,
        uint256 periodCap
    ) external;

    /// @notice Removes a listed signer; it receives nothing afterwards.
    function removeSigner(
        address signer
    ) external;

    /// @notice Pauses top-ups (funding and withdrawal stay open).
    function pause() external;

    /// @notice Whether top-ups are paused.
    function paused() external view returns (bool);

    /// @notice The allowlist, in storage order.
    function signers() external view returns (address[] memory);

    /// @notice Whether `account` is listed.
    function isSigner(
        address account
    ) external view returns (bool);

    /// @notice A listed signer's values (zeros if not listed).
    function signerConfig(
        address signer
    ) external view returns (SignerConfig memory);

    /// @notice ETH sent to `signer` in the last `PERIOD`.
    function sentInPeriod(
        address signer
    ) external view returns (uint256);

    /// @notice What `topUp(signer)` would send and request now; `(0, 0)` if not due or listed, amount 0 while paused.
    function quoteTopUp(
        address signer
    ) external view returns (uint256 amount, uint256 requested);
}
