// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreLiquidation
/// @notice Liquidation-liveness and settlement parameters.
interface IParameterStoreLiquidation {
    /// @notice Whether the smallest liquidation bonus covers the slippage floor and the flash premium.
    /// @dev False when the market, its reserve or the debt reserve is unknown.
    function liquidationLivenessHolds(
        address spoke,
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (bool holds);

    /// @notice Largest per-leg slippage raise a caller shortfall top-up can buy.
    function maxShortfallBps() external view returns (uint16 value);

    /// @notice Lowers `maxShortfallBps`.
    function tightenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Raises `maxShortfallBps`.
    function loosenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Stress rise the DebtOracle applies to a debt asset's accepted price once it has expired.
    /// @return value bps; 0 when none is written.
    function debtStressRiseBps(
        address asset
    ) external view returns (uint16 value);

    /// @notice Raises a debt asset's `debtStressRiseBps`; the listing batch writes the first value with it.
    /// @dev Reverts `OutOfBounds` while the asset's recorded or standby second source is a `PoolTwap`.
    function tightenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Lowers a debt asset's `debtStressRiseBps`.
    function loosenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Target health factor Avana's sizing assumes for a CDP Spoke.
    /// @return value WAD (0 for a Spoke with no value written).
    function aaveTargetHealthFactor(
        address spoke
    ) external view returns (uint256 value);

    /// @notice Minimum liquidation bonus Avana's sizing assumes for a CDP Spoke.
    /// @return value bps (0 for a Spoke with no value written).
    function minLiquidationBonus(
        address spoke
    ) external view returns (uint16 value);

    /// @notice Writes a CDP Spoke's expected Aave liquidation configuration, in either direction.
    /// @dev Reverts `UnknownSpoke` unless the MarketRegistry approves the Spoke.
    /// @param targetHealthFactor Expected `targetHealthFactor`, WAD.
    function setLiquidationExpectations(
        address spoke,
        uint256 targetHealthFactor,
        uint16 minLiquidationBonusBps
    ) external;
}
