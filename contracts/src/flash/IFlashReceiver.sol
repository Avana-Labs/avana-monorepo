// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFlashReceiver
/// @notice Callback through which the chain's flash source hands a flash loan of the debt asset to LPVaultSwap.
/// @dev Implemented by LPVaultSwap. Called only by `MarketRegistry.flashSource()` inside `IFlashSource.flashLoan`, after `amount` of
/// `asset` was transferred to LPVaultSwap. LPVaultSwap measures the principal it received as its balance delta `Fr`
/// (less than `amount` only if the asset charges a transfer fee). Before returning it repays by balance delta
/// (REQ-SWAP-122): with `owed = amount + premium`, at most `MAX_REPAY_TRANSFERS` (4) times it reads `b =
/// asset.balanceOf(flashSource)`, stops if `b >= owed`, else transfers `owed - b`; it then reverts
/// `FlashRepayShort(b, owed)` unless the source holds at least `owed`. Without a transfer fee this is one transfer of
/// `amount + premium`; with USDT's fee (at most 19 bps and 50 USDT per transfer) four transfers always suffice, though on
/// Aave V4 a fee on the debt asset stops `deleverage` at Aave's repayment first (REQ-SWAP-123).
/// @custom:spec REQ-FLASH-004, Q-373
interface IFlashReceiver {
    /// @notice Runs the liquidation funded by the flash loan and repays `amount + premium` to the flash source.
    /// @dev LPVaultSwap checks `msg.sender == FLASH_SOURCE`, that `context` equals the hash of its own active
    /// transient liquidation context, and that `asset` is the debt asset of that context; otherwise it reverts.
    /// @param asset Debt asset lent.
    /// @param amount Amount lent, base units of `asset`.
    /// @param premium Premium owed on top of `amount`.
    /// @param context Opaque context LPVaultSwap passed to `flashLoan`.
    /// @return magic `keccak256("IFlashReceiver.onFlashLoan")`.
    /// @custom:spec REQ-FLASH-004
    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata context
    ) external returns (bytes32 magic);
}
