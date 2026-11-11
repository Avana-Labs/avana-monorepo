// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFlashLiquidatorEvents
/// @notice Events of the flash liquidation helper.
interface IFlashLiquidatorEvents {
    /// @notice Emitted after `flashLoan` returns and the payout is sent.
    /// @param caller `msg.sender` of `flashLiquidate` (the operator's signer for the operator variant).
    /// @param recipient The payout recipient (the caller for the public helper, `FUNDING_SAFE` for the operator variant).
    /// @param asset The debt asset borrowed and repaid.
    /// @param flashAmount `F`.
    /// @param premium The premium the Pool charged.
    /// @param keeperOut What LPVaultSwap paid the helper.
    /// @param topUp What the helper pulled from its payer to repay the Pool (0 when none).
    /// @param payout The net payout sent to the recipient.
    /// @custom:spec REQ-HELPER-008
    event FlashLiquidated(
        address indexed caller,
        address indexed recipient,
        address indexed asset,
        uint256 flashAmount,
        uint256 premium,
        uint256 keeperOut,
        uint256 topUp,
        uint256 payout
    );
}
