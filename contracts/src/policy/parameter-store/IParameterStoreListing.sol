// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveParams} from "./types/DebtReserveParams.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title IParameterStoreListing
/// @notice Setters the listing batches of markets, tokens and debt reserves use: initial market parameters and caps,
/// a Hub's depositor cap, feed definitions, and debt-asset parameters.
/// @dev Every setter requires `APPLICATION_ADMIN` and runs through the timelock at the normal delay.
interface IParameterStoreListing {
    /// @notice Writes a registered market's parameters, including `minPledgeUsd`.
    /// @dev Reverts `NotInListing` unless the MarketRegistry has the market `Registered`. Checks: `twapWindow > 0` and
    /// the pool holds at least `twapMinObservations(marketId)` observations and the integration's time-weighted read over
    /// `[twapWindow, 0]` succeeds (`twapWindow == 0` for an AMM protocol with no time-weighted price);
    /// `consistencyToleranceBps >= consistencyToleranceMinBps`;
    /// `slippageAllowanceBps >= slippageAllowanceMinBps`; `0 < poolRiskFactor <= 4,000`;
    /// `minPledgeUsd <= 100_000e8`; the listing margin SPEC-CF-004; and the market's LPOracle returns 0 from
    /// `checkConfig(getOracleConfig(lpOracle))`, else `OracleConfigRejected`. May run again while Registered. Emits
    /// `ParameterSet` per field and `MinPledgeUsdSet`.
    /// @param marketId Market identifier.
    /// @param params Market parameters.
    /// @custom:spec REQ-PSTORE-004, REQ-PSTORE-005, REQ-PSTORE-012, REQ-CONFIG-015, REQ-CONFIG-036, REQ-CONFIG-038, REQ-CONFIG-041
    function setInitialMarketParams(
        uint256 marketId,
        MarketParams calldata params
    ) external;

    /// @notice Writes the initial caps of a registered, not yet active market.
    /// @dev Reverts `NotInListing` unless the market is `Registered`. Emits `CapLoosened` and `StressFloorSet`.
    /// @param marketId Market identifier.
    /// @param initialMarketUsdCap Regular pledge budget, 8-decimal USD.
    /// @param initialTopUpSliceUsd Rescue top-up budget, 8-decimal USD.
    /// @param initialStressFloorUsd Minimum price per whole vault token for cap booking, 8-decimal USD.
    /// @custom:spec REQ-RISK-041, REQ-PSTORE-012
    function setInitialMarketCaps(
        uint256 marketId,
        uint256 initialMarketUsdCap,
        uint256 initialTopUpSliceUsd,
        uint256 initialStressFloorUsd
    ) external;

    /// @notice Writes a Hub's depositor cap, in the batch of the first `deployCdpSpoke` that names `hub` as home Hub.
    /// @dev Reverts `NotInListing` if the Hub already has a depositor cap.
    /// @param hub The Hub.
    /// @param initialDepositorUsdCap Exposure cap per depositor across every market of the Hub, 8-decimal USD.
    /// @custom:spec REQ-PSTORE-026
    function setInitialHubCaps(
        address hub,
        uint256 initialDepositorUsdCap
    ) external;

    /// @notice Writes the initial exposure cap of a listed token on a Hub that has none yet.
    /// @dev Reverts `TokenNotListed` for an unlisted token and `NotInListing` if the (Hub, token) pair already has a
    /// cap.
    /// @param hub The Hub the cap is keyed by.
    /// @param token Underlying pool token.
    /// @param cap Aggregate exposure cap across every market of the Hub, 8-decimal USD.
    /// @custom:spec REQ-RISK-041, REQ-PSTORE-012, REQ-PSTORE-026
    function setInitialTokenCap(
        address hub,
        address token,
        uint256 cap
    ) external;

    /// @notice Adds a feed definition or changes its settings, pinned decimals or bounds.
    /// @dev A new price source. Reads `decimals()` and the aggregator's `minAnswer`/`maxAnswer` on-chain and ignores
    /// those fields of `def`; pins `maxAnswer = min(aggregator maxAnswer, def.maxAnswerCap)` (REQ-ORACLE-049); keeps a
    /// stored `borrowPriceMaxAge` a tightening lowered (below the new `feedMaxAge`); reverts `InvalidFeed` when the
    /// normalised minimum is below 1, the pinned maximum is not above the minimum or the decimals leave `[1, 18]`, `OutOfBounds` unless `0 < def.feedHeartbeat <= 86,400`, `0 < def.heartbeatMargin <=
    /// MAX_HEARTBEAT_MARGIN` and `def.feedMaxAge == def.liquidationPriceMaxAge == def.borrowPriceMaxAge ==
    /// def.feedHeartbeat + def.heartbeatMargin` (`SPEC-ORC-019`), `LivenessBound` when a token whose recorded routes
    /// use the feed would hold a tolerance below its lower bound (over every route the standby can replace),
    /// `OutOfBounds` when a higher `feedDeviationThresholdBps + heartbeatDriftBps` breaks SPEC-CF-004 for a market
    /// whose parameters are written, and `OracleConfigRejected` when an affected LPOracle's `checkConfig` fails (a
    /// market whose token routes or second sources use the feed). Emits `FeedConfigured`.
    /// @param feed Chainlink aggregator proxy.
    /// @param def Feed settings.
    /// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023, REQ-CONFIG-024, REQ-PSTORE-009, REQ-PSTORE-013, SPEC-ORC-019, Q-322
    function setFeed(
        address feed,
        FeedDef calldata def
    ) external;

    /// @notice Writes the settlement parameters of one debt asset, in the batch of its first `enableDebtReserve` or
    /// later.
    /// @dev Normal delay. Reverts `TokenNotListed` unless the asset is a listed MarketRegistry token or an asset with a
    /// fixed-price source, and `OutOfBounds` unless `0 < p.floorRoundingAllowance` and `2 × p.floorRoundingAllowance` is at most the
    /// value of 50,000 USD at the asset's accepted price. Emits `DebtAssetParamsSet`. Example: GHO (18 decimals) with
    /// `floorRoundingAllowance = 2e18`; USDC (6 decimals) with `2e6`.
    /// @param asset Debt asset.
    /// @param p The asset's settlement parameters, base units of `asset`.
    /// @custom:spec REQ-PSTORE-006, REQ-CONFIG-050, Q-380
    function setDebtAssetParams(
        address asset,
        DebtReserveParams calldata p
    ) external;
}
