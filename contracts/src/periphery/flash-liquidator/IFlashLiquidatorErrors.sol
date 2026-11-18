// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFlashLiquidatorErrors
/// @notice Errors of the flash liquidation helper. Amounts are in base units of the debt asset.
interface IFlashLiquidatorErrors {
    /// @notice A constructor address is `address(0)`.
    error ZeroAddress();

    /// @notice The operator variant's `MAX_TOP_UP_BPS` exceeds 10^4.
    error InvalidTopUpBps(uint256 bps);

    /// @notice The Pool is a Hub recorded on the chain.
    error FlashSourceIsHub();

    /// @notice A context of this helper is already open (nesting or reentry).
    error ContextActive();

    /// @notice The operator variant was called by an address other than `SIGNER`.
    error NotSigner();

    /// @notice The flash amount or the request's bounds are out of range.
    error InvalidFlashAmount();

    /// @notice The Pool cannot lend the flash amount now.
    /// @param available `maxFlashLoan(asset)`.
    error InsufficientFlashLiquidity(uint256 available);

    /// @notice The callback does not match the open context, or the Pool returned without running it.
    error InvalidFlashCallback();

    /// @notice The premium the Pool charges exceeds the caller's `maxPremium`.
    error PremiumTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The premium exceeds `maxFlashFeeBps` of the amount.
    /// @param maxPremium `floor(maxFlashFeeBps * amount / 1e4)`.
    error FlashFeeTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The top-up needed to repay `F + premium` exceeds its bound.
    error TopUpExceeded(uint256 topUp, uint256 bound);

    /// @notice The operator variant's loan exceeds what the liquidation needed.
    /// @param need The largest loan allowed.
    error FlashAmountAboveNeed(uint256 flashAmount, uint256 need);

    /// @notice The operator variant's Safe would lose more than `MAX_TOP_UP_BPS` of the debt repaid.
    /// @param outlay What the Safe would lose net.
    /// @param bound `floor(D * MAX_TOP_UP_BPS / 1e4)`.
    error OutlayExceeded(uint256 outlay, uint256 bound);

    /// @notice The public helper's `claimEscrowed` found `feeRecipient` unset in the ParameterStore.
    error InvalidFeeRecipient();

    /// @notice The net payout is below the request's `minPayout`.
    error PayoutTooLow(uint256 payout, uint256 minPayout);
}
