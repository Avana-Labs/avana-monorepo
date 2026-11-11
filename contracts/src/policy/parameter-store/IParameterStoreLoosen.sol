// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreLoosen
/// @notice Loosen setters of the ParameterStore: each moves one risk parameter in its riskier direction.
/// @dev `APPLICATION_ADMIN` through the timelock at the normal delay; any canceller can cancel a queued call. Each call
/// reverts with `NotLooser` unless the value is strictly looser and `OutOfBounds` outside the hard bounds. The
/// step-limited parameters (`hardHealthFloor`, the four USD caps, `slippageAllowanceBps`) also revert
/// `LoosenStepTooLarge` beyond one step and `LoosenTooSoon` within `normalDelay` of their last loosening, and record
/// `lastLoosenedAt`.
interface IParameterStoreLoosen {
    /// @notice Lowers or disables a market's `hardHealthFloor`.
    /// @dev At most `LOOSEN_HEALTH_FACTOR_STEP` (0.03e18) below the current value; a value below 1e18 is written as 0
    /// (off). Example: `loosenHardHealthFloor(m, 1.07e18)` from 1.10e18 succeeds and `(m, 1.06e18)` reverts
    /// `LoosenStepTooLarge`; from 1.03e18, `(m, 0)` switches it off.
    /// @param marketId Market identifier.
    /// @param value New floor, WAD, or 0 for off.
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-053, REQ-PSTORE-017, REQ-PSTORE-031, Q-398
    function loosenHardHealthFloor(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Raises a market's `slippageAllowanceBps`.
    /// @dev At most `LOOSEN_SLIPPAGE_STEP_BPS` above the current value.
    /// @param marketId Market identifier.
    /// @param value New allowance, bps.
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-053, REQ-CONFIG-071, REQ-PSTORE-017
    function loosenSlippageAllowanceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Raises a debt asset's `floorRoundingAllowance`.
    /// @dev `2 × value` at most the value of 50,000 USD at the asset's accepted price, else `OutOfBounds`. No
    /// settlement budget bounds it (Q-397).
    /// @param asset Debt asset.
    /// @param value New allowance, base units of `asset`.
    /// @custom:spec REQ-CONFIG-050, REQ-CONFIG-053, Q-198, Q-267, Q-380
    function loosenFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external;

    /// @notice Lowers a swap-route slot's depth threshold. Emits `RouteDepthThresholdSet`.
    /// @param marketId Market identifier.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param depthThreshold New threshold, base units of `debtAsset`.
    /// @custom:spec REQ-CONFIG-070, Q-379
    function loosenRouteDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        uint256 depthThreshold
    ) external;

    /// @notice Raises a market's `marketUsdCap`.
    /// @dev Reverts `AddCapTooSmall` unless SPEC-CAP-006 still holds with the new value; at most 1.5 times the current
    /// value.
    /// @param marketId Market identifier.
    /// @param value New cap, 8-decimal USD.
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, SPEC-CAP-006, REQ-PSTORE-017
    function loosenMarketUsdCap(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Raises a market's `topUpSliceUsd`.
    /// @dev Reverts `AddCapTooSmall` unless SPEC-CAP-006 still holds with the new value; at most 1.5 times
    /// `max(current, ⌊marketUsdCap / 10⌋)`.
    /// @param marketId Market identifier.
    /// @param value New slice budget, 8-decimal USD.
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, SPEC-CAP-006, REQ-PSTORE-017
    function loosenTopUpSliceUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Raises a token's `tokenUsdCap(hub, token)`, to at most 1.5 times the current value.
    /// @param hub The Hub the cap is keyed by; every CDP Spoke and market of that Hub on the chain shares it.
    /// @param token Underlying pool token.
    /// @param value New cap, 8-decimal USD.
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, REQ-PSTORE-017
    function loosenTokenUsdCap(
        address hub,
        address token,
        uint256 value
    ) external;

    /// @notice Raises `depositorUsdCap(hub)`, to at most 1.5 times the current value.
    /// @param hub The Hub the cap is keyed by; every CDP Spoke and market of that Hub on the chain shares it.
    /// @param value New cap, 8-decimal USD.
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, REQ-PSTORE-017
    function loosenDepositorUsdCap(
        address hub,
        uint256 value
    ) external;

    /// @notice Raises `poolShareMaxBps`, the pool-share cap and the concentration gate (Q-399).
    /// @dev Within its hard bounds (`OutOfBounds`).
    /// @param value New maximum share, bps.
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, REQ-PSTORE-016
    function loosenPoolShareMaxBps(
        uint16 value
    ) external;

    /// @notice Lowers a market's `minPledgeUsd`. Emits `MinPledgeUsdSet`.
    /// @param marketId Market identifier.
    /// @param value New minimum, 8-decimal USD.
    /// @custom:spec REQ-PSTORE-005, Q-230
    function loosenMinPledgeUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Raises the pool-share cap of a market's pool, `poolShareMaxBpsOf(poolKey)`, at most to the chain
    /// default `poolShareMaxBps()`.
    /// @dev Writes the override of the market's pool; `value` above the chain default reverts `OutOfBounds`. Normal
    /// delay; never short-eligible.
    /// @param marketId Market identifier; its pool key names the pool.
    /// @param value New maximum share, bps.
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, SPEC-CAP-005, Q-383, Q-399
    function loosenPoolShareMaxBpsOf(
        uint256 marketId,
        uint16 value
    ) external;
}
