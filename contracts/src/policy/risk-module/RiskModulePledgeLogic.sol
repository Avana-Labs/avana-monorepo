// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title RiskModulePledgeLogic
/// @notice Body of `checkPledge`, the restore amount and the remaining-record minimum.
/// @dev Safe under STATICCALL: makes no call to Collateralization or the LPVault.
// View calls in loops over the market's pool tokens and the Spoke's reserves, bounded by listings.

import {RiskStatus} from "../../amm/types/AmmTypes.sol";
import {ICollateralization} from "../../custody/collateralization/ICollateralization.sol";
import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {DriftReason, Market} from "../../types/MarketTypes.sol";
import {PriceState} from "../../types/OracleTypes.sol";
import {PledgeCounters, PledgePreview} from "../../types/PositionTypes.sol";
import {IAaveAdapter} from "../aave-adapter/IAaveAdapter.sol";
import {BreakerReasons} from "../market-registry/types/Breaker.sol";
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {IRiskModulePledgeLogic} from "./IRiskModulePledgeLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {PledgeCharge, RiskModuleImmutables} from "./types/RiskModuleTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// forge-lint: disable-start(calls-loop)
contract RiskModulePledgeLogic is RiskModuleBase, IRiskModulePledgeLogic {
    // forge-lint: disable-start(calls-loop)
    struct Ctx {
        Market m;
        uint256 marketId;
        address proxy;
        uint128 units;
        bool topUp;
        uint256 hf;
        uint256 debtRay;
        uint256 minPledge;
        uint256 pledgeUsd;
        uint256 charge;
        bool eligible;
        uint256 restore;
        // The market's fresh price from the eligibility read, 0 when failed.
        uint256 fresh;
    }

    address internal immutable _DRIFT;
    address internal immutable _BREAKER;

    // `_requireLogic` checks each logic address, which rejects zero.
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        RiskModuleImmutables memory im,
        address drift,
        address breaker
    ) RiskModuleBase(im) {
        _requireLogic(drift, keccak256("RiskModuleDriftLogic"));
        _requireLogic(breaker, keccak256("RiskModuleBreakerLogic"));
        _DRIFT = drift;
        _BREAKER = breaker;
    }

    /// @inheritdoc IRiskModulePledgeLogic
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (PledgePreview memory p) {
        Market memory m = _market(marketId);
        address proxy = IAaveAdapter(_ADAPTER).proxyOf(depositor, marketId);
        if (proxy == address(0)) proxy = IAaveAdapter(_ADAPTER).predictProxy(depositor, marketId);
        ICollateralization coll = ICollateralization(_COLLATERALIZATION);
        PledgeCounters memory k = coll.getCounters(m.vaultToken, depositor);
        k.accountRecords = coll.getOpenRecordCount(proxy, m.vaultToken);
        p.isTopUp = _accountData(m.spoke, proxy).borrowCount > 0;
        _rooms(p, m, marketId, k);
        uint128 units;
        (p.reason, units) = _position(m, marketId, depositor, positionKey);
        if (p.reason != bytes4(0)) return p;
        p.usdCharge =
            RiskModuleMath.usdCharge(units, _capPrice(m.lpOracle), _store().stressFloorUsd(marketId), m.decimals);
        uint256 cap =
            Math.min(ILPVault(m.integration).maxRecordsPerAccountMarket(), AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET);
        if (k.accountRecords >= cap) {
            p.reason = TooManyRecords.selector;
            return p;
        }
        try IRiskModulePledgeLogic(address(this))
            .checkPledge(depositor, proxy, marketId, m.integrationId, positionKey, units, k, false) returns (
            PledgeCharge memory ch
        ) {
            p.eligible = true;
            p.usdCharge = ch.usdCharge;
            p.sliceUsd = ch.sliceUsd;
        } catch (bytes memory err) {
            // The revert selector is the first four bytes of the revert data.
            // forge-lint: disable-next-line(unsafe-typecast)
            p.reason = bytes4(err);
        }
    }

    function _position(
        Market memory m,
        uint256 marketId,
        address depositor,
        bytes32 positionKey
    ) internal view returns (bytes4 reason, uint128 units) {
        ILPVault amm = ILPVault(m.integration);
        if (amm.positionOwner(positionKey) != depositor) return (NotPositionOwner.selector, 0);
        try amm.validatePosition(marketId, depositor, positionKey) returns (uint128 u) {
            units = u;
        } catch (bytes memory err) {
            // The revert selector is the first four bytes of the revert data.
            // forge-lint: disable-next-line(unsafe-typecast)
            reason = err.length < 4 ? PoolMismatch.selector : bytes4(err);
        }
    }

    function _rooms(
        PledgePreview memory p,
        Market memory m,
        uint256 marketId,
        PledgeCounters memory k
    ) internal view {
        IParameterStore ps = _store();
        p.marketRoomUsd = _room(ps.marketUsdCap(marketId), k.regularUsed);
        p.sliceRoomUsd = _room(ps.topUpSliceUsd(marketId), k.sliceUsed);
        p.tokenRoomUsd = new uint256[](m.tokens.length);
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            uint256 used = i < k.tokenUsed.length ? k.tokenUsed[i] : 0;
            p.tokenRoomUsd[i] = _room(ps.tokenUsdCap(m.hub, m.tokens[i]), used);
        }
        uint256 open = k.accountRecords;
        uint256 max = AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET;
        p.recordRoom = open < max ? max - open : 0;
        uint256 cap = ps.poolShareMaxBpsOf(_poolKey(m));
        if (cap >= NO_POOL_SHARE_CAP) {
            p.poolShareRoomUnits = type(uint256).max;
        } else {
            RiskStatus memory rs = ILPVault(m.integration).riskStatus(marketId, ps.getMarketParams(marketId).twapWindow);
            if (rs.depthAvailable) {
                p.poolShareRoomUnits = RiskModuleMath.poolShareRoom(k.poolUnits, cap, rs.depthUnits);
            }
        }
    }

    function _room(
        uint256 cap,
        uint256 used
    ) internal pure returns (uint256 room) {
        room = cap > used ? cap - used : 0;
    }

    function _mulDivUp(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        return Math.mulDiv(a, b, c, Math.Rounding.Ceil);
    }
    // forge-lint: disable-end(calls-loop)

    bytes32 internal constant CAP_MARKET = "MARKET";
    bytes32 internal constant CAP_SLICE = "SLICE";
    bytes32 internal constant CAP_TOKEN = "TOKEN";

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
        uint256 usd = RiskModuleMath.pledgeUsd(remainingUnits, _served(m.lpOracle), m.decimals);
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
        ILPOracle.PriceStatus memory st = ILPOracle(c.m.lpOracle).getPriceStatus();
        if (!st.liquidationFresh) revert PriceNotAccepted(uint8(PriceState.Cached));
        // `getPriceStatus` serves at least 1.
        // forge-lint: disable-next-line(unsafe-typecast)
        c.fresh = uint256(st.answer);
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
        uint256 accepted = _served(c.m.lpOracle);
        uint256 price8 = RiskModuleMath.bookingPrice(accepted, c.fresh);
        // Caps at the fresh price, the minimum at the lower of the two.
        uint256 capPrice8 = RiskModuleMath.capPrice(accepted, c.fresh);
        uint256 floorUsd = _store().stressFloorUsd(c.marketId);
        c.minPledge = _store().minPledgeUsd(c.marketId);
        c.pledgeUsd = RiskModuleMath.pledgeUsd(c.units, price8, c.m.decimals);
        c.charge = RiskModuleMath.usdCharge(c.units, capPrice8, floorUsd, c.m.decimals);
        uint256 rescueMin = RiskModuleMath.rescueMinimum(c.minPledge);
        if (c.pledgeUsd < rescueMin) revert BelowMinPledge(c.pledgeUsd, rescueMin);
        c.eligible = c.topUp && c.hf < RiskModuleMath.RESCUE_HEALTH_FACTOR;
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
            RiskStatus memory rs =
                ILPVault(c.m.integration).riskStatus(c.marketId, _store().getMarketParams(c.marketId).twapWindow);
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
