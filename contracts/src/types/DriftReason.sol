// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Reason codes of the RiskModule's Aave configuration drift check.
/// @dev Append only: existing ordinal values never change.
enum DriftReason {
    None,
    // A debt reserve of the account is not a debt reserve the MarketRegistry enabled for the Spoke.
    BorrowedUnapprovedReserve,
    // An approved debt reserve's Aave reserve does not match its recorded definition.
    DebtReserveMismatch,
    ReserveIdentity,
    // A market's collateral reserve has receiveSharesEnabled true.
    ReceiveSharesOn,
    Borrowable,
    // A collateral reserve's liquidationFee is above 0 (a fee pays Hub shares with no token transfer).
    LiquidationFeeNonZero,
    ExtraSpoke,
    DrawCapNonZero,
    DrawnSharesNonZero,
    FeeReceiverAddCap,
    // A collateral reserve has a reinvestment controller.
    ReinvestmentController,
    PriceSource,
    CollateralRiskAboveThreshold,
    // The implementation behind the Spoke proxy is not the approved one, by address and code hash.
    SpokeImplementation,
    // The CDP Spoke's Hub differs from its recorded home Hub.
    HomeHubMismatch,
    // A reserve of the Spoke is borrowable without being a debt reserve the MarketRegistry enabled.
    DebtReserveSet,
    // An approved debt reserve's Aave price source differs from the recorded one.
    DebtPriceSource,
    // A dynamic configuration key's collateral factor is above expectedCollateralFactorBps(m).
    CollateralFactorAboveExpected,
    // ceil(maxLiquidationBonus * CF / 1e4) >= 1e4, or the minimum bonus is below minLiquidationBonus.
    BonusBoundViolated,
    // The Spoke's liquidation target health factor differs from aaveTargetHealthFactor.
    LiquidationConfigChanged,
    // The home Hub reports the CDP Spoke inactive or halted, or an Avana reserve of it is paused.
    SpokeHalted
}
