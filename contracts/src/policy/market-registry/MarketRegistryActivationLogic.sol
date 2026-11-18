// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {IParameterStoreLiquidation} from "../parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreRiskViews} from "../parameter-store/IParameterStoreRiskViews.sol";
import {IParameterStoreViews} from "../parameter-store/IParameterStoreViews.sol";
import {MarketParams} from "../parameter-store/types/MarketParams.sol";
import {IRiskModuleChecks} from "../risk-module/IRiskModuleChecks.sol";
import {IRiskModuleViews} from "../risk-module/IRiskModuleViews.sol";
import {IMarketRegistryDriftLogic} from "./IMarketRegistryDriftLogic.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryOracleChecks} from "./MarketRegistryOracleChecks.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {WindDownState} from "./types/WindDownState.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MarketRegistryActivationLogic
/// @notice Bodies of `activateMarket`, `cancelRegistration` and `setMarketOffboarding`. Short delay.
/// @dev Runs by delegatecall from the MarketRegistry, except `marketDrift`, which is called directly.
// Bodies of IMarketRegistry selectors; this contract inherits no interface piece.
// solhint-disable comprehensive-interface
// Every external call here is a view, so none can re-enter the registry.
// forge-lint: disable-start(reentrancy-events)
// ParameterStore liveness views over the Spoke's enabled debt reserves; views only.
// forge-lint: disable-start(calls-loop)
contract MarketRegistryActivationLogic is MarketRegistryOracleChecks, IMarketRegistryLogic, IMarketRegistryDriftLogic {
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryActivationLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IMarketRegistryDriftLogic
    function marketDrift(
        address spoke,
        address homeHub,
        address vaultToken,
        uint256 reserveId,
        uint256 hubAssetId
    ) external view override returns (DriftReason) {
        IAaveV4Spoke s = IAaveV4Spoke(spoke);
        uint32 key = 0;
        try s.getReserve(reserveId) returns (IAaveV4Spoke.Reserve memory r) {
            if (r.hub != homeHub) return DriftReason.HomeHubMismatch;
            if (r.underlying != vaultToken || r.assetId != hubAssetId) return DriftReason.ReserveIdentity;
            key = r.dynamicConfigKey;
        } catch {
            return DriftReason.ReserveIdentity;
        }
        try s.getReserveConfig(reserveId) returns (IAaveV4Spoke.ReserveConfig memory rc) {
            if (rc.receiveSharesEnabled) return DriftReason.ReceiveSharesOn;
        } catch {
            return DriftReason.ReserveIdentity;
        }
        try s.getDynamicReserveConfig(reserveId, key) returns (IAaveV4Spoke.DynamicReserveConfig memory dc) {
            if (dc.liquidationFee != 0) return DriftReason.LiquidationFeeNonZero;
        } catch {
            return DriftReason.ReserveIdentity;
        }
        try IAaveV4Hub(homeHub).getAssetConfig(hubAssetId) returns (IAaveV4Hub.AssetConfig memory ac) {
            if (ac.reinvestmentController != address(0)) return DriftReason.ReinvestmentController;
        } catch {
            return DriftReason.ReserveIdentity;
        }
        return DriftReason.None;
    }

    function activateMarket(
        uint256 marketId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        Market storage m = l.markets[marketId];
        if (m.status != MarketStatus.Registered) revert MarketNotRegistered(marketId);
        (uint256 assetId, uint256 reserveId) = _resolveReserve(marketId, m);
        if (!_keyFree(l.marketOfHubAsset[m.hub][assetId]) || !_keyFree(l.marketOfReserve[m.spoke][reserveId])) {
            revert DuplicateMarketKey();
        }
        m.hubAssetId = assetId;
        m.reserveId = reserveId;
        l.marketOfHubAsset[m.hub][assetId] = marketId;
        l.marketOfReserve[m.spoke][reserveId] = marketId;
        uint256[] memory ids = new uint256[](1);
        ids[0] = marketId;
        IRiskModuleChecks rm = IRiskModuleChecks(_RISK_MODULE);
        try rm.checkAaveConfig(m.spoke, ids) {}
        catch {
            revert ActivationCheckFailed(marketId, "aaveConfig");
        }
        if (!rm.isHubSharesEqualAssets(marketId)) revert ActivationCheckFailed(marketId, "hubShares");
        uint256 cfLp = IRiskModuleViews(_RISK_MODULE).expectedCollateralFactorBps(marketId);
        _checkReserve(marketId, m, cfLp);
        _checkParamsAndCap(marketId, m);
        _checkOracleAndRoutes(marketId, m, cfLp);
        _checkLiveness(marketId, m.spoke);
        m.status = MarketStatus.Active;
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        m.activatedAt = uint64(block.timestamp);
        emit MarketActivated(marketId, block.chainid, m.spoke, reserveId, m.hub, assetId);
    }

    function cancelRegistration(
        uint256 marketId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        Market storage m = l.markets[marketId];
        if (m.status != MarketStatus.Registered) revert MarketNotRegistered(marketId);
        m.status = MarketStatus.Cancelled;
        delete l.marketOfKey[l.keyOf[marketId]];
        delete l.marketOfVaultToken[m.vaultToken];
        delete l.marketOfLpOracle[m.lpOracle];
        emit MarketRegistrationCancelled(marketId);
    }

    function setMarketOffboarding(
        uint256 marketId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        Market storage m = l.markets[marketId];
        if (m.status != MarketStatus.Active) revert MarketNotActive(marketId);
        IAaveV4Spoke s = IAaveV4Spoke(m.spoke);
        uint16 cf = s.getDynamicReserveConfig(m.reserveId, s.getReserve(m.reserveId).dynamicConfigKey).collateralFactor;
        m.status = MarketStatus.Offboarding;
        l.windDown[marketId] = WindDownState({
            // Block timestamps and chain identifiers fit 64 bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            offboardedAt: uint64(block.timestamp),
            unusedLastStepAt: 0,
            startLtBps: cf,
            // At most cf, a uint16.
            // forge-lint: disable-next-line(unsafe-typecast)
            targetLtBps: uint16((uint256(cf) * OFFBOARD_TARGET_SHARE_BPS) / _BPS)
        });
        emit MarketOffboarding(marketId);
    }

    function _resolveReserve(
        uint256 marketId,
        Market storage m
    ) private view returns (uint256 assetId, uint256 reserveId) {
        try IAaveV4Hub(m.hub).getAssetId(m.vaultToken) returns (uint256 a) {
            assetId = a;
        } catch {
            revert ActivationCheckFailed(marketId, "hubAsset");
        }
        try IAaveV4Spoke(m.spoke).getReserveId(m.hub, assetId) returns (uint256 r) {
            reserveId = r;
        } catch {
            revert ActivationCheckFailed(marketId, "reserve");
        }
    }

    function _checkReserve(
        uint256 marketId,
        Market storage m,
        uint256 cfLp
    ) private view {
        IAaveV4Spoke s = IAaveV4Spoke(m.spoke);
        uint256 rid = m.reserveId;
        IAaveV4Spoke.ReserveConfig memory rc = s.getReserveConfig(rid);
        if (rc.paused || rc.frozen) revert ActivationCheckFailed(marketId, "reserveState");
        IAaveV4Spoke.DynamicReserveConfig memory dc = s.getDynamicReserveConfig(rid, s.getReserve(rid).dynamicConfigKey);
        uint256 cf = dc.collateralFactor;
        uint256 maxLb = dc.maxLiquidationBonus;
        if (cf == 0 || cf > cfLp) revert ActivationCheckFailed(marketId, "collateralFactor");
        if (Math.mulDiv(maxLb, cf, _BPS, Math.Rounding.Ceil) >= _BPS) {
            revert ActivationCheckFailed(marketId, "bonusBound");
        }
        if (dc.liquidationFee != 0) revert ActivationCheckFailed(marketId, "liquidationFee");
        if (IAaveV4Hub(m.hub).getAssetConfig(m.hubAssetId).liquidityFee != 0) {
            revert ActivationCheckFailed(marketId, "liquidityFee");
        }
        IAaveV4Spoke.LiquidationConfig memory lc = s.getLiquidationConfig();
        IParameterStoreLiquidation ps = IParameterStoreLiquidation(_PARAMETER_STORE);
        if (lc.targetHealthFactor <= 1e18 || lc.targetHealthFactor != ps.aaveTargetHealthFactor(m.spoke)) {
            revert ActivationCheckFailed(marketId, "liquidationConfig");
        }
        if (maxLb < _BPS || (maxLb - _BPS) * lc.liquidationBonusFactor / _BPS < ps.minLiquidationBonus(m.spoke)) {
            revert ActivationCheckFailed(marketId, "minBonus");
        }
        _checkFeeBound(marketId, _BPS + (maxLb - _BPS) * lc.liquidationBonusFactor / _BPS);
    }

    /// @dev The slippage allowance must leave the Avana fee intact at the smallest liquidation bonus.
    function _checkFeeBound(
        uint256 marketId,
        uint256 minLb
    ) private view {
        uint256 s = IParameterStoreViews(_PARAMETER_STORE).getMarketParams(marketId).slippageAllowanceBps;
        uint256 f = IParameterStoreViews(_PARAMETER_STORE).avanaFeeShareBps();
        if (f > _BPS || s * minLb > (_BPS - f) * (minLb - _BPS)) revert ActivationCheckFailed(marketId, "feeBound");
    }

    /// @dev Market parameters and caps are set, and the Hub `addCap` covers the market's USD cap at its stress floor.
    function _checkParamsAndCap(
        uint256 marketId,
        Market storage m
    ) private view {
        MarketParams memory p = IParameterStoreViews(_PARAMETER_STORE).getMarketParams(marketId);
        if (p.poolRiskFactor == 0 || p.minPledgeUsd == 0) revert ActivationCheckFailed(marketId, "params");
        IParameterStoreRiskViews r = IParameterStoreRiskViews(_PARAMETER_STORE);
        uint256 capUsd = r.marketUsdCap(marketId);
        uint256 floorUsd = r.stressFloorUsd(marketId);
        if (capUsd == 0 || floorUsd == 0) revert ActivationCheckFailed(marketId, "caps");
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        uint256 addCap = hub.getSpokeConfig(m.hubAssetId, m.spoke).addCap;
        if (
            addCap != hub.MAX_ALLOWED_SPOKE_CAP() && addCap < Math.ceilDiv(capUsd + r.topUpSliceUsd(marketId), floorUsd)
        ) {
            revert ActivationCheckFailed(marketId, "addCap");
        }
    }

    function _checkOracleAndRoutes(
        uint256 marketId,
        Market storage m,
        uint256 cfLp
    ) private view {
        address[] memory tokens = m.tokens;
        bool listed = true;
        for (uint256 i = 0; i < tokens.length; ++i) {
            listed = listed && _s().tokens[tokens[i]].listed;
        }
        if (!listed || !_commonModeHolds(tokens)) revert ActivationCheckFailed(marketId, "registration");
        if (!_listingMarginHolds(cfLp, tokens)) revert ActivationCheckFailed(marketId, "listingMargin");
        if (!_oracleConfigPasses(m.lpOracle)) revert ActivationCheckFailed(marketId, "oracleConfig");
        if (!_oracleLive(m.lpOracle)) revert ActivationCheckFailed(marketId, "oracleLive");
        uint256[] storage drs = _s().debtReserveIds[m.spoke];
        bool covered = true;
        for (uint256 i = 0; i < drs.length && covered; ++i) {
            covered = _routesCover(marketId, _s().debtReserves[m.spoke][drs[i]].asset);
        }
        if (!covered) revert ActivationCheckFailed(marketId, "routes");
    }

    function _checkLiveness(
        uint256 marketId,
        address spoke
    ) private view {
        uint256[] storage drs = _s().debtReserveIds[spoke];
        uint256 n = drs.length;
        uint256 at = n;
        for (uint256 i = 0; i < n; ++i) {
            if (!IParameterStoreLiquidation(_PARAMETER_STORE).liquidationLivenessHolds(spoke, marketId, drs[i])) {
                at = i;
                break;
            }
        }
        if (at != n) revert LivenessBound(spoke, marketId, drs[at]);
    }
}
// forge-lint: disable-end(calls-loop)
