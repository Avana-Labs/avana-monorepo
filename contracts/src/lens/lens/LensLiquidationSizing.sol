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
/// @notice Aave V4's liquidation sizing at the pinned Spoke version (a3ef63e), from the pinned `LiquidationLogic` source
/// rather than rewritten (`LensAaveSizing`, built with Aave's settings, called by STATICCALL): the debt to restore the target health factor at the current bonus,
/// capped by the account's debt and by the collateral, raised by Aave's dust rule, and the shares Aave seizes for it.
/// @dev Inputs are the Spoke's own reads of the same block: account data, positions, the account's dynamic
/// configuration key, the AaveOracle prices, the drawn index and the premium debt in RAY. The caller's `debtToCover` is
/// unbounded here, so the result is Aave's sizing before its `MustNotLeaveDust` check; a call sending at least
/// `debtRepaid` executes with the same sizing.
/// @custom:spec REQ-LENS-017, REQ-LENS-029, REQ-LENS-003, Q-232, Q-268
library LensLiquidationSizing {
    /// @dev RAY, Aave's 27-decimal unit.
    uint256 internal constant RAY = 1e27;

    /// @notice One sizing.
    /// @param debtRepaid `D`: drawn shares times the drawn index rounded up plus the premium rounded up, debt-asset base
    /// units, as Aave pulls it.
    /// @param unitsSeized `c`: the vault-token units Aave removes from the Hub for the liquidator (fee shares excluded).
    /// @param drawnShares Drawn shares Aave liquidates.
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

    /// @notice Aave's sizing of a liquidation of `proxy` seizing `collateralReserveId` to repay `debtReserveId`; zero
    /// when Aave would refuse it (health factor at or above 1e18, nothing supplied or borrowed, collateral disabled or
    /// at a zero collateral factor).
    /// @param sizing `LensAaveSizing`.
    /// @param spoke The CDP Spoke.
    /// @param proxy The account.
    /// @param collateralReserveId The vault-token reserve.
    /// @param debtReserveId The debt reserve.
    /// @return s The sizing.
    /// @custom:spec REQ-LENS-017, REQ-LENS-029
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

    /// @dev The sizing inputs as `liquidationCall` builds them; `ok` is false when Aave's validation would refuse
    /// the call for a reason sizing cannot change.
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
