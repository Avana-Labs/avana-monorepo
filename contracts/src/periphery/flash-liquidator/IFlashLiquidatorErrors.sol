// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFlashLiquidatorErrors
/// @notice Errors of the flash liquidation helper. Every amount is in base units of the debt asset. Each one reverts the
/// whole transaction, including the liquidation inside the callback.
interface IFlashLiquidatorErrors {
    /// @notice A constructor address is `address(0)` (the GHO flash minter may be `address(0)`, but a set minter must
    /// name a GHO token).
    /// @custom:spec REQ-HELPER-001
    error ZeroAddress();

    /// @notice The operator variant's `MAX_TOP_UP_BPS` exceeds 10^4.
    /// @param bps The rejected value.
    /// @custom:spec REQ-HELPER-001
    error InvalidTopUpBps(uint256 bps);

    /// @notice A lender (the Pool, or the GHO flash minter) is a Hub recorded on the chain (`MarketRegistry.isRecordedHub`),
    /// at deployment or, for the lender of the call's asset, at a call.
    /// @custom:spec REQ-HELPER-002, REQ-HELPER-013
    error FlashSourceIsHub();

    /// @notice `flashLiquidate` was called while a context of this helper is open (nesting or reentry).
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-013
    error ContextActive();

    /// @notice The operator variant was called by an address other than `SIGNER`.
    /// @custom:spec REQ-HELPER-011, REQ-HELPER-013
    error NotSigner();

    /// @notice The flash amount is above `params.debtToCover`, or 0 on the public helper (the operator variant accepts
    /// 0), or `params.debtToCover` or `params.maxShortfall` is
    /// above `2^128 - 1` (LPVaultSwap's own bound, REQ-SWAP-005).
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-013
    error InvalidFlashAmount();

    /// @notice The Pool cannot lend the flash amount now (`maxFlashLoan` below it).
    /// @param available `maxFlashLoan(asset)`.
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-009
    error InsufficientFlashLiquidity(uint256 available);

    /// @notice The callback came from an address other than the context's lender, through the other lender's callback,
    /// with a foreign initiator, more than one asset, an asset, amount or data hash other than the context's, no active
    /// context or a used context; or the lender returned without running it.
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-005, REQ-HELPER-013
    error InvalidFlashCallback();

    /// @notice The premium the Pool charges exceeds the caller's `maxPremium`.
    /// @param premium The charged premium.
    /// @param maxPremium The caller's bound.
    /// @custom:spec REQ-HELPER-005
    error PremiumTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The premium fails the exact check `premium * 1e4 <= maxFlashFeeBps * amount` (SPEC-LIQ-015).
    /// @param premium The charged premium.
    /// @param maxPremium `floor(maxFlashFeeBps * amount / 1e4)`.
    /// @custom:spec REQ-HELPER-005, SPEC-LIQ-015
    error FlashFeeTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The top-up needed to repay `F + premium` exceeds its bound (`maxTopUp`, and in the operator variant also
    /// `floor(D * MAX_TOP_UP_BPS / 1e4)` with `D` the debt LPVaultSwap repaid in the call).
    /// @param topUp `F + premium - keeperOut - unused shortfall budget`.
    /// @param bound The bound that applied.
    /// @custom:spec REQ-HELPER-007, REQ-SWAP-081
    error TopUpExceeded(uint256 topUp, uint256 bound);

    /// @notice The operator variant's loan exceeds what the liquidation needed: `F > ceil(D * (1e4 +
    /// LENS_DUST_MARGIN_BPS) / 1e4)`, with `D` the debt LPVaultSwap repaid in the call.
    /// @param flashAmount `F`.
    /// @param need `ceil(D * (1e4 + LENS_DUST_MARGIN_BPS) / 1e4)`.
    /// @custom:spec REQ-HELPER-011, REQ-HELPER-016
    error FlashAmountAboveNeed(uint256 flashAmount, uint256 need);

    /// @notice The operator variant's Safe would end the call with less debt asset than it started: what left it
    /// (inventory, shortfall budget and top-up) less the payout exceeds `floor(D * MAX_TOP_UP_BPS / 1e4)`, with `D` the
    /// debt LPVaultSwap repaid in the call.
    /// @param outlay What the Safe would lose net.
    /// @param bound `floor(D * MAX_TOP_UP_BPS / 1e4)`.
    /// @custom:spec REQ-HELPER-011, REQ-HELPER-016
    error OutlayExceeded(uint256 outlay, uint256 bound);

    /// @notice The public helper's `claimEscrowed` found `feeRecipient` unset in the ParameterStore.
    /// @custom:spec REQ-HELPER-010
    error InvalidFeeRecipient();

    /// @notice The net payout after repaying the loan and its premium is below the request's `minPayout`.
    /// @param payout The net payout.
    /// @param minPayout The caller's minimum.
    /// @custom:spec REQ-HELPER-008, REQ-HELPER-014, Q-345
    error PayoutTooLow(uint256 payout, uint256 minPayout);
}
