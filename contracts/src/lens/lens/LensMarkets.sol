// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IClIntegration} from "../../amm/IClIntegration.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IRiskModuleViews} from "../../policy/risk-module/IRiskModuleViews.sol";
import {Market} from "../../types/Market.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensMarkets} from "./ILensMarkets.sol";
import {ILensRateStrategy} from "./ILensRateStrategy.sol";
import {LensBase} from "./LensBase.sol";
import {DebtReserveView} from "./types/DebtReserveView.sol";
import {MarketView} from "./types/MarketView.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensMarkets
/// @notice The app's market list and debt-reserve views: identity, accepted price, Aave supply and its value, limits,
/// headroom, Hub totals, drawn and supply rates and the rate curve.
/// @dev Bounded by the caller's page, the market's pool tokens and the Spoke's enabled debt reserves.
/// @custom:spec REQ-LENS-045, REQ-LENS-046
// View calls in loops over a page of at most LENS_MAX_PAGE markets and a Spoke's enabled debt reserves (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensMarkets is LensBase, ILensMarkets {
    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-045, REQ-LENS-023, REQ-LENS-024, REQ-LENS-006
    function getMarkets(
        uint256 offset,
        uint256 limit
    ) external view override returns (MarketView[] memory markets) {
        _unlocked();
        if (_emptyPage(limit)) return markets;
        uint256 n = _registry().marketCount();
        if (offset >= n) return markets;
        uint256 k = n - offset;
        markets = new MarketView[](k < limit ? k : limit);
        for (uint256 i = 0; i < markets.length; ++i) {
            markets[i] = _marketView(offset + i + 1, _registry().getMarket(offset + i + 1));
        }
    }

    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-045, REQ-LENS-022, REQ-LENS-006
    function getMarket(
        uint256 marketId
    ) external view override returns (MarketView memory market) {
        _unlocked();
        market = _marketView(marketId, _market(marketId));
    }

    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-046, REQ-LENS-032, REQ-LENS-006
    function getDebtReserve(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (DebtReserveView memory reserve) {
        _unlocked();
        reserve = _reserveView(spoke, _debtReserve(spoke, debtReserveId));
    }

    /// @inheritdoc ILensMarkets
    /// @custom:spec REQ-LENS-046, REQ-LENS-006
    function getDebtReserves(
        address spoke
    ) external view override returns (DebtReserveView[] memory reserves) {
        _unlocked();
        uint256[] memory ids = _registry().getDebtReserveIds(spoke);
        reserves = new DebtReserveView[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            reserves[i] = _reserveView(spoke, _registry().getDebtReserve(spoke, ids[i]));
        }
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev The market view of REQ-LENS-045.
    function _marketView(
        uint256 marketId,
        Market memory m
    ) internal view returns (MarketView memory v) {
        (v.blockNumber, v.timestamp, v.marketId, v.chainId, v.status) =
        (block.number, block.timestamp, marketId, m.chainId, m.status);
        (v.pool, v.poolId, v.tokens, v.tokenDecimals) = (m.pool, m.poolId, m.tokens, m.tokenDecimals);
        (v.tickLower, v.tickUpper, v.integrationId) = (m.shape.tickLower, m.shape.tickUpper, m.integrationId);
        if (m.vaultToken == address(0)) return v;
        if (m.shape.kind == ShapeKind.TickRange) v.feeTier = IClIntegration(m.integration).clMarket(marketId).fee;
        v.ammProtocol = IAmmIntegration(m.integration).AMM_PROTOCOL();
        (v.vaultToken, v.lpOracle, v.hub, v.spoke) = (m.vaultToken, m.lpOracle, m.hub, m.spoke);
        (v.name, v.symbol) = (IERC20Metadata(m.vaultToken).name(), IERC20Metadata(m.vaultToken).symbol());
        (v.reserveId, v.hubAssetId) = (m.reserveId, m.hubAssetId);
        // forge-lint: disable-next-line(unused-return)
        (v.acceptedPrice,) = ILPOracle(m.lpOracle).lastAcceptedPrice();
        // forge-lint: disable-next-line(unused-return)
        (,, v.priceState) = ILPOracle(m.lpOracle).getTokenPrices();
        v.suppliedUnits = IAaveV4Hub(m.hub).getSpokeAddedAssets(m.hubAssetId, m.spoke);
        v.suppliedUsd = Math.mulDiv(v.suppliedUnits, v.acceptedPrice, 10 ** m.decimals);
        _limits(v, m, marketId);
    }

    /// @dev Collateral factor and bonus of the reserve's latest dynamic configuration, headroom, pause and breakers.
    function _limits(
        MarketView memory v,
        Market memory m,
        uint256 marketId
    ) internal view {
        uint32 key = IAaveV4Spoke(m.spoke).getReserve(m.reserveId).dynamicConfigKey;
        IAaveV4Spoke.DynamicReserveConfig memory c = IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key);
        (v.collateralFactorBps, v.liquidationThresholdBps) = (c.collateralFactor, c.collateralFactor);
        v.maxLiquidationBonusBps = c.maxLiquidationBonus;
        PledgeCounters memory k = ICollateralizationViews(_COLLATERALIZATION).getCounters(m.vaultToken, address(0));
        v.marketHeadroomUsd = _room(_store().marketUsdCap(marketId), k.regularUsed);
        v.sliceHeadroomUsd = _room(_store().topUpSliceUsd(marketId), k.sliceUsed);
        v.addHeadroom = _addHeadroom(m);
        v.pauseState = _registry().pauseState(m.hub);
        // forge-lint: disable-next-line(unused-return)
        (v.breakerReasons,) = IRiskModuleViews(_RISK_MODULE).getBreakerStatus(marketId);
    }

    /// @dev The debt-reserve view of REQ-LENS-046.
    function _reserveView(
        address spoke,
        DebtReserveDef memory def
    ) internal view returns (DebtReserveView memory v) {
        (v.blockNumber, v.timestamp, v.spoke, v.reserveId) = (block.number, block.timestamp, spoke, def.reserveId);
        (v.asset, v.decimals, v.fixedPrice, v.hub, v.hubAssetId) =
        (def.asset, def.decimals, def.fixedPrice, def.fundingHub, def.hubAssetId);
        v.price = IAaveV4Oracle(IAaveV4Spoke(spoke).ORACLE()).getReservePrice(def.reserveId);
        _hubTotals(v);
        IAaveV4Spoke.ReserveConfig memory rc = IAaveV4Spoke(spoke).getReserveConfig(def.reserveId);
        (v.paused, v.frozen, v.borrowable) = (rc.paused, rc.frozen, rc.borrowable);
        v.drawCap = IAaveV4Hub(def.fundingHub).getSpokeConfig(def.hubAssetId, spoke).drawCap;
        v.drawHeadroom = _drawHeadroom(spoke, def);
        // forge-lint: disable-next-line(unused-return)
        (v.breakerReasons,) = IRiskModuleViews(_RISK_MODULE).getDebtBreakerStatus(spoke, def.reserveId);
        v.pauseState = _registry().pauseState(def.fundingHub);
    }

    /// @dev Hub totals, utilization, the drawn and supply rates and the rate curve of the reserve's Hub asset.
    /// @custom:spec REQ-LENS-046
    function _hubTotals(
        DebtReserveView memory v
    ) internal view {
        IAaveV4Hub hub = IAaveV4Hub(v.hub);
        v.added = hub.getAddedAssets(v.hubAssetId);
        (v.drawn, v.premium) = ILensHubReads(v.hub).getAssetOwed(v.hubAssetId);
        v.liquidity = hub.getAssetLiquidity(v.hubAssetId);
        v.drawnRateRay = ILensHubReads(v.hub).getAssetDrawnRate(v.hubAssetId);
        IAaveV4Hub.AssetConfig memory cfg = hub.getAssetConfig(v.hubAssetId);
        v.liquidityFeeBps = cfg.liquidityFee;
        uint256 owed = v.drawn + v.premium;
        if (v.added != 0) {
            v.utilizationBps = Math.mulDiv(owed, 1e4, v.added);
            v.supplyRateRay = Math.mulDiv(v.drawnRateRay, owed * (1e4 - cfg.liquidityFee), v.added * 1e4);
        }
        ILensRateStrategy.InterestRateData memory d =
            ILensRateStrategy(cfg.irStrategy).getInterestRateData(v.hubAssetId);
        (v.optimalUsageBps, v.baseDrawnRateBps) = (d.optimalUsageRatio, d.baseDrawnRate);
        (v.rateGrowthBeforeOptimalBps, v.rateGrowthAfterOptimalBps) =
        (d.rateGrowthBeforeOptimal, d.rateGrowthAfterOptimal);
    }
}
// forge-lint: disable-end(calls-loop)
