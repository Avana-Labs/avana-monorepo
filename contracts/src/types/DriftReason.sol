// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Reason codes of the RiskModule's Aave configuration drift check.
/// @dev Checked on the standard Aave V4 Spoke of every CDP Spoke; drift trips a breaker that stops new activity, never
/// liquidation. `None` means no drift. Spoke-wide and debt-reserve reasons are reported with `marketId = 0`. Append only:
/// existing ordinal values never change. The three standard-Spoke settings the listing sets and the drift check
/// enforces are `ReceiveSharesOn`, `LiquidationFeeNonZero` and `ReinvestmentController`.
/// @custom:spec REQ-ADAPTER-014, REQ-ADAPTER-022, REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-ADAPTER-031, REQ-ADAPTER-032, REQ-ADAPTER-033, REQ-ADAPTER-034, REQ-ADAPTER-035, REQ-ADAPTER-063, REQ-ADAPTER-064, REQ-RISK-063, REQ-RISK-069, Q-270, Q-281, Q-378
enum DriftReason {
    None,
    // A debt reserve of the account is not a debt reserve the MarketRegistry enabled for the Spoke.
    BorrowedUnapprovedReserve,
    // An approved debt reserve's Aave reserve does not match its recorded definition.
    DebtReserveMismatch,
    ReserveIdentity,
    // Standard-Spoke setting 1 of 3: a market's collateral reserve has receiveSharesEnabled true.
    ReceiveSharesOn,
    Borrowable,
    // Standard-Spoke setting 2 of 3: a collateral reserve's liquidationFee is above 0 and not paid to Avana's fee
    // receiver.
    LiquidationFeeNonZero,
    ExtraSpoke,
    DrawCapNonZero,
    DrawnSharesNonZero,
    FeeReceiverAddCap,
    // Standard-Spoke setting 3 of 3: a collateral reserve has a reinvestment controller.
    ReinvestmentController,
    PriceSource,
    CollateralRiskAboveThreshold,
    // The implementation behind the Spoke proxy is not the approved one, by address and code hash
    // (MarketRegistry.spokeImplementationStatus reports current = false; REQ-ADAPTER-063).
    SpokeImplementation,
    // The CDP Spoke's Hub differs from its recorded home Hub (IMarketRegistryHubs.spokeSettingsDrift).
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
    // The home Hub reports the CDP Spoke inactive or halted, or an Avana reserve of it is paused (REQ-RISK-088, Q-351).
    SpokeHalted,
    // Reserved: no drift view returns it. That no proxy has an approved position manager is shown by construction
    // (REQ-RISK-088, Q-352); the value is removed once the AaveAdapter's tests and formal rule complete the proof.
    PositionManagerApproved
}
