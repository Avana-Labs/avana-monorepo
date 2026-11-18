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
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
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
/// @notice Body of `checkPledge`, the restore amount and the remaining-record minimum.
/// @dev Safe under STATICCALL: makes no call to Collateralization or the LPVault.
// View calls in loops over the market's pool tokens and the Spoke's reserves, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModulePledgeLogic is RiskModulePreview {
    bytes32 internal constant CAP_MARKET = "MARKET";
    bytes32 internal constant CAP_SLICE = "SLICE";
    bytes32 internal constant CAP_TOKEN = "TOKEN";

    constructor(
        RiskModuleImmutables memory im,
        address drift,
        address breaker
    ) RiskModulePreview(im, drift, breaker) {}

    /// @inheritdoc IRiskModuleLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModulePledgeLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModulePledgeLogic
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
    function usdToRestore(
        address proxy
    ) external view override returns (uint256 usd) {
        (address spoke, uint256 marketId) = _account(proxy);
        IAaveV4Spoke.UserAccountData memory a = _accountData(spoke, proxy);
        if (a.borrowCount == 0) return 0;
        usd = RiskModuleMath.usdToRestore(a.healthFactor, a.totalDebtValueRay, _latestCf(spoke, _market(marketId)));
    }

    /// @inheritdoc IRiskModulePledgeLogic
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view override {
        Market memory m = _market(marketId);
        uint256 usd = RiskModuleMath.pledgeUsd(remainingUnits, _accepted(m.lpOracle), m.decimals);
        uint256 minUsd = _store().minPledgeUsd(marketId);
        if (usd < minUsd) revert RecordBelowMinPledge(usd, minUsd);
    }

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
        // Not failed (Live or Drifting), so the fresh price is positive.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.fresh = pv.freshAnswer > 0 ? uint256(pv.freshAnswer) : 0;
        if (!c.topUp && pv.state == PriceState.Drifting && (pv.reasons & PRICE_DRIFTING_BITS) != PRICE_USD_BAND) {
            revert PriceNotAccepted(uint8(pv.state));
        }
        _reserveAvailable(c);
        if (!c.topUp) _newAccount(c);
    }

    function _reserveAvailable(
        Ctx memory c
    ) internal view {
        IAaveV4Spoke.ReserveConfig memory rc = IAaveV4Spoke(c.m.spoke).getReserveConfig(c.m.reserveId);
        if (rc.paused || rc.frozen) revert AaveReserveUnavailable();
        IAaveV4Hub.SpokeConfig memory sc = IAaveV4Hub(c.m.hub).getSpokeConfig(c.m.hubAssetId, c.m.spoke);
        if (!sc.active || sc.halted) revert HubSpokeUnavailable();
    }

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

    function _value(
        Ctx memory c
    ) internal view {
        uint256 accepted = _accepted(c.m.lpOracle);
        uint256 price8 = RiskModuleMath.bookingPrice(accepted, c.fresh);
        // Caps at the fresh price, the minimum at the lower of the two.
        uint256 capPrice8 = RiskModuleMath.capPrice(accepted, c.fresh);
        uint256 floorUsd = _store().stressFloorUsd(c.marketId);
        c.minPledge = _store().minPledgeUsd(c.marketId);
        c.pledgeUsd = RiskModuleMath.pledgeUsd(c.units, price8, c.m.decimals);
        c.charge = RiskModuleMath.usdCharge(c.units, capPrice8, floorUsd, c.m.decimals);
        uint256 rescueMin = RiskModuleMath.rescueMinimum(c.minPledge);
        if (c.pledgeUsd < rescueMin) revert BelowMinPledge(c.pledgeUsd, rescueMin);
        c.eligible = c.topUp && c.hf < RiskModuleConstants.RESCUE_HEALTH_FACTOR;
        if (c.eligible) {
            uint256 restore = RiskModuleMath.usdToRestore(c.hf, c.debtRay, _latestCf(c.m.spoke, c.m));
            c.restore = RiskModuleMath.restoreBooked(restore, capPrice8, floorUsd, _served(c.m.lpOracle));
        }
    }

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

    /// @dev Returns the slice part. The token test covers only the regular part, so a rescue top-up can use the slice.
    function _caps(
        Ctx memory c,
        PledgeCounters calldata k
    ) internal view returns (uint256 sliceUsd) {
        address[] memory tokens = c.m.tokens;
        if (k.tokenUsed.length != tokens.length) revert CapExceeded(CAP_TOKEN);
        // `split` with no regular use takes `room` as the regular room.
        bool marketOk;
        (sliceUsd, marketOk) = RiskModuleMath.split(c.charge, 0, _regularRoom(c, k, tokens), c.eligible);
        if (!marketOk) revert CapExceeded(CAP_MARKET);
        if (sliceUsd > 0) {
            if (sliceUsd > c.restore) revert SliceNotAvailable();
            if (!RiskModuleMath.fits(k.sliceUsed, sliceUsd, _store().topUpSliceUsd(c.marketId))) {
                revert CapExceeded(CAP_SLICE);
            }
        }
        uint256 regular = c.charge - sliceUsd;
        if (regular != 0) _tokenTest(c, k, tokens, regular);
    }

    /// @dev The market room; for an eligible top-up, the smallest of it and every token room.
    function _regularRoom(
        Ctx memory c,
        PledgeCounters calldata k,
        address[] memory tokens
    ) internal view returns (uint256 room) {
        uint256 marketCap = _store().marketUsdCap(c.marketId);
        room = marketCap > k.regularUsed ? marketCap - k.regularUsed : 0;
        if (!c.eligible) return room;
        for (uint256 i = 0; i < tokens.length; ++i) {
            uint256 tokenCap = _store().tokenUsdCap(c.m.hub, tokens[i]);
            uint256 tokenRoom = tokenCap > k.tokenUsed[i] ? tokenCap - k.tokenUsed[i] : 0;
            if (tokenRoom < room) room = tokenRoom;
        }
    }

    function _tokenTest(
        Ctx memory c,
        PledgeCounters calldata k,
        address[] memory tokens,
        uint256 regular
    ) internal view {
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (!RiskModuleMath.fits(k.tokenUsed[i], regular, _store().tokenUsdCap(c.m.hub, tokens[i]))) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert CapExceeded(CAP_TOKEN);
            }
        }
    }

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
        // `ORACLE` is the price-state rule's own gate; `CONFIG_DRIFT` never stops a top-up.
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
