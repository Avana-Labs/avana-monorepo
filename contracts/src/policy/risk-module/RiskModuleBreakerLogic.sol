// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {RiskStatus} from "../../amm/types/RiskStatus.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {BreakerReasons} from "../market-registry/types/Breaker.sol";
import {DebtReserveDef} from "../market-registry/types/DebtReserveDef.sol";
import {IssuerProbe, IssuerProbes} from "../market-registry/types/IssuerProbe.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleCalls} from "./RiskModuleCalls.sol";
import {RiskModuleConstants} from "./RiskModuleConstants.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";

/// @title RiskModuleBreakerLogic
/// @notice Circuit-breaker conditions of markets and debt reserves from live state, and their tripped state with the
/// MarketRegistry's breach times and latches (SPEC-BRK-002 to SPEC-BRK-008, Q-399).
/// @dev Views only. Market conditions: `ORACLE` (the market not Live or its borrow gates failing), `POOL_SHARE`
/// (SPEC-BRK-002), `POOL_DEPTH` (the time-weighted depth unavailable or 0), `ISSUER` (any pool token's probe,
/// SPEC-BRK-003) and `CONFIG_DRIFT` (any drift of the market's Spoke, REQ-RISK-078). Debt conditions: `DEFICIT`
/// (SPEC-BRK-004) and `ISSUER` of the asset. A breaker is tripped by its live reasons, its latched reasons and, while
/// `block.timestamp < lastBreachAt + gateRecoverySeconds`, every temporary reason: the MarketRegistry keeps one breach
/// time per key, not the reason it recorded. Every issuer probe read runs with `ISSUER_PROBE_GAS` behind the gas floor
/// of REQ-RISK-089; the combined kind makes two reads.
/// @custom:spec REQ-RISK-065, REQ-RISK-078, REQ-RISK-089, REQ-RISK-091, SPEC-BRK-002, SPEC-BRK-003, SPEC-BRK-004, SPEC-BRK-007, SPEC-BRK-008, Q-241, Q-399
// View calls and gas-limited probes in loops over at most 8 pool tokens (at most two probe reads each).
// forge-lint: disable-start(calls-loop)
contract RiskModuleBreakerLogic is RiskModuleBase, IRiskModuleBreakerLogic {
    /// @dev `paused()` and `basisPointsRate()`.
    // A selector is the first four bytes of the signature hash.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant PAUSED_SELECTOR = bytes4(keccak256("paused()"));
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes4 internal constant FEE_RATE_SELECTOR = bytes4(keccak256("basisPointsRate()"));

    /// @dev The drift logic, read for `CONFIG_DRIFT`.
    address internal immutable _DRIFT;

    /// @notice Fixes the implementation immutables and the drift logic.
    /// @param im The per-chain Avana addresses.
    /// @param drift The drift logic built with `im`.
    /// @custom:spec REQ-RISK-002
    // `_requireLogic` checks each logic address, which rejects zero (REQ-RISK-002).
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        RiskModuleImmutables memory im,
        address drift
    ) RiskModuleBase(im) {
        _requireLogic(drift, keccak256("RiskModuleDriftLogic"));
        _DRIFT = drift;
    }

    /// @inheritdoc IRiskModuleLogic
    /// @custom:spec REQ-RISK-002
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleBreakerLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    /// @custom:spec REQ-RISK-091, SPEC-BRK-002, SPEC-BRK-003
    function marketConditions(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) external view override returns (uint32 live) {
        live = _marketLive(marketId, unitsGiven, poolUnits);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    /// @custom:spec REQ-RISK-091, SPEC-BRK-003, SPEC-BRK-004
    function debtConditions(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 live) {
        live = _debtLive(spoke, debtReserveId);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    /// @custom:spec REQ-RISK-065, SPEC-BRK-007, SPEC-BRK-008
    function marketBreaker(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        uint32 live = _marketLive(marketId, unitsGiven, poolUnits);
        (uint32 latched, uint64 lastBreach) = _registry().marketBreaker(marketId);
        (reasons, reopensAt) = _tripped(live, latched, lastBreach);
    }

    /// @inheritdoc IRiskModuleBreakerLogic
    /// @custom:spec REQ-RISK-065, SPEC-BRK-004, SPEC-BRK-007, SPEC-BRK-008
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        uint32 live = _debtLive(spoke, debtReserveId);
        (uint32 latched, uint64 lastBreach) = _registry().debtBreaker(spoke, debtReserveId);
        (reasons, reopensAt) = _tripped(live, latched, lastBreach);
    }

    /// @dev Tripped reasons and reopening time (SPEC-BRK-007, SPEC-BRK-008).
    function _tripped(
        uint32 live,
        uint32 latched,
        uint64 lastBreach
    ) internal view returns (uint32 reasons, uint64 reopensAt) {
        uint256 recovery = _store().gateRecoverySeconds();
        reasons = live | latched;
        uint256 until = uint256(lastBreach) + recovery;
        bool recovering = lastBreach != 0 && block.timestamp < until;
        if (recovering) reasons |= BreakerReasons.TEMPORARY;
        // Timestamps plus a recovery of at most 7,200 s fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (live & BreakerReasons.TEMPORARY != 0) reopensAt = uint64(block.timestamp + recovery);
        // forge-lint: disable-next-line(unsafe-typecast)
        else if (recovering) reopensAt = uint64(until);
    }

    /// @dev Market conditions holding now.
    function _marketLive(
        uint256 marketId,
        bool unitsGiven,
        uint256 poolUnits
    ) internal view returns (uint32 live) {
        Market memory m = _market(marketId);
        PriceStateView memory pv = ILPOracle(m.lpOracle).getPriceState();
        if (pv.state != PriceState.Live || !pv.borrowAllowed) live |= BreakerReasons.ORACLE;
        RiskStatus memory rs =
            IAmmIntegration(m.integration).riskStatus(marketId, _store().getMarketParams(marketId).twapWindow);
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

    /// @dev SPEC-BRK-002: the LP at or below its peg level and Avana's share of the pool above the pool's cap (an
    /// unavailable depth counts as above); a cap of 10,000 bps or more is no limit.
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
        uint256 units = unitsGiven ? poolUnits : ICollateralizationViews(_COLLATERALIZATION).poolUnits(key);
        tripped = RiskModuleMath.poolShareExceeds(units, cap, rs.depthUnits);
    }

    /// @dev Debt conditions holding now: the funding Hub's deficit on the Spoke above `breakerDeficitMax × RAY`, and
    /// the asset's issuer probe.
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

    /// @dev SPEC-BRK-003: `PausedFlag` trips on `paused() == true`, `UsdtFeeRate` on `basisPointsRate() > 0`, and
    /// `UsdtFeeRateAndPaused` when either of its two reads trips, each read exactly as the single kind reads it; `None`
    /// never trips.
    function _issuerTripped(
        address token
    ) internal view returns (bool tripped) {
        IssuerProbe probe = _registry().getToken(token).issuerProbe;
        if (IssuerProbes.readsPaused(probe) && _readTrips(token, PAUSED_SELECTOR)) return true;
        if (IssuerProbes.readsFeeRate(probe)) tripped = _readTrips(token, FEE_RATE_SELECTOR);
    }

    /// @dev One probe read: a static call to `sel` with `ISSUER_PROBE_GAS` behind the gas floor, copying at most one
    /// word. A revert, an out-of-gas or return data that is not exactly 32 bytes trips (a longer answer too, whatever
    /// its first word), and so does a non-zero word.
    function _readTrips(
        address token,
        bytes4 sel
    ) private view returns (bool) {
        (bool ok, uint256 word) =
            RiskModuleCalls.staticReadWord(token, RiskModuleConstants.ISSUER_PROBE_GAS, abi.encodePacked(sel));
        return !ok || word != 0;
    }
}
// forge-lint: disable-end(calls-loop)
