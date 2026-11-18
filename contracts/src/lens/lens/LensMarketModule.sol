// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../amm/types/AmmTypes.sol";
import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {BackingRecord, Pending} from "../../custody/collateralization/types/CollateralizationTypes.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {CapView, Market} from "../../types/MarketTypes.sol";
import {PendingView, PledgeCounters} from "../../types/PositionTypes.sol";
import {ILensMarket} from "./ILensMarket.sol";
import {LensBase} from "./LensBase.sol";
import {BackingView, DrawHeadroom, RecordBackingView} from "./types/LensTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensMarketModule
/// @notice Lens module serving `ILensMarket`.
contract LensMarketModule is LensBase, ILensMarket {
    // forge-lint: disable-start(calls-loop)
    /// @inheritdoc ILensMarket
    function checkBacking(
        address vaultToken
    ) external view override returns (BackingView memory b) {
        _unlocked();
        (uint256 marketId, Market memory m) = _marketOfToken(vaultToken);
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        uint256 assetId = m.hubAssetId;
        (b.blockNumber, b.timestamp, b.marketId, b.hub, b.vaultToken) =
        (block.number, block.timestamp, marketId, m.hub, vaultToken);
        (b.assetId, b.reserveId) = (assetId, m.reserveId);
        b.totalSupply = IERC20(vaultToken).totalSupply();
        b.totalCredited = ICollateralization(_COLLATERALIZATION).getTotalCredited(vaultToken);
        Pending memory p = ICollateralization(_COLLATERALIZATION).getPending(vaultToken);
        (b.pendingUnits, b.pendingAmounts) = (p.units, p.amounts);
        b.unsettledSeizedUnits = IERC20(vaultToken).balanceOf(_LP_VAULT_SWAP);
        b.hubBalance = IERC20(vaultToken).balanceOf(m.hub);
        b.hubLiquidity = hub.getAssetLiquidity(assetId);
        b.stranded = b.hubBalance - Math.min(b.hubBalance, b.hubLiquidity);
        (b.addedAssets, b.addedShares) = (hub.getAddedAssets(assetId), hub.getAddedShares(assetId));
        b.drawnShares = hub.getAssetDrawnShares(assetId);
        b.supplyEqualsCredited = b.totalSupply == b.totalCredited + b.pendingUnits;
        b.hubHoldsSupplied = b.hubBalance >= b.hubLiquidity;
        b.sharesEqualAssets = b.addedShares == b.addedAssets;
        b.noDrawnShares = b.drawnShares == 0;
        IAaveV4Hub.AssetConfig memory cfg = hub.getAssetConfig(assetId);
        (b.noDrawCap, b.singleBorrowSpoke) = _spokeChecks(hub, assetId, m.spoke, cfg.feeReceiver);
        b.noLiquidityFee = cfg.liquidityFee == 0;
        b.noReinvestment = cfg.reinvestmentController == address(0);
        b.reserveFlags = _standardReserve(m.spoke, m.reserveId);
    }

    /// @inheritdoc ILensMarket
    function checkRecordBacking(
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view override returns (RecordBackingView[] memory records) {
        _unlocked();
        if (_emptyPage(limit)) return records;
        (, Market memory m) = _marketOfToken(vaultToken);
        ICollateralization coll = ICollateralization(_COLLATERALIZATION);
        uint256 n = coll.getMarketRecordCount(vaultToken);
        if (offset >= n) return records;
        uint256 k = n - offset;
        if (k > limit) k = limit;
        (uint256[] memory ids, BackingRecord[] memory recs) = coll.getMarketRecords(vaultToken, offset, k);
        records = new RecordBackingView[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            records[i] = _recordBacking(m.integration, ids[i], recs[i]);
        }
    }

    /// @inheritdoc ILensMarket
    function getPendingSettlement(
        address vaultToken
    ) external view override returns (PendingView memory v) {
        _unlocked();
        (uint256 marketId, Market memory m) = _marketOfToken(vaultToken);
        Pending memory p = ICollateralization(_COLLATERALIZATION).getPending(vaultToken);
        (v.blockNumber, v.timestamp, v.vaultToken, v.units, v.amounts) =
        (block.number, block.timestamp, vaultToken, p.units, p.amounts);
        v.unsettledSeizedUnits = IERC20(vaultToken).balanceOf(_LP_VAULT_SWAP);
        v.settleableUnits = Math.min(p.units, v.unsettledSeizedUnits);
        v.settleable = v.settleableUnits > 0;
        DebtReserveDef memory def = _registry().getDebtReserve(m.spoke, _registry().settlementReserve(marketId));
        v.debtAsset = def.asset;
        v.firstLossReserve = _registry().firstLossReserveOf(def.fundingHub, def.asset);
        v.valueDebt = _oracleValue(p.units, _collateralPrice(m), m.decimals, def.decimals, _debtPrice(m.spoke, def));
    }

    /// @inheritdoc ILensMarket
    function getCapHeadroom(
        address vaultToken,
        address depositor
    ) external view override returns (CapView memory c) {
        _unlocked();
        (uint256 marketId, Market memory m) = _marketOfToken(vaultToken);
        PledgeCounters memory k = ICollateralization(_COLLATERALIZATION).getCounters(vaultToken, depositor);
        (c.blockNumber, c.timestamp, c.hub, c.vaultToken, c.depositor) =
        (block.number, block.timestamp, m.hub, vaultToken, depositor);
        c.minPledgeUsd = _store().minPledgeUsd(marketId);
        c.marketHeadroomUsd = _room(_store().marketUsdCap(marketId), k.regularUsed);
        c.sliceHeadroomUsd = _room(_store().topUpSliceUsd(marketId), k.sliceUsed);
        c.tokens = m.tokens;
        c.tokenHeadroomUsd = new uint256[](m.tokens.length);
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            uint256 used = i < k.tokenUsed.length ? k.tokenUsed[i] : 0;
            c.tokenHeadroomUsd[i] = _room(_store().tokenUsdCap(m.hub, m.tokens[i]), used);
        }
        c.poolShareMaxBps = _store().poolShareMaxBpsOf(k.poolKey);
        c.poolShareBps = _poolShareBps(marketId, m.integration, k.poolUnits);
        // The oracle serves at least 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 accepted = uint256(ILPOracle(m.lpOracle).latestAnswer());
        uint256 floor = _store().stressFloorUsd(marketId);
        c.chargePricePerWholeToken = Math.max(accepted, floor);
        c.vaultTokenAddHeadroom = _addHeadroom(m);
        c.drawHeadroom = _drawHeadrooms(m.spoke);
    }

    /// @dev `noDrawCap` (no Spoke can draw) and `singleBorrowSpoke` (only the CDP Spoke and the fee receiver).
    function _spokeChecks(
        IAaveV4Hub hub,
        uint256 assetId,
        address cdpSpoke,
        address feeReceiver
    ) internal view returns (bool noDrawCap, bool single) {
        uint256 count = hub.getSpokeCount(assetId);
        noDrawCap = true;
        bool cdpSeen = false;
        bool feeSeen = false;
        bool other = false;
        for (uint256 i = 0; i < count; ++i) {
            address s = hub.getSpokeAddress(assetId, i);
            IAaveV4Hub.SpokeConfig memory sc = hub.getSpokeConfig(assetId, s);
            noDrawCap = noDrawCap && sc.drawCap == 0;
            if (s == cdpSpoke && s != feeReceiver) cdpSeen = true;
            else if (s == feeReceiver && sc.addCap == 0) feeSeen = true;
            else other = true;
        }
        single = cdpSeen && feeSeen && !other;
    }

    /// @dev Standard-Spoke settings of the vault-token reserve: not borrowable, no receive-shares, no liquidation fee.
    function _standardReserve(
        address spoke,
        uint256 reserveId
    ) internal view returns (bool ok) {
        IAaveV4Spoke.ReserveConfig memory rc = IAaveV4Spoke(spoke).getReserveConfig(reserveId);
        ok = !rc.borrowable && !rc.receiveSharesEnabled;
        uint32 latest = IAaveV4Spoke(spoke).getReserve(reserveId).dynamicConfigKey;
        for (uint256 key = 0; key <= latest; ++key) {
            // forge-lint: disable-next-line(unsafe-typecast)
            ok = ok && IAaveV4Spoke(spoke).getDynamicReserveConfig(reserveId, uint32(key)).liquidationFee == 0;
        }
    }

    /// @dev One record of `checkRecordBacking`; a position out of custody reports 0 live units and is not backed.
    function _recordBacking(
        address integration,
        uint256 recordId,
        BackingRecord memory r
    ) internal view returns (RecordBackingView memory v) {
        (v.blockNumber, v.timestamp, v.recordId) = (block.number, block.timestamp, recordId);
        (v.integrationId, v.positionKey, v.credited) = (r.integrationId, r.positionKey, r.credited);
        v.inCustody = ILPVault(integration).depositorOf(r.positionKey) != address(0);
        if (v.inCustody) v.liveUnits = ILPVault(integration).unitsOf(r.positionKey);
        v.backed = v.inCustody && v.liveUnits >= v.credited;
    }

    /// @dev Avana's share of the pool's TWAP depth, bps rounded up; max when units are credited and depth is 0.
    function _poolShareBps(
        uint256 marketId,
        address integration,
        uint256 poolUnits
    ) internal view returns (uint256 bps) {
        if (poolUnits == 0) return 0;
        RiskStatus memory rs = ILPVault(integration).riskStatus(marketId, _store().getMarketParams(marketId).twapWindow);
        if (!rs.depthAvailable || rs.depthUnits == 0) return type(uint256).max;
        bps = Math.mulDiv(poolUnits, SettlementMath.BPS, rs.depthUnits, Math.Rounding.Ceil);
    }

    /// @dev One `drawCap` headroom per enabled debt reserve of the Spoke; unlimited for Aave's maximum cap.
    function _drawHeadrooms(
        address spoke
    ) internal view returns (DrawHeadroom[] memory out) {
        uint256[] memory ids = _registry().getDebtReserveIds(spoke);
        out = new DrawHeadroom[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            out[i] = DrawHeadroom({
                reserveId: ids[i], headroom: _drawHeadroom(spoke, _registry().getDebtReserve(spoke, ids[i]))
            });
        }
    }
    // forge-lint: disable-end(calls-loop)

    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
