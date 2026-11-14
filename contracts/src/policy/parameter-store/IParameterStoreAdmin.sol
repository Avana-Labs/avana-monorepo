// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SecondSource} from "../../types/SecondSource.sol";
import {GlobalParams} from "./types/GlobalParams.sol";

/// @title IParameterStoreAdmin
/// @notice Initialization and the structural setters of the ParameterStore, which may move a value in either
/// direction.
/// @dev Every setter requires `APPLICATION_ADMIN` and runs through the timelock at the normal delay; any canceller can
/// cancel a queued call. `tightenMaxFlashFeeBps` takes the short delay, and it and `setAvanaFeeShareBps` also accept
/// `APPLICATION_RISK_STEWARD` (the Joint Configuration Safe) at once; `useStandbySecondSource` is the pause guardian's. `setUsdBand`, `setGraceDuration` and `setGraceHealthFactor` change only here, in either
/// direction; they have no tighten setter. Each emits `ParameterSet` (or `FeedConfigured`, `StressFloorSet`) and reverts
/// `OutOfBounds` or `LivenessBound` outside its bounds.
interface IParameterStoreAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, atomically with the proxy deployment; grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to
    /// `timelock` only, reverting `AdminRoleOnlyTimelock` unless `timelock == TIMELOCK`; every value within its hard
    /// bounds, `gateRecoverySeconds` within [600, 7,200] included.
    /// @param timelock The Avana timelock.
    /// @param params Initial global parameters, including the breaker thresholds and `maxShortfallBps`.
    /// @param initialDepositorUsdCap Initial exposure cap per depositor wallet, 8-decimal USD.
    /// @param initialPoolShareMaxBps Initial maximum Avana share of pool liquidity, bps.
    /// @custom:spec REQ-PSTORE-001, REQ-CONFIG-050, REQ-PSTORE-016, REQ-PSTORE-018, REQ-PSTORE-019, Q-259
    function initialize(
        address timelock,
        GlobalParams calldata params,
        uint256 initialDepositorUsdCap,
        uint16 initialPoolShareMaxBps
    ) external;

    /// @notice Sets a feed's `borrowPriceMaxAge` in either direction.
    /// @dev Normal delay; `0 < value <= feedHeartbeat + heartbeatMargin`, the feed's `feedMaxAge` (`OutOfBounds`).
    /// @param feed Chainlink aggregator proxy.
    /// @param value New age limit, seconds.
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-049, REQ-CONFIG-054, REQ-PSTORE-009, SPEC-ORC-019, Q-322
    function setBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a market's `consistencyToleranceBps` in either direction.
    /// @dev Normal delay; reverts `LivenessBound` below `consistencyToleranceMinBps`. For concentrated liquidity the
    /// value equals the tick tolerance it replaces: 50 bps is about 50 ticks (one tick is a ratio of 1.0001).
    /// @param marketId Market identifier.
    /// @param value New tolerance, bps of the fair price.
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-052, REQ-CONFIG-054
    function setConsistencyToleranceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets a token's `feedAgreementToleranceBps` in either direction.
    /// @dev Normal delay; never below the REQ-CONFIG-024 lower bound.
    /// @param token Pool token.
    /// @param value New tolerance, bps.
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-049, REQ-CONFIG-054
    function setFeedAgreementToleranceBps(
        address token,
        uint16 value
    ) external;

    /// @notice Sets a market's `poolRiskFactor` in either direction.
    /// @dev Normal delay, within the hard pool-risk-factor ceiling.
    /// @param marketId Market identifier.
    /// @param value New factor, bps.
    /// @custom:spec REQ-CONFIG-015, REQ-CONFIG-049, REQ-CONFIG-054
    function setPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets `avanaFeeShareBps` in either direction.
    /// @dev `APPLICATION_ADMIN` at the normal delay, or `APPLICATION_RISK_STEWARD` at once, in either direction within
    /// `[0, 5,000]` (`OutOfBounds`).
    /// @param value New share, bps.
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-010, Q-097
    function setAvanaFeeShareBps(
        uint16 value
    ) external;

    /// @notice Sets `feeRecipient`.
    /// @dev Normal delay; reverts `InvalidFeeRecipient` for the zero address, any Avana contract the MarketRegistry
    /// records or that reports this chain's timelock or registry (or answers `logicConfig()`), a Hub, a CDP Spoke, a
    /// debt reserve's First-Loss Reserve or price source, or a PositionProxy (its `ADAPTER()` is the AaveAdapter, or the
    /// ProxyManager's `predictProxy` of its bindings is its address).
    /// @param recipient New recipient.
    /// @custom:spec REQ-CONFIG-056
    function setFeeRecipient(
        address recipient
    ) external;

    /// @notice Sets `maxFlashFeeBps`.
    /// @dev Normal delay; `OutOfBounds` above 100. A raise reverts `LivenessBound` unless the liquidation-liveness check holds for every Active
    /// or Offboarding market against every enabled debt reserve of its Spoke (the flash premium is part of what the
    /// recovered value must repay).
    /// @param value New maximum, bps.
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-021, REQ-PSTORE-024, Q-135, Q-261, Q-335
    function setMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Lowers `maxFlashFeeBps` (short delay, or at once by `APPLICATION_RISK_STEWARD`).
    /// @dev Reverts `NotStricter` unless `value < maxFlashFeeBps()`. Governance keeps it strictly above the Aave V3 Pool
    /// rate while that rate is above 0, and may lower it to 0 once the flash source and the public helper hold
    /// `FLASH_BORROWER` (SPEC-LIQ-015). A lower ceiling can only move liquidations to the
    /// caller-funded path, never stop them.
    /// @param value New maximum, bps.
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-024, Q-335
    function tightenMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Sets a token's independent second price source for borrow and withdraw-with-debt, and its reviewed
    /// standby.
    /// @dev Normal delay. Reverts `TokenNotListed` for an unlisted token and `OutOfBounds` unless every word
    /// `getOracleInputs(..., true)` serves for the source is one the oracles read: `0 < toleranceBps <= 500` and a
    /// source holding code; an `OracleNetwork` source with `maxAge > 0`, `twapWindow == 0`, `poolRef == 0` and a feed
    /// definition (`setFeed`), whose pinned decimals and bounds are served with it; a `PoolTwap` source with
    /// `twapWindow > 0`, `poolRef != 0` and `maxAge == 0`, refused for a debt asset with a DebtOracle
    /// (`debtStressRiseBps(token) > 0`), which reads only an oracle network. `src` must not be a feed of the token's
    /// recorded routes. Reverts `OracleConfigRejected` unless `checkConfig` passes for every market whose tokens
    /// include `token`. The standby (may be empty, `kind == None`) passes the same checks and reverts `OutOfBounds`
    /// when it shares a feed or pool with `src` or with the token's price routes, so it fails independently of them
    /// (AMMN-INT-01); two sources served through the same `source` address count as shared even for different pools.
    /// @param token Pool token or debt asset.
    /// @param src The second source.
    /// @param standby The standby either guardian can put in force with `useStandbySecondSource`.
    /// @custom:spec REQ-PSTORE-028, REQ-PSTORE-029, REQ-PSTORE-009, REQ-ORACLE-100, SPEC-ORC-020, Q-323
    function setSecondSource(
        address token,
        SecondSource calldata src,
        SecondSource calldata standby
    ) external;

    /// @notice Puts the token's standby second source in force at once.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` (the Emergency Guardian or the Aave Protocol Guardian), immediate: the one
    /// ParameterStore function outside `APPLICATION_ADMIN`. Reverts `NoStandby(token)` without a recorded standby and
    /// `StandbyActive(token)` while already in use, and `OutOfBounds` when the standby now shares a feed or pool with
    /// the recorded source or the token's recorded routes; sets `onStandby[token] = true` and emits
    /// `SecondSourceSwitched(token, true, msg.sender)`. A failed or disagreeing second source then stops borrowing that relies on the token for the
    /// guardians' reaction time, not for the 5-day replacement delay. Liquidation never reads a second source.
    /// @param token Pool token or debt asset.
    /// @custom:spec REQ-PSTORE-029, EMG-103
    function useStandbySecondSource(
        address token
    ) external;

    /// @notice Returns the token to its recorded second source.
    /// @dev `APPLICATION_ADMIN`, normal delay, so a guardian cannot switch back to a source that failed. With the
    /// standby in force, sets `onStandby[token] = false`, re-runs `checkConfig` for every market holding the token
    /// (`OracleConfigRejected`) and emits `SecondSourceSwitched(token, false, msg.sender)`; otherwise it changes and
    /// emits nothing.
    /// @param token Pool token or debt asset.
    /// @custom:spec REQ-PSTORE-029, EMG-103
    function restoreSecondSource(
        address token
    ) external;

    /// @notice Sets `cachedWindow`.
    /// @dev Normal delay.
    /// @param value New window, seconds.
    /// @custom:spec REQ-CONFIG-049, Q-183
    function setCachedWindow(
        uint32 value
    ) external;

    /// @notice Sets `disagreementPauseMax`.
    /// @dev Normal delay; reverts `LivenessBound` above its registry bound (3,600 seconds).
    /// @param value New maximum, seconds.
    /// @custom:spec REQ-CONFIG-052, Q-183
    function setDisagreementPauseMax(
        uint32 value
    ) external;

    /// @notice Sets a market's `twapWindow` (a change to price computation).
    /// @dev Normal delay; requires `twapWindow > 0` and `pool.observe([twapWindow, 0])` to succeed.
    /// @param marketId Market identifier.
    /// @param value New window, seconds.
    /// @custom:spec REQ-CONFIG-038, REQ-CONFIG-054
    function setTwapWindow(
        uint256 marketId,
        uint32 value
    ) external;

    /// @notice Sets the USD band.
    /// @dev Normal delay; requires `usdBandLow < 1e8 < usdBandHigh`. A breach makes the market Drifting with reason
    /// `USD_BAND`, which blocks borrowing and withdraw-with-debt only.
    /// @param low Lower level, 8 decimals per 1 USD at peg.
    /// @param high Upper level, 8 decimals per 1 USD at peg.
    /// @custom:spec REQ-CONFIG-054, REQ-CONFIG-055, Q-176, Q-195, Q-246
    function setUsdBand(
        uint256 low,
        uint256 high
    ) external;

    /// @notice Sets a feed's `liquidationPriceMaxAge`.
    /// @dev Normal delay; reverts `LivenessBound` below the feed's `feedHeartbeat`.
    /// @param feed Chainlink aggregator proxy.
    /// @param value New age limit, seconds.
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-052
    function setLiquidationPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a feed's `feedMaxAge`, the maximum age of a valid answer in LPOracle state evaluation.
    /// @dev Normal delay; reverts `OutOfBounds` unless `value == feedHeartbeat + heartbeatMargin` of the feed
    /// (`SPEC-ORC-019`), so it only re-derives the stored value after a heartbeat change. Emits `FeedConfigured`.
    /// @param feed Chainlink aggregator proxy.
    /// @param value New maximum age, seconds.
    /// @custom:spec REQ-CONFIG-023, REQ-CONFIG-049, REQ-CONFIG-054, REQ-ORACLE-002
    function setFeedMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets `graceDuration`.
    /// @dev Normal delay in either direction; at most `graceDurationMax`.
    /// @param value New duration, seconds.
    /// @custom:spec REQ-CONFIG-052, Q-246
    function setGraceDuration(
        uint32 value
    ) external;

    /// @notice Sets `graceHealthFactor`.
    /// @dev Normal delay in either direction; `graceHealthFactorMin <= value < 1e18`.
    /// @param value New health factor, WAD.
    /// @custom:spec REQ-CONFIG-052, Q-246
    function setGraceHealthFactor(
        uint256 value
    ) external;

    /// @notice Sets `feedAgreementMarginBps`.
    /// @dev Normal delay; every token's tolerance must still satisfy the REQ-CONFIG-024 lower bound.
    /// @param value New margin, bps.
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-049
    function setFeedAgreementMarginBps(
        uint16 value
    ) external;

    /// @notice Sets a market's `slippageAllowanceMinBps`.
    /// @dev Normal delay; `slippageAllowanceBps` must stay at or above it. A raise on an Active or Offboarding market
    /// reverts `LivenessBound` unless `liquidationLivenessHolds` against every enabled debt reserve of its Spoke.
    /// @param marketId Market identifier.
    /// @param value New floor, bps.
    /// @custom:spec REQ-CONFIG-041, REQ-CONFIG-049, REQ-PSTORE-021, Q-261
    function setSlippageAllowanceMinBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets a token's collateral-factor input (`tokenCollateralFactorBps`).
    /// @dev Normal delay; manual recalibration.
    /// @param token Pool token.
    /// @param value New collateral factor, bps.
    /// @custom:spec REQ-CONFIG-019, REQ-CONFIG-020, REQ-CONFIG-049
    function setTokenCollateralFactorBps(
        address token,
        uint16 value
    ) external;

    /// @notice Changes a market's stress floor.
    /// @dev Normal delay. Lowering reverts `AddCapTooSmall` unless SPEC-CAP-006 holds with the new floor; raising
    /// reverts `SupplyNotZero` unless the market's vault-token supply is 0. Emits `StressFloorSet`.
    /// @param marketId Market identifier.
    /// @param value New floor, 8-decimal USD per whole vault token.
    /// @custom:spec REQ-RISK-045, SPEC-CAP-006
    function setStressFloorUsd(
        uint256 marketId,
        uint256 value
    ) external;
}
