// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwap} from "../../liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ChainlinkPrice} from "../../oracle/ChainlinkPrice.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {LPPriceMath} from "../../oracle/LPPriceMath.sol";
import {AccountGateStatus, MarketGateStatus} from "../../types/MarketTypes.sol";
import {PriceState} from "../../types/OracleTypes.sol";
import {DebtReserveDef, MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IRiskModuleBorrowLogic} from "./IRiskModuleBorrowLogic.sol";
import {IRiskModuleBreakerLogic} from "./IRiskModuleBreakerLogic.sol";
import {IRiskModuleDriftLogic} from "./IRiskModuleDriftLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {IRiskModuleStatusLogic} from "./IRiskModuleStatusLogic.sol";
import {RiskModuleBorrowScope} from "./RiskModuleBorrowScope.sol";
import {RiskModuleImmutables} from "./types/RiskModuleTypes.sol";

/// @title RiskModuleStatusLogic
/// @notice Body of `getAccountGateStatus`: every borrow-side gate outcome of an account, without poking.
/// @dev Reserve fields hold `type(uint256).max` when no reserve matches.
// View calls in loops over the account's reserves and legs, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleStatusLogic is RiskModuleBorrowScope, IRiskModuleStatusLogic {
    address internal immutable _BORROW;

    // `_requireLogic` checks each logic address, which rejects zero.
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
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleStatusLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleStatusLogic
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
        st.noApprovedKeeper = ILPVaultSwap(_LP_VAULT_SWAP).activeKeeperCount() == 0;
        (st.healthFactor, st.healthFactorExcludingRescue) = IRiskModuleBorrowLogic(_BORROW).healthFactors(proxy);
        uint256[] memory one = new uint256[](1);
        one[0] = marketId;
        (st.driftMarketId, st.driftReason) = IRiskModuleDriftLogic(_DRIFT).driftOf(spoke, one, proxy);
        st.markets = new MarketGateStatus[](1);
        st.markets[0] = _marketStatus(s, st.noApprovedKeeper);
        _debtStatus(st, s);
        st.borrowAllowed = _passes(proxy, true);
        st.withdrawWithDebtAllowed = _passes(proxy, false);
    }

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

    function _marketStatus(
        Scope memory s,
        bool noKeeper
    ) internal view returns (MarketGateStatus memory g) {
        g.marketId = s.marketId;
        g.reserveId = s.m.reserveId;
        ILPOracle.PriceStatus memory st = ILPOracle(s.m.lpOracle).getPriceStatus();
        g.priceState = st.liquidationFresh ? PriceState.Live : PriceState.Cached;
        g.oldestFeedAge = LPPriceMath.age(st.updatedAt);
        g.feedTooOld = !st.borrowFresh;
        g.offboarding = s.m.status == MarketStatus.Offboarding;
        IAaveV4Spoke.ReserveConfig memory rc = IAaveV4Spoke(s.spoke).getReserveConfig(s.m.reserveId);
        g.aaveReservePaused = rc.paused;
        g.aaveReserveFrozen = rc.frozen;
        g.hubSharesEqualAssets = IRiskModuleDriftLogic(_DRIFT).isHubSharesEqualAssets(s.marketId);
        (g.noSettlementPath,) = _routeHalt(s);
        g.liquidationHalted = noKeeper || g.noSettlementPath;
        g.breakerReasons = IRiskModuleBreakerLogic(_BREAKER).marketConditions(s.marketId);
    }

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
                uint32 reasons = IRiskModuleBreakerLogic(_BREAKER).debtConditions(s.spoke, r);
                if (reasons != 0) (st.breakerDebtReserveId, st.breakerDebtReasons) = (r, reasons);
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
        return !ChainlinkPrice.read(source, address(_store())).borrowFresh;
    }

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
