// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../../amm/IClIntegration.sol";
import {ISlipstreamIntegration} from "../../amm/slipstream/ISlipstreamIntegration.sol";
import {ClMarketConfig, FeeMode} from "../../amm/types/AmmTypes.sol";
import {IUniswapV4Integration} from "../../amm/uniswap-v4/IUniswapV4Integration.sol";
import {UniswapV4State} from "../../amm/uniswap-v4/UniswapV4State.sol";
import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {BackingRecord} from "../../custody/collateralization/types/CollateralizationTypes.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IUniswapV4PoolManager} from "../../interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {Market} from "../../types/MarketTypes.sol";
import {PriceState} from "../../types/OracleTypes.sol";
import {PledgeCounters, ShapeKind} from "../../types/PositionTypes.sol";
import {ILensFees} from "./ILensFees.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensMarkets} from "./ILensMarkets.sol";
import {ILensRateStrategy} from "./ILensRateStrategy.sol";
import {ILensSlipstreamFeeReads} from "./ILensSlipstreamFeeReads.sol";
import {ILensV3FeeReads} from "./ILensV3FeeReads.sol";
import {ILensV4FeeReads} from "./ILensV4FeeReads.sol";
import {LensBase} from "./LensBase.sol";
import {
    DebtReserveView,
    LensClPosition,
    LensSlipstreamTick,
    LensV3Tick,
    MarketView,
    PositionFeesView
} from "./types/LensTypes.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensMarketsModule
/// @notice Lens module serving `ILensMarkets` and `ILensFees`.
contract LensMarketsModule is LensBase, ILensMarkets, ILensFees {
    // forge-lint: disable-start(calls-loop)
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
        ILPOracle.PriceStatus memory st = ILPOracle(m.lpOracle).getPriceStatus();
        // The oracle serves at least 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        v.acceptedPrice = uint256(st.answer);
        v.priceState = st.liquidationFresh ? PriceState.Live : PriceState.Cached;
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
        _riskConfig(v, m);
    }

    function _riskConfig(
        MarketView memory v,
        Market memory m
    ) internal view {
        IAaveV4Spoke spoke = IAaveV4Spoke(m.spoke);
        v.collateralRiskBps = spoke.getReserveConfig(m.reserveId).collateralRisk;
        IAaveV4Spoke.LiquidationConfig memory lc = spoke.getLiquidationConfig();
        (v.targetHealthFactor, v.healthFactorForMaxBonus, v.liquidationBonusFactorBps) =
        (lc.targetHealthFactor, lc.healthFactorForMaxBonus, lc.liquidationBonusFactor);
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
    // forge-lint: disable-end(calls-loop)

    // forge-lint: disable-start(calls-loop)
    bytes32 internal constant UNISWAP_V3 = keccak256("UNISWAP_V3");
    bytes32 internal constant AERODROME_SLIPSTREAM = keccak256("AERODROME_SLIPSTREAM");
    bytes32 internal constant UNISWAP_V4 = keccak256("UNISWAP_V4");
    uint256 internal constant Q128 = 1 << 128;

    struct ClFees {
        address token0;
        address token1;
        // Uniswap v3: the fee tier; Slipstream: the tick spacing (as a non-negative integer).
        int256 poolParam;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256[2] last;
        uint128[2] owed;
        int24 tick;
        uint256[2] global;
        uint256[2] outsideLower;
        uint256[2] outsideUpper;
    }

    /// @inheritdoc ILensFees
    function getPositionFees(
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (PositionFeesView memory fees) {
        _unlocked();
        fees = _positionFees(marketId, _market(marketId), positionKey);
    }

    /// @inheritdoc ILensFees
    function getAccountFees(
        address wallet,
        uint256 marketId
    ) external view override returns (PositionFeesView[] memory fees) {
        _unlocked();
        Market memory m = _market(marketId);
        (address proxy, bool deployed) = _proxy(wallet, marketId, m.spoke);
        if (!deployed) return fees;
        // forge-lint: disable-start(unused-return)
        (, BackingRecord[] memory records) = ICollateralization(_COLLATERALIZATION)
            .getAccountRecords(proxy, m.vaultToken, 0, AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET);
        // forge-lint: disable-end(unused-return)
        fees = new PositionFeesView[](records.length);
        for (uint256 i = 0; i < records.length; ++i) {
            fees[i] = _positionFees(marketId, m, records[i].positionKey);
        }
    }

    /// @dev The fee view of one position; `supported` false for an unsupported protocol or a position outside the pool.
    function _positionFees(
        uint256 marketId,
        Market memory m,
        bytes32 positionKey
    ) internal view returns (PositionFeesView memory v) {
        (v.blockNumber, v.timestamp, v.marketId, v.positionKey) = (block.number, block.timestamp, marketId, positionKey);
        v.tokensOwed = new uint256[](m.tokens.length);
        v.amounts = new uint256[](m.tokens.length);
        ILPVault integration = ILPVault(m.integration);
        v.depositor = integration.depositorOf(positionKey);
        v.inCustody = v.depositor != address(0);
        bytes32 protocol = integration.AMM_PROTOCOL();
        bool v3 = protocol == UNISWAP_V3;
        if (!v3 && protocol != AERODROME_SLIPSTREAM && protocol != UNISWAP_V4) return v;
        if (integration.capabilities().feeMode != FeeMode.Separate) return v;
        ClMarketConfig memory c = IClIntegration(m.integration).clMarket(marketId);
        if (protocol == UNISWAP_V4) {
            _v4Fees(v, IUniswapV4Integration(m.integration), marketId, c, positionKey);
            return v;
        }
        uint256 tokenId = IClIntegration(m.integration).tokenIdOf(positionKey);
        if (!v3) {
            // A Slipstream key names its position manager by generation; only the market's generation matches.
            // forge-lint: disable-next-line(unsafe-typecast)
            // forge-lint: disable-next-line(unused-return)
            (address npm,) = ISlipstreamIntegration(m.integration).generation(uint8(uint256(positionKey) >> 248));
            if (npm != c.positionManager) return v;
        }
        ClFees memory f = v3 ? _v3Fees(c, tokenId) : _slipstreamFees(c, tokenId);
        if (f.token0 != c.token0 || f.token1 != c.token1) return v;
        if (f.poolParam != (v3 ? int256(uint256(c.fee)) : int256(c.tickSpacing))) return v;
        v.supported = true;
        v.liquidity = f.liquidity;
        for (uint256 i = 0; i < 2; ++i) {
            v.tokensOwed[i] = f.owed[i];
            v.amounts[i] = _owedAfterUpdate(f, i);
        }
    }

    function _v3Fees(
        ClMarketConfig memory c,
        uint256 tokenId
    ) internal view returns (ClFees memory f) {
        _position(f, ILensV3FeeReads(c.positionManager).positions(tokenId));
        ILensV3FeeReads pool = ILensV3FeeReads(c.pool);
        // Only the fields used are read from the fixed external layout.
        // forge-lint: disable-next-line(unused-return)
        (, f.tick,,,,,) = pool.slot0();
        (f.global[0], f.global[1]) = (pool.feeGrowthGlobal0X128(), pool.feeGrowthGlobal1X128());
        LensV3Tick memory lower = pool.ticks(f.tickLower);
        LensV3Tick memory upper = pool.ticks(f.tickUpper);
        f.outsideLower = [lower.feeGrowthOutside0X128, lower.feeGrowthOutside1X128];
        f.outsideUpper = [upper.feeGrowthOutside0X128, upper.feeGrowthOutside1X128];
    }

    function _slipstreamFees(
        ClMarketConfig memory c,
        uint256 tokenId
    ) internal view returns (ClFees memory f) {
        _position(f, ILensSlipstreamFeeReads(c.positionManager).positions(tokenId));
        ILensSlipstreamFeeReads pool = ILensSlipstreamFeeReads(c.pool);
        // Only the fields used are read from the fixed external layout.
        // forge-lint: disable-next-line(unused-return)
        (, f.tick,,,,) = pool.slot0();
        (f.global[0], f.global[1]) = (pool.feeGrowthGlobal0X128(), pool.feeGrowthGlobal1X128());
        LensSlipstreamTick memory lower = pool.ticks(f.tickLower);
        LensSlipstreamTick memory upper = pool.ticks(f.tickUpper);
        f.outsideLower = [lower.feeGrowthOutside0X128, lower.feeGrowthOutside1X128];
        f.outsideUpper = [upper.feeGrowthOutside0X128, upper.feeGrowthOutside1X128];
    }

    /// @dev Fees of a v4 position, computed unchecked as the PoolManager does.
    function _v4Fees(
        PositionFeesView memory v,
        IUniswapV4Integration integration,
        uint256 marketId,
        ClMarketConfig memory c,
        bytes32 positionKey
    ) internal view {
        // Only the fields used are read from the fixed external layout.
        // forge-lint: disable-next-line(unused-return)
        (, bytes32 poolId,,) = integration.marketOf(marketId);
        // Only the fields used are read from the fixed external layout.
        // forge-lint: disable-next-line(unused-return)
        (, uint256 info) = ILensV4FeeReads(c.positionManager).getPoolAndPositionInfo(uint256(positionKey));
        // The 25 upper bytes of PositionInfo are the PoolId's first 25 bytes; the ticks sit at bits 8 and 32.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (info == 0 || bytes25(bytes32(info)) != bytes25(poolId)) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        if (int24(int256(info >> 8)) != c.tickLower || int24(int256(info >> 32)) != c.tickUpper) return;
        IUniswapV4PoolManager pm = IUniswapV4PoolManager(c.factory);
        UniswapV4State.PositionState memory p = UniswapV4State.position(
            pm, poolId, UniswapV4State.positionId(c.positionManager, c.tickLower, c.tickUpper, positionKey)
        );
        (uint256 in0, uint256 in1) = UniswapV4State.feeGrowthInside(pm, poolId, c.tickLower, c.tickUpper);
        (v.amounts[0], v.amounts[1]) = UniswapV4State.feesOwed(p, in0, in1);
        v.liquidity = p.liquidity;
        v.supported = true;
    }

    function _position(
        ClFees memory f,
        LensClPosition memory p
    ) internal pure {
        (f.token0, f.token1, f.poolParam) = (p.token0, p.token1, int256(p.poolParam));
        (f.tickLower, f.tickUpper, f.liquidity) = (p.tickLower, p.tickUpper, p.liquidity);
        f.last = [p.feeGrowthInside0LastX128, p.feeGrowthInside1LastX128];
        f.owed = [p.tokensOwed0, p.tokensOwed1];
    }

    /// @dev Token `i` owed after the position manager's update, in the 0.7 sources' wrapping arithmetic.
    function _owedAfterUpdate(
        ClFees memory f,
        uint256 i
    ) internal pure returns (uint256) {
        if (f.liquidity == 0) return f.owed[i];
        uint256 inside =
            _feeGrowthInside(f.tick, f.tickLower, f.tickUpper, f.global[i], f.outsideLower[i], f.outsideUpper[i]);
        unchecked {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 growth = uint128(Math.mulDiv(inside - f.last[i], f.liquidity, Q128));
            return uint256(f.owed[i] + growth);
        }
    }

    /// @dev v3-core `Tick.getFeeGrowthInside` for one token, mod 2^256.
    function _feeGrowthInside(
        int24 tick,
        int24 lower,
        int24 upper,
        uint256 global,
        uint256 outsideLower,
        uint256 outsideUpper
    ) internal pure returns (uint256 inside) {
        unchecked {
            uint256 below = tick >= lower ? outsideLower : global - outsideLower;
            uint256 above = tick < upper ? outsideUpper : global - outsideUpper;
            inside = global - below - above;
        }
    }
    // forge-lint: disable-end(calls-loop)

    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
