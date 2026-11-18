// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../amm/IClIntegration.sol";
import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
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
/// @notice Market list and debt-reserve views: identity, price, supply, limits, headroom, rates and rate curve.
// Loops over a page of at most LENS_MAX_PAGE markets and a Spoke's enabled debt reserves.
// forge-lint: disable-start(calls-loop)
abstract contract LensMarkets is LensBase, ILensMarkets {
    /// @inheritdoc ILensMarkets
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
    function getMarket(
        uint256 marketId
    ) external view override returns (MarketView memory market) {
        _unlocked();
        market = _marketView(marketId, _market(marketId));
    }

    /// @inheritdoc ILensMarkets
    function getDebtReserve(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (DebtReserveView memory reserve) {
        _unlocked();
        reserve = _reserveView(spoke, _debtReserve(spoke, debtReserveId));
    }

    /// @inheritdoc ILensMarkets
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
        v.ammProtocol = ILPVault(m.integration).AMM_PROTOCOL();
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

    function _limits(
        MarketView memory v,
        Market memory m,
        uint256 marketId
    ) internal view {
        uint32 key = IAaveV4Spoke(m.spoke).getReserve(m.reserveId).dynamicConfigKey;
        IAaveV4Spoke.DynamicReserveConfig memory c = IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key);
        (v.collateralFactorBps, v.liquidationThresholdBps) = (c.collateralFactor, c.collateralFactor);
        (v.maxLiquidationBonusBps, v.liquidationFeeBps) = (c.maxLiquidationBonus, c.liquidationFee);
        PledgeCounters memory k = ICollateralization(_COLLATERALIZATION).getCounters(m.vaultToken, address(0));
        (v.marketUsdCap, v.topUpSliceUsd) = (_store().marketUsdCap(marketId), _store().topUpSliceUsd(marketId));
        v.marketHeadroomUsd = _room(v.marketUsdCap, k.regularUsed);
        v.sliceHeadroomUsd = _room(v.topUpSliceUsd, k.sliceUsed);
        v.addHeadroom = _addHeadroom(m);
        v.pauseState = _registry().pauseState(m.hub);
        // forge-lint: disable-next-line(unused-return)
        (v.breakerReasons,) = IRiskModule(_RISK_MODULE).getBreakerStatus(marketId);
        _riskConfig(v, m, marketId);
    }

    function _riskConfig(
        MarketView memory v,
        Market memory m,
        uint256 marketId
    ) internal view {
        IAaveV4Spoke spoke = IAaveV4Spoke(m.spoke);
        v.collateralRiskBps = spoke.getReserveConfig(m.reserveId).collateralRisk;
        IAaveV4Spoke.LiquidationConfig memory lc = spoke.getLiquidationConfig();
        (v.targetHealthFactor, v.healthFactorForMaxBonus, v.liquidationBonusFactorBps) =
        (lc.targetHealthFactor, lc.healthFactorForMaxBonus, lc.liquidationBonusFactor);
        v.hardHealthFloor = _store().hardHealthFloor(marketId);
        v.tokenUsdCaps = new uint256[](m.tokens.length);
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            v.tokenUsdCaps[i] = _store().tokenUsdCap(m.hub, m.tokens[i]);
        }
        v.addCap = IAaveV4Hub(m.hub).getSpokeConfig(m.hubAssetId, m.spoke).addCap;
        v.debtReserveIds = _registry().getDebtReserveIds(m.spoke);
        v.borrowRatesRay = new uint256[](v.debtReserveIds.length);
        for (uint256 i = 0; i < v.debtReserveIds.length; ++i) {
            DebtReserveDef memory def = _registry().getDebtReserve(m.spoke, v.debtReserveIds[i]);
            uint256 drawn = ILensHubReads(def.fundingHub).getAssetDrawnRate(def.hubAssetId);
            v.borrowRatesRay[i] = Math.mulDiv(drawn, 1e4 + v.collateralRiskBps, 1e4, Math.Rounding.Ceil);
        }
    }

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
        (v.breakerReasons,) = IRiskModule(_RISK_MODULE).getDebtBreakerStatus(spoke, def.reserveId);
        v.pauseState = _registry().pauseState(def.fundingHub);
    }

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
