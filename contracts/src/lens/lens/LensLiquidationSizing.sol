// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensAaveSizing} from "./ILensAaveSizing.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensSpokeReads} from "./ILensSpokeReads.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensLiquidationSizing
/// @notice Aave V4's liquidation sizing, called on `LensAaveSizing` built from Aave's own `LiquidationLogic`.
/// @dev `debtToCover` is unbounded here, so the result is Aave's sizing before its `MustNotLeaveDust` check.
library LensLiquidationSizing {
    uint256 internal constant RAY = 1e27;

    /// @param debtRepaid Debt Aave pulls, debt-asset base units, rounded up.
    /// @param unitsSeized Vault-token units Aave seizes for the liquidator (fee shares excluded).
    /// @param premiumDebtRay Premium debt Aave liquidates, RAY.
    /// @param wholeDebt Every drawn share is liquidated.
    /// @param allCollateral Every supplied share is seized.
    struct Sizing {
        uint256 debtRepaid;
        uint256 unitsSeized;
        uint256 drawnShares;
        uint256 premiumDebtRay;
        bool wholeDebt;
        bool allCollateral;
    }

    /// @notice Aave's sizing of a liquidation of `proxy`; zero when Aave would refuse it.
    /// @param sizing `LensAaveSizing`.
    function size(
        address sizing,
        address spoke,
        address proxy,
        uint256 collateralReserveId,
        uint256 debtReserveId
    ) internal view returns (Sizing memory s) {
        (bool ok, ILensAaveSizing.Params memory a) = _inputs(spoke, proxy, collateralReserveId, debtReserveId);
        if (!ok) return s;
        ILensAaveSizing.Amounts memory r = ILensAaveSizing(sizing).calculateLiquidationAmounts(a);
        s.drawnShares = r.drawnSharesToLiquidate;
        s.premiumDebtRay = r.premiumDebtRayToLiquidate;
        s.debtRepaid = Math.mulDiv(r.drawnSharesToLiquidate, a.drawnIndex, RAY, Math.Rounding.Ceil)
            + Math.ceilDiv(r.premiumDebtRayToLiquidate, RAY);
        s.unitsSeized = ILensHubReads(a.collateralReserveHub)
            .previewRemoveByShares(a.collateralReserveAssetId, r.collateralSharesToLiquidator);
        s.wholeDebt = r.drawnSharesToLiquidate == a.drawnShares;
        s.allCollateral = r.collateralSharesToLiquidate == a.suppliedShares;
    }

    /// @dev Sizing inputs as `liquidationCall` builds them; `ok` false when Aave's validation would refuse the call.
    function _inputs(
        address spoke,
        address proxy,
        uint256 collateralReserveId,
        uint256 debtReserveId
    ) private view returns (bool ok, ILensAaveSizing.Params memory a) {
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        IAaveV4Spoke.UserAccountData memory ud = sp.getUserAccountData(proxy);
        if (ud.healthFactor >= 1e18) return (false, a);
        IAaveV4Spoke.UserPosition memory cpos = sp.getUserPosition(collateralReserveId, proxy);
        a.drawnShares = sp.getUserPosition(debtReserveId, proxy).drawnShares;
        // forge-lint: disable-next-line(unused-return)
        (bool collateral,) = sp.getUserReserveStatus(collateralReserveId, proxy);
        IAaveV4Spoke.DynamicReserveConfig memory dc =
            sp.getDynamicReserveConfig(collateralReserveId, cpos.dynamicConfigKey);
        if (cpos.suppliedShares == 0 || a.drawnShares == 0 || !collateral || dc.collateralFactor == 0) {
            return (false, a);
        }
        ok = true;
        IAaveV4Spoke.Reserve memory cr = sp.getReserve(collateralReserveId);
        IAaveV4Spoke.Reserve memory dr = sp.getReserve(debtReserveId);
        IAaveV4Oracle oracle = IAaveV4Oracle(sp.ORACLE());
        (a.collateralReserveHub, a.collateralReserveAssetId) = (cr.hub, cr.assetId);
        (a.suppliedShares, a.collateralAssetDecimals) = (cpos.suppliedShares, cr.decimals);
        a.collateralAssetPrice = oracle.getReservePrice(collateralReserveId);
        a.premiumDebtRay = ILensSpokeReads(spoke).getUserPremiumDebtRay(debtReserveId, proxy);
        a.drawnIndex = ILensHubReads(dr.hub).getAssetDrawnIndex(dr.assetId);
        (a.totalDebtValueRay, a.debtAssetDecimals) = (ud.totalDebtValueRay, dr.decimals);
        a.debtAssetPrice = oracle.getReservePrice(debtReserveId);
        a.debtToCover = type(uint256).max;
        (a.collateralFactor, a.maxLiquidationBonus, a.liquidationFee) =
        (dc.collateralFactor, dc.maxLiquidationBonus, dc.liquidationFee);
        IAaveV4Spoke.LiquidationConfig memory lc = sp.getLiquidationConfig();
        (a.healthFactorForMaxBonus, a.liquidationBonusFactor, a.targetHealthFactor) =
        (lc.healthFactorForMaxBonus, lc.liquidationBonusFactor, lc.targetHealthFactor);
        a.healthFactor = ud.healthFactor;
    }
}
