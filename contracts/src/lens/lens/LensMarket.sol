// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {RiskStatus} from "../../amm/types/RiskStatus.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {BackingRecord} from "../../custody/collateralization/types/BackingRecord.sol";
import {Pending} from "../../custody/collateralization/types/Pending.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {CapView} from "../../types/CapView.sol";
import {Market} from "../../types/Market.sol";
import {PendingView} from "../../types/PendingView.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {ILensMarket} from "./ILensMarket.sol";
import {LensBase} from "./LensBase.sol";
import {BackingView} from "./types/BackingView.sol";
import {DrawHeadroom} from "./types/DrawHeadroom.sol";
import {RecordBackingView} from "./types/RecordBackingView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensMarket
/// @notice Market views of the Lens: the backing and standard-configuration check, record backing by page, the
/// pending-settlement balance and Avana and Aave cap headroom.
/// @dev Loops only over the Spokes listed on the vault-token asset, the reserve's dynamic configuration keys, one page
/// of records, the market's pool tokens and the Spoke's enabled debt reserves.
/// @custom:spec REQ-LENS-012, REQ-LENS-013, REQ-LENS-014, REQ-LENS-018, REQ-LENS-019, REQ-LENS-023, REQ-LENS-024, REQ-LENS-026
// View calls in loops over listings bounded by governance (Spokes, debt reserves, markets, pool tokens), one
// page of at most LENS_MAX_PAGE records or the caller's own arrays (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensMarket is LensBase, ILensMarket {
    /// @inheritdoc ILensMarket
    /// @custom:spec REQ-LENS-012, REQ-LENS-013, REQ-LENS-005, REQ-LENS-006
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
        b.totalCredited = ICollateralizationViews(_COLLATERALIZATION).getTotalCredited(vaultToken);
        Pending memory p = ICollateralizationViews(_COLLATERALIZATION).getPending(vaultToken);
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
    /// @custom:spec REQ-LENS-014, REQ-LENS-023, REQ-LENS-024, REQ-LENS-005, REQ-LENS-006
    function checkRecordBacking(
        address vaultToken,
        uint256 offset,
        uint256 limit
    ) external view override returns (RecordBackingView[] memory records) {
        _unlocked();
        if (_emptyPage(limit)) return records;
        (, Market memory m) = _marketOfToken(vaultToken);
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
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
    /// @custom:spec REQ-LENS-026, REQ-LENS-005, REQ-LENS-006
    function getPendingSettlement(
        address vaultToken
    ) external view override returns (PendingView memory v) {
        _unlocked();
        (uint256 marketId, Market memory m) = _marketOfToken(vaultToken);
        Pending memory p = ICollateralizationViews(_COLLATERALIZATION).getPending(vaultToken);
        (v.blockNumber, v.timestamp, v.vaultToken, v.units, v.amounts) =
        (block.number, block.timestamp, vaultToken, p.units, p.amounts);
        v.unsettledSeizedUnits = IERC20(vaultToken).balanceOf(_LP_VAULT_SWAP);
        v.settleableUnits = Math.min(p.units, v.unsettledSeizedUnits);
        v.settleable = v.settleableUnits > 0;
        DebtReserveDef memory def = _registry().getDebtReserve(m.spoke, _registry().settlementReserve(marketId));
        v.debtAsset = def.asset;
        v.coverageSpoke = _registry().coverageSpokeOf(def.fundingHub, def.asset);
        v.valueDebt = _oracleValue(p.units, _collateralPrice(m), m.decimals, def.decimals, _debtPrice(m.spoke, def));
    }

    /// @inheritdoc ILensMarket
    /// @custom:spec REQ-LENS-018, REQ-LENS-019, REQ-LENS-005, REQ-LENS-006
    function getCapHeadroom(
        address vaultToken,
        address depositor
    ) external view override returns (CapView memory c) {
        _unlocked();
        (uint256 marketId, Market memory m) = _marketOfToken(vaultToken);
        PledgeCounters memory k = ICollateralizationViews(_COLLATERALIZATION).getCounters(vaultToken, depositor);
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
        c.depositorHeadroomUsd = _room(_store().depositorUsdCap(m.hub), k.depositorUsed);
        c.poolShareMaxBps = _store().poolShareMaxBpsOf(k.poolKey);
        c.poolShareBps = _poolShareBps(marketId, m.integration, k.poolUnits);
        // forge-lint: disable-next-line(unused-return)
        (uint256 accepted,) = ILPOracle(m.lpOracle).lastAcceptedPrice();
        // A pledge is booked at min(fresh, accepted) (REQ-RISK-026); a failed market's fresh price is 0.
        int256 fresh = ILPOracle(m.lpOracle).getPriceState().freshAnswer;
        // A positive int256 is cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (fresh > 0 && uint256(fresh) < accepted) accepted = uint256(fresh);
        uint256 floor = _store().stressFloorUsd(marketId);
        c.chargePricePerWholeToken = Math.max(accepted, floor);
        c.vaultTokenAddHeadroom = _addHeadroom(m);
        c.drawHeadroom = _drawHeadrooms(m.spoke);
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev `noDrawCap` (every Spoke on the asset has `drawCap == 0`) and `singleBorrowSpoke` (the Spokes are exactly the
    /// CDP Spoke and the fee receiver, whose `addCap` is 0).
    /// @custom:spec REQ-LENS-012, REQ-LENS-013
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

    /// @dev The three standard-Spoke settings of the vault-token reserve: not borrowable, `receiveSharesEnabled` off,
    /// and `liquidationFee == 0` on every dynamic configuration key up to the reserve's latest.
    /// @custom:spec REQ-LENS-012, REQ-LENS-013
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

    /// @dev One record of `checkRecordBacking`: in custody when the LPVault names a depositor of record (its
    /// `isInCustody`); a position out of custody reports 0 live units and is not backed.
    /// @custom:spec REQ-LENS-014
    function _recordBacking(
        address integration,
        uint256 recordId,
        BackingRecord memory r
    ) internal view returns (RecordBackingView memory v) {
        (v.blockNumber, v.timestamp, v.recordId) = (block.number, block.timestamp, recordId);
        (v.integrationId, v.positionKey, v.credited) = (r.integrationId, r.positionKey, r.credited);
        v.inCustody = IAmmIntegration(integration).depositorOf(r.positionKey) != address(0);
        if (v.inCustody) v.liveUnits = IAmmIntegration(integration).unitsOf(r.positionKey);
        v.backed = v.inCustody && v.liveUnits >= v.credited;
    }

    /// @dev Avana's share of the pool's time-weighted depth, bps rounded up: the pool's credited units over the depth
    /// the market's AMM integration reports for the market's TWAP window; `type(uint256).max` when units are credited
    /// and the depth is unavailable or 0.
    /// @custom:spec REQ-LENS-018, SPEC-CAP-005
    function _poolShareBps(
        uint256 marketId,
        address integration,
        uint256 poolUnits
    ) internal view returns (uint256 bps) {
        if (poolUnits == 0) return 0;
        RiskStatus memory rs =
            IAmmIntegration(integration).riskStatus(marketId, _store().getMarketParams(marketId).twapWindow);
        if (!rs.depthAvailable || rs.depthUnits == 0) return type(uint256).max;
        bps = Math.mulDiv(poolUnits, SettlementMath.BPS, rs.depthUnits, Math.Rounding.Ceil);
    }

    /// @dev One `drawCap` headroom per enabled debt reserve of the Spoke, on the funding Hub and asset its definition
    /// names: `max(0, drawCap × 10^d − totalOwed − ⌈deficitRay / 1e27⌉)`; unlimited for Aave's maximum cap.
    /// @custom:spec REQ-LENS-019
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
}
// forge-lint: disable-end(calls-loop)
