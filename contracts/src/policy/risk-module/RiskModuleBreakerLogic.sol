// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../amm/types/AmmTypes.sol";
import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
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
/// @notice Circuit-breaker conditions and tripped state of markets and debt reserves.
/// @dev Views only, except `pokeOracles`, whose only state changes are the oracles' own `poke()`.
// View calls and gas-limited probes in loops over at most 8 pool tokens (at most two probe reads each).
// forge-lint: disable-start(calls-loop)
contract RiskModuleBreakerLogic is RiskModuleBase, IRiskModuleBreakerLogic {
    // A selector is the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant PAUSED_SELECTOR = bytes4(keccak256("paused()"));
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant FEE_RATE_SELECTOR = bytes4(keccak256("basisPointsRate()"));

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
    function pokeOracles(
        uint256 marketId
    ) external override {
        Market memory m = _market(marketId);
        // The pokes store observations only; the conditions read the price state themselves.
        // forge-lint: disable-next-line(unused-return)
        ILPOracle(m.lpOracle).poke();
        uint256[] memory ids = _registry().getDebtReserveIds(m.spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            DebtReserveDef memory d = _registry().getDebtReserve(m.spoke, ids[i]);
            // forge-lint: disable-next-line(unused-return)
            if (!d.fixedPrice) IDebtOracle(d.priceSource).poke();
        }
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    function marketConditions(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) external view override returns (uint32 live) {
        live = _marketLive(marketId, unitsGiven, poolUnits);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    function debtConditions(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 live) {
        live = _debtLive(spoke, debtReserveId);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    function marketBreaker(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        uint32 live = _marketLive(marketId, unitsGiven, poolUnits);
        // Recovery reads the per-reason breach times, not the latest of any reason.
        // forge-lint: disable-next-line(unused-return)
        (uint32 latched,) = _registry().marketBreaker(marketId);
        (reasons, reopensAt) = _tripped(live, latched, bytes32(marketId));
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        uint32 live = _debtLive(spoke, debtReserveId);
        // As in `marketBreaker`.
        // forge-lint: disable-next-line(unused-return)
        (uint32 latched,) = _registry().debtBreaker(spoke, debtReserveId);
        (reasons, reopensAt) = _tripped(live, latched, _debtKey(spoke, debtReserveId));
    }

    /// @dev Live and latched reasons, plus each temporary reason inside `gateRecoverySeconds` of its last breach.
    function _tripped(
        uint32 live,
        uint32 latched,
        bytes32 key
    ) internal view returns (uint32 reasons, uint64 reopensAt) {
        uint256 recovery = _store().gateRecoverySeconds();
        reasons = live | latched;
        uint256 until = 0;
        uint32[3] memory temporary = [BreakerReasons.ORACLE, BreakerReasons.POOL_SHARE, BreakerReasons.POOL_DEPTH];
        for (uint256 i = 0; i < 3; ++i) {
            uint256 at = _registry().lastBreachAt(BreakerReasons.breachKey(key, temporary[i]));
            if (at == 0 || block.timestamp >= at + recovery) continue;
            reasons = reasons | temporary[i];
            if (at + recovery > until) until = at + recovery;
        }
        // Timestamps plus a recovery of at most 7,200 s fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (live & BreakerReasons.TEMPORARY != 0) reopensAt = uint64(block.timestamp + recovery);
        // forge-lint: disable-next-line(unsafe-typecast)
        else if (until != 0) reopensAt = uint64(until);
    }

    function _marketLive(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) internal view returns (uint32 live) {
        Market memory m = _market(marketId);
        PriceStateView memory pv = ILPOracle(m.lpOracle).getPriceState();
        if (pv.state != PriceState.Live || !pv.borrowAllowed) live |= BreakerReasons.ORACLE;
        RiskStatus memory rs =
            ILPVault(m.integration).riskStatus(marketId, _store().getMarketParams(marketId).twapWindow);
        if (!rs.depthAvailable || rs.depthUnits == 0) live |= BreakerReasons.POOL_DEPTH;
        if (_concentrated(m, pv, rs, unitsGiven, poolUnits)) live |= BreakerReasons.POOL_SHARE;
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            if (_issuerTripped(m.tokens[i])) {
                live |= BreakerReasons.ISSUER;
                break;
            }
        }
        // Drift on any market of the Spoke trips this market, so the market it was found on is not used.
        // forge-lint: disable-next-line(unused-return)
        (, DriftReason drift) = IRiskModuleDriftLogic(_DRIFT).spokeDrift(m.spoke);
        if (drift != DriftReason.None) live |= BreakerReasons.CONFIG_DRIFT;
    }

    /// @dev The LP at or below its peg and Avana's pool share above the cap (unknown depth counts as above).
    function _concentrated(
        Market memory m,
        PriceStateView memory pv,
        RiskStatus memory rs,
        bool unitsGiven,
        uint256 poolUnits
    ) internal view returns (bool tripped) {
        bytes32 key = _poolKey(m);
        uint256 cap = _store().poolShareMaxBpsOf(key);
        if (cap >= NO_POOL_SHARE_CAP) return false;
        uint256[] memory quotes = new uint256[](pv.tokens.length);
        for (uint256 i = 0; i < quotes.length; ++i) {
            quotes[i] = pv.tokens[i].quote;
        }
        if (!RiskModuleMath.atOrBelowPeg(quotes)) return false;
        if (!rs.depthAvailable) return true;
        uint256 units = unitsGiven ? poolUnits : ICollateralization(_COLLATERALIZATION).poolUnits(key);
        tripped = RiskModuleMath.poolShareExceeds(units, cap, rs.depthUnits);
    }

    function _debtLive(
        address spoke,
        uint256 debtReserveId
    ) internal view returns (uint32 live) {
        DebtReserveDef memory d = _registry().getDebtReserve(spoke, debtReserveId);
        uint256 deficit = IAaveV4Hub(d.fundingHub).getSpokeDeficitRay(d.hubAssetId, spoke);
        uint256 maxDeficit = _store().breakerDeficitMax(d.fundingHub, d.asset);
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
