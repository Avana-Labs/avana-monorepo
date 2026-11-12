// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensAaveSizing
/// @notice ABI of `LensAaveSizing` (`aave-deploy/`), Aave V4's pinned liquidation sizing compiled with Aave's settings.
/// @dev The structs are the ABI of Aave's `LiquidationLogic.CalculateLiquidationAmountsParams` and
/// `LiquidationAmounts` at a3ef63e, field for field (the collateral Hub as an address).
/// @custom:spec REQ-LENS-017, REQ-LENS-029
interface ILensAaveSizing {
    /// @notice Sizing inputs, as `liquidationCall` builds them.
    struct Params {
        address collateralReserveHub;
        uint256 collateralReserveAssetId;
        uint256 suppliedShares;
        uint256 collateralAssetDecimals;
        uint256 collateralAssetPrice;
        uint256 drawnShares;
        uint256 premiumDebtRay;
        uint256 drawnIndex;
        uint256 totalDebtValueRay;
        uint256 debtAssetDecimals;
        uint256 debtAssetPrice;
        uint256 debtToCover;
        uint256 collateralFactor;
        uint256 healthFactorForMaxBonus;
        uint256 liquidationBonusFactor;
        uint256 maxLiquidationBonus;
        uint256 targetHealthFactor;
        uint256 healthFactor;
        uint256 liquidationFee;
    }

    /// @notice Aave's liquidation amounts.
    struct Amounts {
        uint256 collateralSharesToLiquidate;
        uint256 collateralSharesToLiquidator;
        uint256 drawnSharesToLiquidate;
        uint256 premiumDebtRayToLiquidate;
    }

    /// @notice `LiquidationLogic._calculateLiquidationAmounts(params)` at the pinned release.
    /// @param params The sizing inputs.
    /// @return amounts The amounts.
    function calculateLiquidationAmounts(
        Params calldata params
    ) external view returns (Amounts memory amounts);
}
