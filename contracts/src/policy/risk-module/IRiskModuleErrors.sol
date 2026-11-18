// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/MarketTypes.sol";
import {PriceState} from "../../types/OracleTypes.sol";

/// @title IRiskModuleErrors
/// @notice Errors of the RiskModule's pledge check and borrow-side checks.
interface IRiskModuleErrors {
    /// @notice The market is not Active in the MarketRegistry.
    error MarketNotActive(uint256 marketId);

    /// @notice The market is Offboarding: no pledge into it and no borrow against it.
    error MarketOffboarding(uint256 marketId);

    /// @notice The market's AMM integration does not report the depositor as the position's owner (preview reason).
    error NotPositionOwner();

    /// @notice The position's pool is not the market's pool, or it comes from a non-canonical position manager.
    error PoolMismatch();

    /// @notice The position's shape (for concentrated liquidity, its tick range) is not exactly the market's.
    error ShapeMismatch();

    /// @notice The position's liquidity is 0.
    error ZeroLiquidity();

    /// @notice The pledged market's price state is not accepted for this pledge class.
    error PriceNotAccepted(uint8 state);

    /// @notice A pledge cap test failed.
    error CapExceeded(bytes32 capKind);

    /// @notice The pledge needs the top-up slice but is not eligible for it, or exceeds the restore amount.
    error SliceNotAvailable();

    /// @notice The pledge's value at the served price is below the minimum that applies to it.
    /// @param pledgeUsd The pledge's value, rounded down, 8-decimal USD.
    /// @param minPledgeUsd The minimum that applies, 8-decimal USD.
    error BelowMinPledge(uint256 pledgeUsd, uint256 minPledgeUsd);

    /// @notice Liquidation is halted for the account's collateral market: 0 active approved keepers on the chain.
    error LiquidationHalted(uint256 marketId);

    /// @notice A pool token of the account's market has no usable swap route into this debt reserve's asset.
    error DebtLiquidationHalted(uint256 debtReserveId);

    /// @notice The Spoke is not approved in the MarketRegistry.
    error UnknownSpoke(address spoke);

    /// @notice A collateral reserve of the account maps to no Active or Offboarding market on the Spoke.
    error UnknownCollateral(uint256 reserveId);

    /// @notice An Aave configuration drift check failed.
    /// @param marketId Market identifier, or 0 for a Spoke-wide reason.
    error ConfigDrift(uint256 marketId, DriftReason reason);

    /// @notice A collateral market of the account is not Live.
    error PriceNotLive(uint256 marketId, PriceState state);

    /// @notice A Chainlink input of a collateral market's price is in the future or older than `borrowPriceMaxAge`.
    /// @param age `block.timestamp - updatedAt` of the source round, seconds.
    error PriceTooOld(address feed, uint256 age);

    /// @notice A debt reserve's DebtOracle is not Live, or its served price is in the future or too old.
    /// @param age `block.timestamp - servedUpdatedAt`, seconds.
    error DebtPriceTooOld(uint256 debtReserveId, address source, uint256 age);

    /// @notice A debt reserve's Aave price source differs from the recorded one.
    error UnexpectedDebtPriceSource(uint256 debtReserveId, address source);

    /// @notice Hub added shares differ from added assets for the market's vault-token asset.
    error HubSharesNotEqualAssets(uint256 marketId);

    /// @notice The health factor after the Spoke call is below the required minimum.
    /// @param required `max(1e18, minHealthFactor)`, WAD.
    error HealthFactorTooLow(uint256 healthFactor, uint256 required);

    /// @notice A live condition of a market's circuit breaker holds (new activity on that market, or by an account
    /// holding it); the check passes again as soon as the condition clears.
    error BreakerTripped(uint256 marketId, uint32 reasons);

    /// @notice A live condition of the debt circuit breaker of `(spoke, debtReserveId)` holds.
    error DebtBreakerTripped(address spoke, uint256 debtReserveId, uint32 reasons);

    /// @notice A pledge needed the rescue exemption but is not a rescue top-up.
    /// @param healthFactor The account's health factor before the pledge, WAD (`type(uint256).max` with no debt).
    /// @param usdCharge The pledge's booked charge, 8-decimal USD.
    /// @param restoreBooked The restore amount on the booking basis, 8-decimal USD.
    error NotRescueTopUp(uint256 healthFactor, uint256 usdCharge, uint256 restoreBooked);

    /// @notice The record left by a partial removal with debt is worth less than `minPledgeUsd`.
    /// @param remainingUsd Value of the remaining units at the accepted price, 8-decimal USD.
    error RecordBelowMinPledge(uint256 remainingUsd, uint256 minPledgeUsd);

    /// @notice The account already holds the maximum number of open records in its market.
    error TooManyRecords(uint256 records);

    /// @notice The AMM integration named by the caller is not the market's integration.
    error IntegrationMismatch(uint256 marketId, uint32 integrationId);

    /// @notice `gasleft()` is below the gas a gas-limited external call requires.
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice A logic contract given to the implementation constructor reports another kind or other immutables.
    error InvalidLogic(address logic);

    /// @notice A borrow would take the market's debt above the cap fixed for the running interval.
    /// @param cap The interval's cap, 8-decimal USD.
    /// @param newDebt The market's debt after the borrow, 8-decimal USD.
    error DynamicBorrowCapExceeded(uint256 marketId, uint256 cap, uint256 newDebt);
}
