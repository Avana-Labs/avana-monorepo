// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensHubAssets} from "./ILensHubAssets.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensRateStrategy} from "./ILensRateStrategy.sol";
import {LensRisk} from "./LensRisk.sol";
import {HubAssetView} from "./types/HubAssetView.sol";
import {SpokeKind} from "./types/SpokeKind.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensHubAssets
/// @notice The Hub-asset view of the Lend pages: the asset's totals as the Hub keeps them, its available liquidity, its
/// drawn and supply rates and rate curve, its USD price from the Lend Spoke's AaveOracle, and one slice per Spoke.
/// @dev Keyed by `(hub, assetId)`, so a lend asset that no CDP Spoke borrows yet has a view. Bounded by the Spokes the
/// Hub lists on the asset.
/// @custom:spec REQ-LENS-058, REQ-LENS-059
// View calls in a loop over the Spokes the Hub lists on the asset, a governance listing (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensHubAssets is LensRisk, ILensHubAssets {
    /// @inheritdoc ILensHubAssets
    /// @custom:spec REQ-LENS-058, REQ-LENS-059, REQ-LENS-060, REQ-LENS-005, REQ-LENS-006
    function getHubAsset(
        address hub,
        uint256 assetId
    ) external view override returns (HubAssetView memory v) {
        _unlocked();
        IAaveV4Hub h = IAaveV4Hub(hub);
        (v.underlying, v.decimals) = h.getAssetUnderlyingAndDecimals(assetId);
        if (v.underlying == address(0)) revert UnknownHubAsset(hub, assetId);
        (v.blockNumber, v.timestamp, v.hub, v.assetId) = (block.number, block.timestamp, hub, assetId);
        _totals(v);
        _rates(v);
        v.spokes = _spokeDraws(hub, assetId);
        for (uint256 i = 0; i < v.spokes.length; ++i) {
            if (v.spokes[i].kind != SpokeKind.Lend) continue;
            v.lendSpoke = v.spokes[i].spoke;
            IAaveV4Spoke lend = IAaveV4Spoke(v.lendSpoke);
            v.priceUsd8 = IAaveV4Oracle(lend.ORACLE()).getReservePrice(lend.getReserveId(hub, assetId));
            break;
        }
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev The Hub's totals of the asset: added assets and shares, owed (drawn, premium and their sum), drawn and
    /// premium shares, liquidity, swept, deficit (rounded up) and accrued fees.
    function _totals(
        HubAssetView memory v
    ) internal view {
        IAaveV4Hub h = IAaveV4Hub(v.hub);
        ILensHubReads r = ILensHubReads(v.hub);
        (v.added, v.addedShares) = (h.getAddedAssets(v.assetId), h.getAddedShares(v.assetId));
        (v.drawn, v.premium) = r.getAssetOwed(v.assetId);
        v.owed = r.getAssetTotalOwed(v.assetId);
        v.drawnShares = h.getAssetDrawnShares(v.assetId);
        // forge-lint: disable-next-line(unused-return)
        (v.premiumShares,) = r.getAssetPremiumData(v.assetId);
        (v.liquidity, v.swept) = (h.getAssetLiquidity(v.assetId), r.getAssetSwept(v.assetId));
        v.deficit = Math.ceilDiv(r.getAssetDeficitRay(v.assetId), 1e27);
        v.accruedFees = r.getAssetAccruedFees(v.assetId);
    }

    /// @dev Utilization, drawn and supply rates (as REQ-LENS-046), the fee settings and the rate curve.
    /// @custom:spec REQ-LENS-058, REQ-LENS-046
    function _rates(
        HubAssetView memory v
    ) internal view {
        IAaveV4Hub.AssetConfig memory cfg = IAaveV4Hub(v.hub).getAssetConfig(v.assetId);
        (v.liquidityFeeBps, v.feeReceiver, v.irStrategy) = (cfg.liquidityFee, cfg.feeReceiver, cfg.irStrategy);
        v.drawnRateRay = ILensHubReads(v.hub).getAssetDrawnRate(v.assetId);
        uint256 owed = v.drawn + v.premium;
        if (v.added != 0) {
            v.utilizationBps = Math.mulDiv(owed, 1e4, v.added);
            v.supplyRateRay = Math.mulDiv(v.drawnRateRay, owed * (1e4 - cfg.liquidityFee), v.added * 1e4);
        }
        ILensRateStrategy.InterestRateData memory d = ILensRateStrategy(cfg.irStrategy).getInterestRateData(v.assetId);
        (v.optimalUsageBps, v.baseDrawnRateBps) = (d.optimalUsageRatio, d.baseDrawnRate);
        (v.rateGrowthBeforeOptimalBps, v.rateGrowthAfterOptimalBps) =
        (d.rateGrowthBeforeOptimal, d.rateGrowthAfterOptimal);
    }
}
// forge-lint: disable-end(calls-loop)
