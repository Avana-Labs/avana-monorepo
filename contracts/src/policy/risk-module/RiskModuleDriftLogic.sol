// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DriftReason, Market} from "../../types/MarketTypes.sol";
import {DebtReserveDef, MarketStatus, SpokeDef} from "../market-registry/types/MarketRegistryTypes.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleTypes.sol";

/// @title RiskModuleDriftLogic
/// @notice Aave configuration drift of a CDP Spoke and its markets, Hub shares == assets and expected CF.
/// @dev Views only. Does not require the market to be Active, so activation can run it on a Registered market.
// View calls in loops over the Spoke's reserves, debt reserves and markets, all bounded by timelock listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleDriftLogic is RiskModuleBase, IRiskModuleDriftLogic {
    struct SpokeCtx {
        address spoke;
        address hub;
        address oracle;
        uint256 minThreshold;
    }

    constructor(
        RiskModuleImmutables memory im
    ) RiskModuleBase(im) {}

    /// @inheritdoc IRiskModuleLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleDriftLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleDriftLogic
    function driftOf(
        address spoke,
        uint256[] calldata marketIds,
        address proxy
    ) external view override returns (uint256 marketId, DriftReason reason) {
        SpokeCtx memory s;
        reason = _spokeWide(spoke, s);
        if (reason != DriftReason.None) return (0, reason);
        for (uint256 i = 0; i < marketIds.length; ++i) {
            reason = _marketDrift(s, marketIds[i], _market(marketIds[i]), proxy);
            if (reason != DriftReason.None) return (marketIds[i], reason);
        }
    }

    /// @inheritdoc IRiskModuleDriftLogic
    function spokeDrift(
        address spoke
    ) external view override returns (uint256 marketId, DriftReason reason) {
        SpokeCtx memory s;
        reason = _spokeWide(spoke, s);
        if (reason != DriftReason.None) return (0, reason);
        uint256[] memory ids = _registry().marketsOfSpoke(spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            Market memory m = _market(ids[i]);
            if (m.status != MarketStatus.Active && m.status != MarketStatus.Offboarding) continue;
            reason = _marketDrift(s, ids[i], m, address(0));
            if (reason != DriftReason.None) return (ids[i], reason);
        }
    }

    /// @inheritdoc IRiskModuleDriftLogic
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view override returns (bool equal) {
        Market memory m = _market(marketId);
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        equal = hub.getAddedAssets(m.hubAssetId) == hub.getAddedShares(m.hubAssetId);
    }

    /// @inheritdoc IRiskModuleDriftLogic
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view override returns (uint256 cfBps) {
        cfBps = _expectedCf(_market(marketId).tokens, marketId);
    }

    /// @dev Expected collateral factor over the market's tokens; 0 for a market with no token.
    function _expectedCf(
        address[] memory tokens,
        uint256 marketId
    ) internal view returns (uint256 cfBps) {
        if (tokens.length == 0) return 0;
        uint256 minCf = type(uint256).max;
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 cf = _store().tokenCollateralFactorBps(tokens[i]);
            if (cf < minCf) minCf = cf;
        }
        cfBps = RiskModuleMath.lpCollateralFactor(minCf, _store().getMarketParams(marketId).poolRiskFactor);
    }

    function _spokeWide(
        address spoke,
        SpokeCtx memory s
    ) internal view returns (DriftReason) {
        // The Spoke's implementation must match the one recorded at approval; unreadable reads as not current.
        // forge-lint: disable-next-line(unused-return)
        (,, bool current) = _registry().spokeImplementationStatus(spoke);
        if (!current) return DriftReason.SpokeImplementation;
        SpokeDef memory sd = _registry().getSpoke(spoke);
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        s.spoke = spoke;
        s.hub = sd.hub;
        s.oracle = sp.ORACLE();
        if (s.oracle != sd.aaveOracle) return DriftReason.PriceSource;
        uint256 count = sp.getReserveCount();
        for (uint256 r = 0; r < count; ++r) {
            if (sp.getReserveConfig(r).borrowable != _registry().isApprovedDebtReserve(spoke, r)) {
                return DriftReason.DebtReserveSet;
            }
        }
        return _debtReserves(sp, s);
    }

    function _debtReserves(
        IAaveV4Spoke sp,
        SpokeCtx memory s
    ) internal view returns (DriftReason) {
        uint256[] memory ids = _registry().getDebtReserveIds(s.spoke);
        s.minThreshold = type(uint256).max;
        for (uint256 i = 0; i < ids.length; ++i) {
            DebtReserveDef memory d = _registry().getDebtReserve(s.spoke, ids[i]);
            IAaveV4Spoke.Reserve memory r = sp.getReserve(ids[i]);
            if (
                r.underlying != d.asset || r.hub != d.fundingHub || r.assetId != d.hubAssetId
                    || r.decimals != d.decimals
            ) {
                return DriftReason.DebtReserveMismatch;
            }
            if (IAaveV4Oracle(s.oracle).getReserveSource(ids[i]) != d.priceSource) return DriftReason.DebtPriceSource;
            IAaveV4Hub h = IAaveV4Hub(d.fundingHub);
            if (h.getAssetConfig(d.hubAssetId).reinvestmentController != address(0)) {
                return DriftReason.ReinvestmentController;
            }
            uint256 t = h.getSpokeConfig(d.hubAssetId, s.spoke).riskPremiumThreshold;
            if (t != h.MAX_RISK_PREMIUM_THRESHOLD() && t < s.minThreshold) s.minThreshold = t;
        }
        return DriftReason.None;
    }

    function _marketDrift(
        SpokeCtx memory s,
        uint256 marketId,
        Market memory m,
        address proxy
    ) internal view returns (DriftReason reason) {
        uint32 latestKey;
        (reason, latestKey) = _reserveDrift(s, m);
        if (reason != DriftReason.None) return reason;
        reason = _hubAsset(s, m);
        if (reason != DriftReason.None) return reason;
        if (IAaveV4Oracle(s.oracle).getReserveSource(m.reserveId) != m.lpOracle) return DriftReason.PriceSource;
        uint256 expected = _expectedCf(m.tokens, marketId);
        reason = _key(s, m.reserveId, latestKey, expected);
        if (reason != DriftReason.None || proxy == address(0)) return reason;
        uint32 own = IAaveV4Spoke(s.spoke).getUserPosition(m.reserveId, proxy).dynamicConfigKey;
        if (own != latestKey) reason = _key(s, m.reserveId, own, expected);
    }

    function _reserveDrift(
        SpokeCtx memory s,
        Market memory m
    ) internal view returns (DriftReason, uint32 latestKey) {
        if (m.spoke != s.spoke) return (DriftReason.ReserveIdentity, 0);
        if (m.hub != s.hub) return (DriftReason.HomeHubMismatch, 0);
        IAaveV4Spoke sp = IAaveV4Spoke(s.spoke);
        IAaveV4Spoke.Reserve memory r = sp.getReserve(m.reserveId);
        if (r.underlying != m.vaultToken || r.hub != s.hub || r.assetId != m.hubAssetId || r.decimals != m.decimals) {
            return (DriftReason.ReserveIdentity, 0);
        }
        IAaveV4Spoke.ReserveConfig memory c = sp.getReserveConfig(m.reserveId);
        if (c.receiveSharesEnabled) return (DriftReason.ReceiveSharesOn, 0);
        if (c.borrowable) return (DriftReason.Borrowable, 0);
        if (r.collateralRisk + 1 > s.minThreshold) return (DriftReason.CollateralRiskAboveThreshold, 0);
        return (DriftReason.None, r.dynamicConfigKey);
    }

    function _hubAsset(
        SpokeCtx memory s,
        Market memory m
    ) internal view returns (DriftReason) {
        IAaveV4Hub h = IAaveV4Hub(s.hub);
        uint256 a = m.hubAssetId;
        IAaveV4Hub.SpokeConfig memory sc = h.getSpokeConfig(a, s.spoke);
        IAaveV4Hub.AssetConfig memory ac = h.getAssetConfig(a);
        if (h.getSpokeCount(a) != 2) return DriftReason.ExtraSpoke;
        address s0 = h.getSpokeAddress(a, 0);
        address s1 = h.getSpokeAddress(a, 1);
        bool pair = (s0 == s.spoke && s1 == ac.feeReceiver) || (s1 == s.spoke && s0 == ac.feeReceiver);
        if (!pair || s0 == s1) return DriftReason.ExtraSpoke;
        IAaveV4Hub.SpokeConfig memory fc = h.getSpokeConfig(a, ac.feeReceiver);
        if (sc.drawCap != 0 || fc.drawCap != 0) return DriftReason.DrawCapNonZero;
        if (h.getAssetDrawnShares(a) != 0) return DriftReason.DrawnSharesNonZero;
        if (fc.addCap != 0) return DriftReason.FeeReceiverAddCap;
        if (ac.reinvestmentController != address(0)) return DriftReason.ReinvestmentController;
        return DriftReason.None;
    }

    function _key(
        SpokeCtx memory s,
        uint256 reserveId,
        uint32 key,
        uint256 expectedCf
    ) internal view returns (DriftReason) {
        IAaveV4Spoke.DynamicReserveConfig memory d = IAaveV4Spoke(s.spoke).getDynamicReserveConfig(reserveId, key);
        if (d.liquidationFee != 0) return DriftReason.LiquidationFeeNonZero;
        if (d.collateralFactor > expectedCf) return DriftReason.CollateralFactorAboveExpected;
        if (RiskModuleMath.bonusBoundViolated(d.maxLiquidationBonus, d.collateralFactor)) {
            return DriftReason.BonusBoundViolated;
        }
        return DriftReason.None;
    }
}
// forge-lint: disable-end(calls-loop)
