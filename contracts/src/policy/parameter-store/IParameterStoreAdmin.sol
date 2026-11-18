// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SecondSource} from "../../types/SecondSource.sol";
import {GlobalParams} from "./types/GlobalParams.sol";

/// @title IParameterStoreAdmin
/// @notice Initialization and the structural setters of the ParameterStore, which move a value in either direction.
/// @dev Setters take the timelock's normal delay unless noted.
interface IParameterStoreAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Grants the admin roles to `timelock`; reverts `AdminRoleOnlyTimelock` unless `timelock == TIMELOCK`.
    /// @param initialPoolShareMaxBps Initial maximum Avana share of pool liquidity, bps.
    function initialize(
        address timelock,
        GlobalParams calldata params,
        uint16 initialPoolShareMaxBps
    ) external;

    /// @notice Sets a feed's `borrowPriceMaxAge` in either direction.
    /// @dev Reverts `OutOfBounds` unless `0 < value <= feedMaxAge`.
    /// @param value New age limit, seconds.
    function setBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a market's `consistencyToleranceBps` in either direction.
    /// @dev Reverts `LivenessBound` below `consistencyToleranceMinBps`.
    /// @param value New tolerance, bps of the fair price.
    function setConsistencyToleranceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets a token's `feedAgreementToleranceBps` in either direction.
    /// @dev Never below `feedAgreementToleranceMinBps(token)`.
    function setFeedAgreementToleranceBps(
        address token,
        uint16 value
    ) external;

    /// @notice Sets a market's `poolRiskFactor` in either direction.
    /// @param value New factor, bps.
    function setPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets `avanaFeeShareBps` in either direction.
    /// @dev Also callable by `APPLICATION_RISK_STEWARD`; a rise reverts `OutOfBounds` unless the fee bound holds.
    function setAvanaFeeShareBps(
        uint16 value
    ) external;

    /// @notice Sets `feeRecipient`.
    /// @dev Reverts `InvalidFeeRecipient` for the zero address, an Avana contract, a Hub, a Spoke or a PositionProxy.
    function setFeeRecipient(
        address recipient
    ) external;

    /// @notice Sets `maxFlashFeeBps`.
    /// @dev A raise reverts `LivenessBound` unless liquidation liveness holds for every live market.
    function setMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Lowers `maxFlashFeeBps` (short delay, or at once by `APPLICATION_RISK_STEWARD`).
    /// @dev A lower ceiling can move liquidations to the caller-funded path, never stop them.
    function tightenMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Sets a token's second price source for borrow and withdraw-with-debt, and its standby.
    /// @dev The standby may be empty; it reverts `OutOfBounds` when it shares a feed or pool with `src` or the routes.
    /// @param standby The standby either guardian can put in force with `useStandbySecondSource`.
    function setSecondSource(
        address token,
        SecondSource calldata src,
        SecondSource calldata standby
    ) external;

    /// @notice Puts the token's standby second source in force at once.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` only, the one function outside `APPLICATION_ADMIN`.
    function useStandbySecondSource(
        address token
    ) external;

    /// @notice Returns the token to its recorded second source.
    /// @dev Timelock only, so a guardian cannot switch back to a source that failed. No-op when not on standby.
    function restoreSecondSource(
        address token
    ) external;

    /// @notice Sets `cachedWindow`.
    /// @param value New window, seconds.
    function setCachedWindow(
        uint32 value
    ) external;

    /// @notice Sets `disagreementPauseMax`.
    /// @dev Reverts `LivenessBound` above its bound.
    /// @param value New maximum, seconds.
    function setDisagreementPauseMax(
        uint32 value
    ) external;

    /// @notice Sets a market's `twapWindow` (a change to price computation).
    /// @dev Requires the pool's time-weighted read over the new window to succeed.
    /// @param value New window, seconds.
    function setTwapWindow(
        uint256 marketId,
        uint32 value
    ) external;

    /// @notice Sets the USD band.
    /// @dev Requires `low < 1e8 < high`.
    /// @param low Lower level, 8 decimals per 1 USD at peg.
    /// @param high Upper level, 8 decimals per 1 USD at peg.
    function setUsdBand(
        uint256 low,
        uint256 high
    ) external;

    /// @notice Sets a feed's `liquidationPriceMaxAge`.
    /// @dev Reverts `LivenessBound` below the feed's `feedHeartbeat`.
    /// @param value New age limit, seconds.
    function setLiquidationPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a feed's `feedMaxAge`, the maximum age of a valid answer in LPOracle state evaluation.
    /// @dev Reverts `OutOfBounds` unless `value == feedHeartbeat + heartbeatMargin`.
    /// @param value New maximum age, seconds.
    function setFeedMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets `graceDuration`.
    /// @dev At most `graceDurationMax`.
    /// @param value New duration, seconds.
    function setGraceDuration(
        uint32 value
    ) external;

    /// @notice Sets `graceHealthFactor`.
    /// @dev `graceHealthFactorMin <= value < 1e18`.
    /// @param value New health factor, WAD.
    function setGraceHealthFactor(
        uint256 value
    ) external;

    /// @notice Sets `feedAgreementMarginBps`.
    /// @dev Every token's tolerance must stay at or above its lower bound.
    function setFeedAgreementMarginBps(
        uint16 value
    ) external;

    /// @notice Sets a market's `slippageAllowanceMinBps`.
    /// @dev A raise on a live market reverts `LivenessBound` unless liquidation liveness still holds.
    function setSlippageAllowanceMinBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets a token's collateral-factor input (`tokenCollateralFactorBps`).
    function setTokenCollateralFactorBps(
        address token,
        uint16 value
    ) external;

    /// @notice Changes a market's stress floor.
    /// @dev Raising reverts `SupplyNotZero` unless the market's vault-token supply is 0.
    /// @param value New floor, 8-decimal USD per whole vault token.
    function setStressFloorUsd(
        uint256 marketId,
        uint256 value
    ) external;
}
