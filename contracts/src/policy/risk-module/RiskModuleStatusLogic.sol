// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapViews} from "../../liquidation/lp-vault-swap/ILPVaultSwapViews.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {MarketGateStatus} from "../../types/MarketGateStatus.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {DebtReserveDef} from "../market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../market-registry/types/MarketStatus.sol";
import {IRiskModuleBorrowLogic} from "./IRiskModuleBorrowLogic.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {IRiskModuleStatusLogic} from "./IRiskModuleStatusLogic.sol";
import {RiskModuleBorrowScope} from "./RiskModuleBorrowScope.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";

/// @title RiskModuleStatusLogic
/// @notice Body of `getAccountGateStatus`: every borrow-side gate outcome of an account on the stored oracle state,
/// without poking (REQ-ADAPTER-038, REQ-RISK-060).
/// @dev `borrowAllowed` and `withdrawWithDebtAllowed` run the borrow logic's `gate`, the same code as the pre-checks
/// without the pokes, so a value read between pokes can differ from what the next call sees. Reserve fields hold
/// `type(uint256).max` when no reserve matches (reserve 0 is a valid identifier). Reading the pause state of the
/// market's Hub here is for the status only; no check reads it. The RiskModule turns a revert of this body into an
/// empty status, so the view never reverts.
/// @custom:spec REQ-ADAPTER-038, REQ-RISK-060
// View calls in loops over the account's reserves and legs, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleStatusLogic is RiskModuleBorrowScope, IRiskModuleStatusLogic {
    /// @dev The borrow logic, whose `gate` gives the two outcomes.
    address internal immutable _BORROW;

    /// @notice Fixes the implementation immutables and the drift, breaker and borrow logic.
    /// @param im The per-chain Avana addresses.
    /// @param drift The drift logic built with `im`.
    /// @param breaker The breaker logic built with `im`.
    /// @param borrowLogic The borrow logic built with `im`.
    /// @custom:spec REQ-RISK-002
    // `_requireLogic` checks each logic address, which rejects zero (REQ-RISK-002).
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        RiskModuleImmutables memory im,
        address drift,
        address breaker,
        address borrowLogic
    ) RiskModuleBorrowScope(im, drift, breaker) {
        _requireLogic(borrowLogic, keccak256("RiskModuleBorrowLogic"));
        _BORROW = borrowLogic;
    }

    /// @inheritdoc IRiskModuleLogic
    /// @custom:spec REQ-RISK-002
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleStatusLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleStatusLogic
    /// @custom:spec REQ-ADAPTER-038, REQ-RISK-060
    function getAccountGateStatus(
        address proxy
    ) external view override returns (AccountGateStatus memory st) {
        (address spoke, uint256 marketId) = _account(proxy);
        st.unknownCollateralReserveId = NO_RESERVE;
        st.unapprovedDebtReserveId = NO_RESERVE;
        st.pausedDebtReserveId = NO_RESERVE;
        st.staleDebtReserveId = NO_RESERVE;
        st.haltedDebtReserveId = NO_RESERVE;
        st.breakerDebtReserveId = NO_RESERVE;
        st.spokeApproved = _registry().getSpoke(spoke).approved;
        Scope memory s;
        s.proxy = proxy;
        s.spoke = spoke;
        s.marketId = marketId;
        s.m = _market(marketId);
        s.borrowed = NO_RESERVE;
        _accountReserves(st, s);
        st.pauseState = _registry().pauseState(s.m.hub);
        st.pauseReason = _registry().pauseReason(s.m.hub);
        st.noApprovedKeeper = ILPVaultSwapViews(_LP_VAULT_SWAP).activeKeeperCount() == 0;
        st.hardHealthFloor = _store().hardHealthFloor(marketId);
        (st.healthFactor, st.healthFactorExcludingRescue) = IRiskModuleBorrowLogic(_BORROW).healthFactors(proxy);
        uint256[] memory one = new uint256[](1);
        one[0] = marketId;
        (st.driftMarketId, st.driftReason) = IRiskModuleDriftLogic(_DRIFT).driftOf(spoke, one, proxy);
        st.markets = new MarketGateStatus[](1);
        st.markets[0] = _marketStatus(s, st.noApprovedKeeper);
        _debtStatus(st, s);
        st.borrowAllowed = st.pauseState == PauseState.None && _passes(proxy, true);
        st.withdrawWithDebtAllowed = st.pauseState != PauseState.Paused && _passes(proxy, false);
    }

    /// @dev Collateral reserves that map to no market of the account, and the debt reserves the Spoke reports.
    function _accountReserves(
        AccountGateStatus memory st,
        Scope memory s
    ) internal view {
        IAaveV4Spoke sp = IAaveV4Spoke(s.spoke);
        uint256 count = sp.getReserveCount();
        uint256[] memory buf = new uint256[](count);
        uint256 n = 0;
        for (uint256 r = 0; r < count; ++r) {
            (bool collateral, bool borrowing) = sp.getUserReserveStatus(r, s.proxy);
            if (collateral && st.unknownCollateralReserveId == NO_RESERVE) {
                bool mapped = r == s.m.reserveId && _registry().marketOfReserve(s.spoke, r) == s.marketId
                    && (s.m.status == MarketStatus.Active || s.m.status == MarketStatus.Offboarding);
                if (!mapped) st.unknownCollateralReserveId = r;
            }
            if (borrowing) buf[n++] = r;
        }
        s.debt = new uint256[](n);
        s.defs = new DebtReserveDef[](n);
        for (uint256 i = 0; i < n; ++i) {
            s.debt[i] = buf[i];
            s.defs[i] = _registry().getDebtReserve(s.spoke, buf[i]);
        }
    }

    /// @dev Per-market outcome of the account's market.
    function _marketStatus(
        Scope memory s,
        bool noKeeper
    ) internal view returns (MarketGateStatus memory g) {
        g.marketId = s.marketId;
        g.reserveId = s.m.reserveId;
        PriceStateView memory pv = ILPOracle(s.m.lpOracle).getPriceState();
        g.priceState = pv.state;
        for (uint256 i = 0; i < pv.tokens.length; ++i) {
            for (uint256 j = 0; j < 2; ++j) {
                address feed = pv.tokens[i].legFeeds[j];
                if (feed == address(0)) continue;
                uint256 at = pv.tokens[i].legUpdatedAt[j];
                uint256 age = at > block.timestamp ? 0 : block.timestamp - at;
                if (age > g.oldestFeedAge) g.oldestFeedAge = age;
                if (at > block.timestamp || age > _store().borrowPriceMaxAge(feed)) g.feedTooOld = true;
            }
        }
        g.offboarding = s.m.status == MarketStatus.Offboarding;
        IAaveV4Spoke.ReserveConfig memory rc = IAaveV4Spoke(s.spoke).getReserveConfig(s.m.reserveId);
        g.aaveReservePaused = rc.paused;
        g.aaveReserveFrozen = rc.frozen;
        g.hubSharesEqualAssets = IRiskModuleDriftLogic(_DRIFT).isHubSharesEqualAssets(s.marketId);
        (g.noSettlementPath,) = _routeHalt(s);
        g.liquidationHalted = noKeeper || g.noSettlementPath;
        (g.breakerReasons, g.breakerLatchedUntil) =
            IRiskModuleBreakerLogic(_BREAKER).marketBreaker(s.marketId, false, 0);
    }

    /// @dev First unapproved, paused, stale, route-halted and breaker-tripped debt reserve of the account.
    function _debtStatus(
        AccountGateStatus memory st,
        Scope memory s
    ) internal view {
        (bool halted, uint256 haltedReserve) = _routeHalt(s);
        if (halted) st.haltedDebtReserveId = haltedReserve;
        IAaveV4Spoke sp = IAaveV4Spoke(s.spoke);
        address oracle = sp.ORACLE();
        for (uint256 i = 0; i < s.debt.length; ++i) {
            uint256 r = s.debt[i];
            if (!s.defs[i].approved) {
                if (st.unapprovedDebtReserveId == NO_RESERVE) st.unapprovedDebtReserveId = r;
                continue;
            }
            if (sp.getReserveConfig(r).paused && st.pausedDebtReserveId == NO_RESERVE) st.pausedDebtReserveId = r;
            if (st.staleDebtReserveId == NO_RESERVE && _stale(oracle, r, i, s)) st.staleDebtReserveId = r;
            if (st.breakerDebtReserveId == NO_RESERVE) {
                // The status reports the reasons; the reopening time is not used.
                // forge-lint: disable-next-line(unused-return)
                (uint32 reasons,) = IRiskModuleBreakerLogic(_BREAKER).debtBreaker(s.spoke, r);
                if (reasons != 0) (st.breakerDebtReserveId, st.debtBreakerReasons) = (r, reasons);
            }
        }
    }

    /// @dev The debt reserve's source differs from the recorded one, or its DebtOracle fails the borrow gate.
    function _stale(
        address oracle,
        uint256 r,
        uint256 i,
        Scope memory s
    ) internal view returns (bool) {
        address source = IAaveV4Oracle(oracle).getReserveSource(r);
        if (source != s.defs[i].priceSource) return true;
        if (s.defs[i].fixedPrice) return false;
        return !IDebtOracle(source).getPriceState().borrowAllowed;
    }

    /// @dev Whether the borrow logic's gate passes now.
    function _passes(
        address proxy,
        bool borrow
    ) internal view returns (bool ok) {
        try IRiskModuleBorrowLogic(_BORROW).gate(proxy, NO_RESERVE, borrow) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}
// forge-lint: disable-end(calls-loop)
