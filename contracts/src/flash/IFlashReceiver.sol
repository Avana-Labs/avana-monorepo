// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFlashReceiver
/// @notice Callback through which the chain's flash source hands a flash loan of the debt asset to LPVaultSwap.
/// @dev Implemented by LPVaultSwap; called only by the chain's flash source.
interface IFlashReceiver {
    /// @notice Runs the liquidation funded by the flash loan and repays `amount + premium` to the flash source.
    /// @dev Reverts unless the caller is the flash source and `context` and `asset` match LPVaultSwap's active context.
    /// @return magic `keccak256("IFlashReceiver.onFlashLoan")`.
    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata context
    ) external returns (bytes32 magic);
}
