// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreTighten
/// @notice Tighten setters of the ParameterStore: each moves one risk parameter in its safer direction.
/// @dev `APPLICATION_ADMIN` through the timelock at the short delay (12 hours), or `APPLICATION_RISK_STEWARD` (the Joint
/// Configuration Safe) at once. A setter that re-runs `checkConfig` reverts `OracleConfigRejected` only for a check its
/// own write breaks. Each call reverts with `NotStricter`
/// unless the value is strictly safer than the current value, `OutOfBounds` outside the hard bounds and
/// `LivenessBound` across a liquidation-liveness bound; it emits `ParameterTightened`, `CapTightened`,
/// `MinPledgeUsdSet` or `RouteDepthThresholdSet`.
interface IParameterStoreTighten {
    /// @notice Enables or raises a market's optional `hardHealthFloor` (0 = off, the default, Q-398).
    /// @dev Safer = higher; the new value is within [1e18, 1.25e18] WAD. Set only when stress tests justify it.
    /// Example: from 1.10e18, `tightenHardHealthFloor(m, 1.12e18)` succeeds, `(m, 1.08e18)` reverts `NotStricter` and
    /// `(m, 1.30e18)` reverts `OutOfBounds`.
    /// @param marketId Market identifier.
    /// @param value New floor, WAD.
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-050, REQ-CONFIG-051, REQ-PSTORE-031, Q-398
    function tightenHardHealthFloor(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Lowers a market's `slippageAllowanceBps`.
    /// @dev Safer = lower; reverts `LivenessBound` below `slippageAllowanceMinBps`.
    /// @param marketId Market identifier.
    /// @param value New allowance, bps.
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-052
    function tightenSlippageAllowanceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Lowers a debt asset's `floorRoundingAllowance`.
    /// @dev Safer = lower.
    /// @param asset Debt asset.
    /// @param value New allowance, base units of `asset`.
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-051, Q-198, Q-380
    function tightenFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external;

    /// @notice Lowers a feed's `borrowPriceMaxAge`.
    /// @dev Safer = lower; blocks borrowing sooner and never touches liquidation. Reverts `UnknownFeed` for a feed with
    /// no definition. Emits `FeedConfigured`.
    /// @param feed Chainlink aggregator proxy.
    /// @param value New age limit, seconds.
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-009, Q-182
    function tightenBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Lowers a market's `consistencyToleranceBps`.
    /// @dev Safer = lower; reverts `LivenessBound` below `consistencyToleranceMinBps`.
    /// @param marketId Market identifier.
    /// @param value New tolerance, bps of the fair price.
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-052, REQ-PSTORE-009
    function tightenConsistencyToleranceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Lowers a token's `feedAgreementToleranceBps`.
    /// @dev Safer = lower; reverts `LivenessBound` below the REQ-CONFIG-024 lower bound.
    /// @param token Pool token.
    /// @param value New tolerance, bps.
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-049, REQ-CONFIG-052, REQ-PSTORE-009
    function tightenFeedAgreementToleranceBps(
        address token,
        uint16 value
    ) external;

    /// @notice Lowers a market's `poolRiskFactor`, to mirror an Aave collateral-factor cut.
    /// @dev Safer = lower, > 0.
    /// @param marketId Market identifier.
    /// @param value New factor, bps.
    /// @custom:spec REQ-CONFIG-015, REQ-CONFIG-049
    function tightenPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Raises a swap-route slot's depth threshold.
    /// @dev Safer = higher. A monitoring and listing criterion; `swap` does not check it. Emits
    /// `RouteDepthThresholdSet`.
    /// @param marketId Market identifier.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param depthThreshold New threshold, base units of `debtAsset`.
    /// @custom:spec REQ-CONFIG-070, Q-379
    function tightenRouteDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        uint256 depthThreshold
    ) external;

    /// @notice Lowers a market's `marketUsdCap`; existing records are unaffected.
    /// @param marketId Market identifier.
    /// @param value New cap, 8-decimal USD.
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenMarketUsdCap(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Lowers a market's `topUpSliceUsd`.
    /// @param marketId Market identifier.
    /// @param value New slice budget, 8-decimal USD.
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenTopUpSliceUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Lowers a token's `tokenUsdCap(hub, token)`.
    /// @param hub The Hub the cap is keyed by; every CDP Spoke and market of that Hub on the chain shares it.
    /// @param token Underlying pool token.
    /// @param value New cap, 8-decimal USD.
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenTokenUsdCap(
        address hub,
        address token,
        uint256 value
    ) external;

    /// @notice Lowers `depositorUsdCap(hub)`.
    /// @param hub The Hub the cap is keyed by; every CDP Spoke and market of that Hub on the chain shares it.
    /// @param value New cap, 8-decimal USD.
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenDepositorUsdCap(
        address hub,
        uint256 value
    ) external;

    /// @notice Lowers `poolShareMaxBps`, pool-share cap and concentration gate; default 10,000 bps (off, Q-403).
    /// @param value New maximum share, bps.
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenPoolShareMaxBps(
        uint16 value
    ) external;

    /// @notice Raises a market's `minPledgeUsd`.
    /// @dev Safer = higher, at most `100_000e8`. Emits `MinPledgeUsdSet`.
    /// @param marketId Market identifier.
    /// @param value New minimum, 8-decimal USD.
    /// @custom:spec REQ-PSTORE-005, Q-230
    function tightenMinPledgeUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Lowers the pool-share cap of a market's pool, `poolShareMaxBpsOf(poolKey)`, below the chain default.
    /// @dev Writes the override of the market's pool, which every market (range) of that pool on the chain shares.
    /// Safer = lower; `value` must be below the current `poolShareMaxBpsOf(poolKey)` and above 0 (`OutOfBounds`).
    /// Short delay.
    /// @param marketId Market identifier; its pool key names the pool.
    /// @param value New maximum share, bps.
    /// @custom:spec REQ-RISK-042, REQ-RISK-044, SPEC-CAP-005, Q-383, Q-399
    function tightenPoolShareMaxBpsOf(
        uint256 marketId,
        uint16 value
    ) external;
}
