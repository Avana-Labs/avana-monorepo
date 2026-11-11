// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {DebtReserveDef} from "../market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../market-registry/types/MarketStatus.sol";
import {SpokeDef} from "../market-registry/types/SpokeDef.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";

/// @title RiskModuleDriftLogic
/// @notice The Aave configuration drift check of a CDP Spoke and its markets, Hub shares == assets and the expected
/// collateral factor (2.7 Aave configuration drift check).
/// @dev Views only. A drift is returned as `(marketId, reason)`, `marketId = 0` for a Spoke-wide reason; the RiskModule
/// turns it into `ConfigDrift(marketId, reason)`. Aave reads that revert pass through unchanged (REQ-RISK-030). The
/// checks read `reserveId` and `hubAssetId` from the market record and do not require the market to be Active, so
/// activation can run them on a Registered market. The vault-token reserve of a market is checked on its latest
/// dynamic key and, inside the pre-checks, on the account's own key.
/// @custom:spec REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-ADAPTER-031, REQ-ADAPTER-032, REQ-ADAPTER-033, REQ-ADAPTER-034, REQ-ADAPTER-035, REQ-ADAPTER-036, REQ-ADAPTER-037, REQ-ADAPTER-063, REQ-ADAPTER-064, REQ-RISK-063, REQ-RISK-069, REQ-RISK-078, REQ-RISK-088, SPEC-CF-001, SPEC-CF-002
// View calls in loops over the Spoke's reserves, debt reserves and markets, all bounded by timelock listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleDriftLogic is RiskModuleBase, IRiskModuleDriftLogic {
    /// @dev EIP-1967 implementation slot of the Spoke proxy (REQ-ADAPTER-063).
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev Spoke-wide values the per-market checks reuse.
    struct SpokeCtx {
        address spoke;
        address hub;
        address oracle;
        uint256 minThreshold;
        uint256 liquidationBonusFactor;
        uint256 minBonus;
    }

    /// @notice Fixes the implementation immutables.
    /// @param im The per-chain Avana addresses.
    /// @custom:spec REQ-RISK-002
    constructor(
        RiskModuleImmutables memory im
    ) RiskModuleBase(im) {}

    /// @inheritdoc IRiskModuleLogic
    /// @custom:spec REQ-RISK-002
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleDriftLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleDriftLogic
    /// @custom:spec REQ-ADAPTER-028, REQ-ADAPTER-030, REQ-RISK-063, REQ-RISK-069, REQ-RISK-088
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
    /// @custom:spec REQ-RISK-078, REQ-RISK-090
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
    /// @custom:spec REQ-ADAPTER-037, Q-189
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view override returns (bool equal) {
        Market memory m = _market(marketId);
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        equal = hub.getAddedAssets(m.hubAssetId) == hub.getAddedShares(m.hubAssetId);
    }

    /// @inheritdoc IRiskModuleDriftLogic
    /// @custom:spec SPEC-CF-001
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view override returns (uint256 cfBps) {
        cfBps = _expectedCf(_market(marketId).tokens, marketId);
    }

    /// @dev SPEC-CF-001 over the market's tokens; 0 for a market with no token.
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

    /// @dev Spoke-wide reasons, in order: implementation, oracle, liquidation target, borrowable set, then each enabled
    /// debt reserve's identity, price source and reinvestment controller. Fills `s` for the per-market checks.
    function _spokeWide(
        address spoke,
        SpokeCtx memory s
    ) internal view returns (DriftReason) {
        SpokeDef memory sd = _registry().getSpoke(spoke);
        IAaveV4Spoke sp = IAaveV4Spoke(spoke);
        if (address(uint160(uint256(sp.extSload(IMPLEMENTATION_SLOT)))) != sd.implementation) {
            return DriftReason.SpokeImplementation;
        }
        s.spoke = spoke;
        s.hub = sd.hub;
        s.oracle = sp.ORACLE();
        if (s.oracle != sd.aaveOracle) return DriftReason.PriceSource;
        IAaveV4Spoke.LiquidationConfig memory lc = sp.getLiquidationConfig();
        // The expectation is written once the Spoke is recorded and is above 1e18 for good (the ParameterStore's
        // bound); 0 means `deployCdpSpoke` is still running, and activation requires the two equal.
        uint256 target = _store().aaveTargetHealthFactor(spoke);
        if (target != 0 && lc.targetHealthFactor != target) return DriftReason.LiquidationConfigChanged;
        s.liquidationBonusFactor = lc.liquidationBonusFactor;
        s.minBonus = _store().minLiquidationBonus(spoke);
        uint256 count = sp.getReserveCount();
        for (uint256 r = 0; r < count; ++r) {
            if (sp.getReserveConfig(r).borrowable != _registry().isApprovedDebtReserve(spoke, r)) {
                return DriftReason.DebtReserveSet;
            }
        }
        return _debtReserves(sp, s);
    }

    /// @dev Each enabled debt reserve matches its definition (`DebtReserveMismatch`), is priced by its recorded source
    /// (`DebtPriceSource`) and has no reinvestment controller on its funding Hub (`ReinvestmentController`); records the
    /// lowest risk-premium threshold below `MAX_RISK_PREMIUM_THRESHOLD` (REQ-ADAPTER-035).
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

    /// @dev Per-market reasons of one market of the Spoke.
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

    /// @dev The vault-token reserve on the Spoke: its identity, its flags and its collateral risk, and the latest
    /// dynamic-config key when none of them drifted.
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
        if (c.paused) return (DriftReason.SpokeHalted, 0);
        if (r.collateralRisk + 1 > s.minThreshold) return (DriftReason.CollateralRiskAboveThreshold, 0);
        return (DriftReason.None, r.dynamicConfigKey);
    }

    /// @dev The vault-token asset on the home Hub: the Spoke active and not halted, exactly the Spoke and the fee
    /// receiver listed, no draw cap, no drawn shares, no fee-receiver add cap, no reinvestment controller.
    function _hubAsset(
        SpokeCtx memory s,
        Market memory m
    ) internal view returns (DriftReason) {
        IAaveV4Hub h = IAaveV4Hub(s.hub);
        uint256 a = m.hubAssetId;
        IAaveV4Hub.SpokeConfig memory sc = h.getSpokeConfig(a, s.spoke);
        if (!sc.active || sc.halted) return DriftReason.SpokeHalted;
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

    /// @dev One dynamic key of the vault-token reserve: no liquidation fee, a collateral factor at most the expected
    /// one and the bonus bound of SPEC-CF-002.
    function _key(
        SpokeCtx memory s,
        uint256 reserveId,
        uint32 key,
        uint256 expectedCf
    ) internal view returns (DriftReason) {
        IAaveV4Spoke.DynamicReserveConfig memory d = IAaveV4Spoke(s.spoke).getDynamicReserveConfig(reserveId, key);
        if (d.liquidationFee != 0) return DriftReason.LiquidationFeeNonZero;
        if (d.collateralFactor > expectedCf) return DriftReason.CollateralFactorAboveExpected;
        if (RiskModuleMath.bonusBoundViolated(
                d.maxLiquidationBonus, d.collateralFactor, s.liquidationBonusFactor, s.minBonus
            )) return DriftReason.BonusBoundViolated;
        return DriftReason.None;
    }
}
// forge-lint: disable-end(calls-loop)
