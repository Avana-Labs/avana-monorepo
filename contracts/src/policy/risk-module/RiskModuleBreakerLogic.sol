// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../amm/types/AmmTypes.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {ILegacyLPVault} from "../../legacy/ILegacyLPVault.sol";
import {DriftReason, Market} from "../../types/MarketTypes.sol";
import {BreakerReasons} from "../market-registry/types/Breaker.sol";
import {IssuerProbe, IssuerProbes} from "../market-registry/types/IssuerProbe.sol";
import {DebtReserveDef} from "../market-registry/types/MarketRegistryTypes.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleTypes.sol";

/// @title RiskModuleBreakerLogic
/// @notice Live circuit-breaker conditions of markets and debt reserves.
/// @dev Views only; nothing is latched, so a breaker holds exactly while one of its conditions holds.
// View calls and gas-limited probes in loops over at most 8 pool tokens (at most two probe reads each).
// forge-lint: disable-start(calls-loop)
contract RiskModuleBreakerLogic is RiskModuleBase, IRiskModuleBreakerLogic {
    // A selector is the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant PAUSED_SELECTOR = bytes4(keccak256("paused()"));
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant FEE_RATE_SELECTOR = bytes4(keccak256("basisPointsRate()"));
    /// @dev Window of the pool's time-weighted depth read by the `POOL_DEPTH` condition, seconds.
    uint32 internal constant DEPTH_WINDOW = 1800;

    address internal immutable _DRIFT;

    // `_requireLogic` checks each logic address, which rejects zero.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        RiskModuleImmutables memory im,
        address drift
    ) RiskModuleBase(im) {
        _requireLogic(drift, keccak256("RiskModuleDriftLogic"));
        _DRIFT = drift;
    }

    /// @inheritdoc IRiskModuleLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleBreakerLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    function marketConditions(
        uint256 marketId
    ) external view override returns (uint32 live) {
        live = _marketLive(marketId);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    function debtConditions(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 live) {
        live = _debtLive(spoke, debtReserveId);
    }

    function _marketLive(
        uint256 marketId
    ) internal view returns (uint32 live) {
        Market memory m = _market(marketId);
        RiskStatus memory rs = ILegacyLPVault(m.integration).riskStatus(marketId, DEPTH_WINDOW);
        if (!rs.depthAvailable || rs.depthUnits == 0) live |= BreakerReasons.POOL_DEPTH;
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            if (_issuerTripped(m.tokens[i])) {
                live |= BreakerReasons.ISSUER;
                break;
            }
        }
        // Drift on any market of the Spoke holds this market, so the market it was found on is not used.
        // forge-lint: disable-next-line(unused-return)
        (, DriftReason drift) = IRiskModuleDriftLogic(_DRIFT).spokeDrift(m.spoke);
        if (drift != DriftReason.None) live |= BreakerReasons.CONFIG_DRIFT;
    }

    function _debtLive(
        address spoke,
        uint256 debtReserveId
    ) internal view returns (uint32 live) {
        DebtReserveDef memory d = _registry().getDebtReserve(spoke, debtReserveId);
        uint256 deficit = IAaveV4Hub(d.fundingHub).getSpokeDeficitRay(d.hubAssetId, spoke);
        uint256 maxDeficit = _store().deficitMax(d.fundingHub, d.asset);
        if (maxDeficit <= type(uint256).max / RiskModuleMath.RAY && deficit > maxDeficit * RiskModuleMath.RAY) {
            live |= BreakerReasons.DEFICIT;
        }
        if (_issuerTripped(d.asset)) live |= BreakerReasons.ISSUER;
    }

    function _issuerTripped(
        address token
    ) internal view returns (bool tripped) {
        IssuerProbe probe = _registry().getToken(token).issuerProbe;
        if (IssuerProbes.readsPaused(probe) && _readTrips(token, PAUSED_SELECTOR)) return true;
        if (IssuerProbes.readsFeeRate(probe)) tripped = _readTrips(token, FEE_RATE_SELECTOR);
    }

    /// @dev One probe read: trips on a revert, out-of-gas, an answer other than 32 bytes, or a non-zero word.
    function _readTrips(
        address token,
        bytes4 sel
    ) private view returns (bool) {
        (bool ok, uint256 word) =
            RiskModuleMath.staticReadWord(token, RiskModuleMath.ISSUER_PROBE_GAS, abi.encodePacked(sel));
        return !ok || word != 0;
    }
}
// forge-lint: disable-end(calls-loop)
