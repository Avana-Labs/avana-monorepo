// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {RiskStatus} from "../../amm/types/RiskStatus.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {BreakerReasons} from "../market-registry/types/Breaker.sol";
import {MarketStatus} from "../market-registry/types/MarketStatus.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {IRiskModulePledgeLogic} from "./IRiskModulePledgeLogic.sol";
import {RiskModuleConstants} from "./RiskModuleConstants.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {RiskModulePreview} from "./RiskModulePreview.sol";
import {PledgeCharge} from "./types/PledgeCharge.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";

/// @title RiskModulePledgeLogic
/// @notice Body of `checkPledge`: eligibility, the sequencer gate and the new-account checks, the minimum value, the
/// Aave pre-checks, the cap tests with the top-up slice, the pool-share cap, the market breaker and the rescue rule;
/// also the restore amount and the remaining-record minimum.
/// @dev A view safe under STATICCALL that makes no call to Collateralization or the LPVault (REQ-RISK-006): the
/// counters arrive as arguments, the position was validated by the integration at custody, and Collateralization's
/// own pledge refuses a 17th record (a re-credit passes its own record in the count, so the count is not tested here).
/// Order: market Active, integration, units, account class, sequencer gate (new account), price state, Aave reserve
/// and Hub availability, debt reserves paused, drift and Hub shares (new account), rescue minimum, Hub `addCap`, reserve
/// limit, caps and slice, then the exemption step of REQ-RISK-066.
/// @custom:spec REQ-RISK-006, REQ-RISK-009, REQ-RISK-010, REQ-RISK-011, REQ-RISK-012, REQ-RISK-013, REQ-RISK-014, REQ-RISK-016, REQ-RISK-017, REQ-RISK-018, REQ-RISK-019, REQ-RISK-020, REQ-RISK-021, REQ-RISK-022, REQ-RISK-023, REQ-RISK-024, REQ-RISK-025, REQ-RISK-026, REQ-RISK-027, REQ-RISK-028, REQ-RISK-029, REQ-RISK-030, REQ-RISK-047, REQ-RISK-057, REQ-RISK-058, REQ-RISK-066, REQ-RISK-067, REQ-RISK-070, REQ-RISK-073, REQ-RISK-074, REQ-RISK-079, REQ-RISK-081, SPEC-CAP-001, SPEC-CAP-002, SPEC-CAP-003, SPEC-CAP-005
// View calls in loops over the market's pool tokens and the Spoke's reserves, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModulePledgeLogic is RiskModulePreview {
    bytes32 internal constant CAP_MARKET = "MARKET";
    bytes32 internal constant CAP_SLICE = "SLICE";
    bytes32 internal constant CAP_TOKEN = "TOKEN";
    bytes32 internal constant CAP_DEPOSITOR = "DEPOSITOR";

    /// @notice Fixes the implementation immutables and the drift and breaker logic.
    /// @param im The per-chain Avana addresses.
    /// @param drift The drift logic built with `im`.
    /// @param breaker The breaker logic built with `im`.
    /// @custom:spec REQ-RISK-002
    constructor(
        RiskModuleImmutables memory im,
        address drift,
        address breaker
    ) RiskModulePreview(im, drift, breaker) {}

    /// @inheritdoc IRiskModuleLogic
    /// @custom:spec REQ-RISK-002
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModulePledgeLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModulePledgeLogic
    /// @custom:spec REQ-RISK-006, REQ-RISK-025, REQ-RISK-066
    function checkPledge(
        address,
        address proxy,
        uint256 marketId,
        uint32 integrationId,
        bytes32,
        uint128 units,
        PledgeCounters calldata counters,
        bool requireRescue
    ) external view override returns (PledgeCharge memory charge) {
        Ctx memory c;
        c.marketId = marketId;
        c.m = _market(marketId);
        c.proxy = proxy;
        c.units = units;
        _eligibility(c, integrationId);
        _value(c);
        _hubRoom(c);
        charge.usdCharge = c.charge;
        charge.sliceUsd = _caps(c, counters);
        RiskModuleMath.Outcome o = _exemption(c, counters, requireRescue);
        if (o == RiskModuleMath.Outcome.Rescue) {
            charge.rescue = true;
            charge.rescueUnits = units;
        } else if (charge.sliceUsd > 0) {
            // sliceUsd <= usdCharge, so the quotient is at most `units`.
            // forge-lint: disable-next-line(unsafe-typecast)
            charge.rescueUnits = uint128(_mulDivUp(units, charge.sliceUsd, c.charge));
        }
    }

    /// @inheritdoc IRiskModulePledgeLogic
    /// @custom:spec SPEC-CAP-003
    function usdToRestore(
        address proxy
    ) external view override returns (uint256 usd) {
        (address spoke, uint256 marketId) = _account(proxy);
        IAaveV4Spoke.UserAccountData memory a = _accountData(spoke, proxy);
        if (a.borrowCount == 0) return 0;
        usd = RiskModuleMath.usdToRestore(a.healthFactor, a.totalDebtValueRay, _latestCf(spoke, _market(marketId)));
    }

    /// @inheritdoc IRiskModulePledgeLogic
    /// @custom:spec REQ-RISK-070, REQ-RISK-075, WDR-031
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view override {
        Market memory m = _market(marketId);
        uint256 usd = RiskModuleMath.pledgeUsd(remainingUnits, _accepted(m.lpOracle), m.decimals);
        uint256 minUsd = _store().minPledgeUsd(marketId);
        if (usd < minUsd) revert RecordBelowMinPledge(usd, minUsd);
    }

    /// @dev Market status and integration, units, account class, the sequencer gate and price state, the Aave reserve
    /// and Hub availability and, for a new account, the debt reserves, drift and Hub shares (REQ-RISK-009 to
    /// REQ-RISK-020, REQ-RISK-081).
    function _eligibility(
        Ctx memory c,
        uint32 integrationId
    ) internal view {
        if (c.m.status != MarketStatus.Active) {
            if (c.m.status == MarketStatus.Offboarding) revert MarketOffboarding(c.marketId);
            revert MarketNotActive(c.marketId);
        }
        if (integrationId != c.m.integrationId) revert IntegrationMismatch(c.marketId, integrationId);
        if (c.units == 0) revert ZeroLiquidity();
        IAaveV4Spoke.UserAccountData memory a = _accountData(c.m.spoke, c.proxy);
        c.topUp = a.borrowCount > 0;
        c.hf = c.topUp ? a.healthFactor : type(uint256).max;
        c.debtRay = a.totalDebtValueRay;
        if (!c.topUp) _requireSequencerUp();
        PriceStateView memory pv = ILPOracle(c.m.lpOracle).getPriceState();
        if (pv.state == PriceState.Cached || pv.state == PriceState.Expired) revert PriceNotAccepted(uint8(pv.state));
        if (!c.topUp && pv.state == PriceState.Drifting && (pv.reasons & PRICE_DRIFTING_BITS) != PRICE_USD_BAND) {
            revert PriceNotAccepted(uint8(pv.state));
        }
        _reserveAvailable(c);
        if (!c.topUp) _newAccount(c);
    }

    /// @dev REQ-RISK-020: the vault-token reserve neither paused nor frozen, the Spoke active and not halted on the Hub.
    function _reserveAvailable(
        Ctx memory c
    ) internal view {
        IAaveV4Spoke.ReserveConfig memory rc = IAaveV4Spoke(c.m.spoke).getReserveConfig(c.m.reserveId);
        if (rc.paused || rc.frozen) revert AaveReserveUnavailable();
        IAaveV4Hub.SpokeConfig memory sc = IAaveV4Hub(c.m.hub).getSpokeConfig(c.m.hubAssetId, c.m.spoke);
        if (!sc.active || sc.halted) revert HubSpokeUnavailable();
    }

    /// @dev REQ-RISK-018, REQ-RISK-019: every enabled debt reserve unpaused, no drift, Hub shares == assets.
    function _newAccount(
        Ctx memory c
    ) internal view {
        uint256[] memory ids = _registry().getDebtReserveIds(c.m.spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (IAaveV4Spoke(c.m.spoke).getReserveConfig(ids[i]).paused) revert DebtReservePaused(ids[i]);
        }
        uint256[] memory one = new uint256[](1);
        one[0] = c.marketId;
        (uint256 driftMarket, DriftReason reason) = IRiskModuleDriftLogic(_DRIFT).driftOf(c.m.spoke, one, address(0));
        if (reason != DriftReason.None) revert ConfigDrift(driftMarket, reason);
        if (!IRiskModuleDriftLogic(_DRIFT).isHubSharesEqualAssets(c.marketId)) {
            revert HubSharesNotEqualAssets(c.marketId);
        }
    }

    /// @dev Prices, value, charge and the rescue minimum (SPEC-CAP-001, REQ-RISK-057, REQ-RISK-067); the restore amount
    /// of an eligible top-up (SPEC-CAP-003).
    function _value(
        Ctx memory c
    ) internal view {
        uint256 price8 = _accepted(c.m.lpOracle);
        uint256 floorUsd = _store().stressFloorUsd(c.marketId);
        c.minPledge = _store().minPledgeUsd(c.marketId);
        c.pledgeUsd = RiskModuleMath.pledgeUsd(c.units, price8, c.m.decimals);
        c.charge = RiskModuleMath.usdCharge(c.units, price8, floorUsd, c.m.decimals);
        uint256 rescueMin = RiskModuleMath.rescueMinimum(c.minPledge);
        if (c.pledgeUsd < rescueMin) revert BelowMinPledge(c.pledgeUsd, rescueMin);
        c.eligible = c.topUp && c.hf < RiskModuleConstants.RESCUE_HEALTH_FACTOR;
        if (c.eligible) {
            uint256 restore = RiskModuleMath.usdToRestore(c.hf, c.debtRay, _latestCf(c.m.spoke, c.m));
            c.restore = RiskModuleMath.restoreBooked(restore, price8, floorUsd, _served(c.m.lpOracle));
        }
    }

    /// @dev REQ-RISK-020: the Hub `addCap` (whole vault tokens, unless the Hub's no-cap value) and the Spoke's
    /// per-account collateral reserve limit when the reserve is not yet collateral of the account.
    function _hubRoom(
        Ctx memory c
    ) internal view {
        IAaveV4Hub hub = IAaveV4Hub(c.m.hub);
        uint256 addCap = hub.getSpokeConfig(c.m.hubAssetId, c.m.spoke).addCap;
        if (addCap != hub.MAX_ALLOWED_SPOKE_CAP()) {
            uint256 room = addCap * 10 ** uint256(c.m.decimals);
            if (!RiskModuleMath.fits(hub.getAddedAssets(c.m.hubAssetId), c.units, room)) revert HubAddCapReached();
        }
        IAaveV4Spoke sp = IAaveV4Spoke(c.m.spoke);
        // Only the collateral flag is used; the borrowing flag is not.
        // forge-lint: disable-next-line(unused-return)
        (bool collateral,) = sp.getUserReserveStatus(c.m.reserveId, c.proxy);
        if (collateral) return;
        uint256 limit = sp.MAX_USER_RESERVES_LIMIT();
        if (limit == type(uint16).max) return;
        uint256 count = sp.getReserveCount();
        uint256 used = 0;
        for (uint256 r = 0; r < count; ++r) {
            // forge-lint: disable-next-line(unused-return)
            (bool isCollateral,) = sp.getUserReserveStatus(r, c.proxy);
            if (isCollateral) ++used;
        }
        if (used >= limit) revert UserReservesLimit();
    }

    /// @dev SPEC-CAP-002 with the slice rule of REQ-RISK-022; returns the slice part.
    function _caps(
        Ctx memory c,
        PledgeCounters calldata k
    ) internal view returns (uint256 sliceUsd) {
        bool marketOk;
        (sliceUsd, marketOk) =
            RiskModuleMath.split(c.charge, k.regularUsed, _store().marketUsdCap(c.marketId), c.eligible);
        if (!marketOk) revert CapExceeded(CAP_MARKET);
        if (sliceUsd > 0) {
            if (sliceUsd > c.restore) revert SliceNotAvailable();
            if (!RiskModuleMath.fits(k.sliceUsed, sliceUsd, _store().topUpSliceUsd(c.marketId))) {
                revert CapExceeded(CAP_SLICE);
            }
        }
        uint256 regular = c.charge - sliceUsd;
        address[] memory tokens = c.m.tokens;
        if (k.tokenUsed.length != tokens.length) revert CapExceeded(CAP_TOKEN);
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (!RiskModuleMath.fits(k.tokenUsed[i], regular, _store().tokenUsdCap(c.m.hub, tokens[i]))) {
                // One token over its cap refuses the whole pledge.
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert CapExceeded(CAP_TOKEN);
            }
        }
        if (!RiskModuleMath.fits(k.depositorUsed, regular, _store().depositorUsdCap(c.m.hub))) {
            revert CapExceeded(CAP_DEPOSITOR);
        }
    }

    /// @dev Pool-share cap (SPEC-CAP-005), market breaker without `ORACLE` and the rescue rule (REQ-RISK-066).
    function _exemption(
        Ctx memory c,
        PledgeCounters calldata k,
        bool requireRescue
    ) internal view returns (RiskModuleMath.Outcome o) {
        RiskModuleMath.Exemption memory x;
        x.requireRescue = requireRescue;
        uint256 cap = _store().poolShareMaxBpsOf(_poolKey(c.m));
        if (cap < NO_POOL_SHARE_CAP) {
            RiskStatus memory rs = IAmmIntegration(c.m.integration)
                .riskStatus(c.marketId, _store().getMarketParams(c.marketId).twapWindow);
            x.depthUnavailable = !rs.depthAvailable;
            x.capFail = rs.depthAvailable && RiskModuleMath.poolShareExceeds(k.poolUnits + c.units, cap, rs.depthUnits);
        }
        // Only the reasons decide the pledge; the reopening time is not used.
        // forge-lint: disable-next-line(unused-return)
        (uint32 brk,) = IRiskModuleBreakerLogic(_BREAKER).marketBreaker(c.marketId, true, k.poolUnits);
        // `ORACLE` is the price-state rule's own gate; `CONFIG_DRIFT` never stops a top-up (REQ-RISK-078).
        brk &= ~BreakerReasons.ORACLE;
        if (c.topUp) brk &= ~BreakerReasons.CONFIG_DRIFT;
        x.brk = brk;
        x.belowMinimum = c.pledgeUsd < c.minPledge;
        x.eligible = c.eligible;
        x.charge = c.charge;
        x.restore = c.restore;
        o = RiskModuleMath.exemption(x);
        if (o == RiskModuleMath.Outcome.BelowMinimum) revert BelowMinPledge(c.pledgeUsd, c.minPledge);
        if (o == RiskModuleMath.Outcome.NotRescue) revert NotRescueTopUp(c.hf, c.charge, c.restore);
        if (o == RiskModuleMath.Outcome.PoolShareUnavailable) revert PoolShareUnavailable();
        if (o == RiskModuleMath.Outcome.PoolShareExceeded) revert PoolShareExceeded();
        if (o == RiskModuleMath.Outcome.Breaker) revert BreakerTripped(c.marketId, x.brk);
    }
}
// forge-lint: disable-end(calls-loop)
