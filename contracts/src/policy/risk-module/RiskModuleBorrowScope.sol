// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {DebtReserveDef, MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleImmutables} from "./types/RiskModuleTypes.sol";

/// @title RiskModuleBorrowScope
/// @notice The account scope of the borrow-side checks, read from the Spoke, and the swap-route halt.
/// @dev Every collateral reserve must map to the proxy's market; every debt reserve must match its definition.
// View calls in loops over the Spoke's reserves and the market's tokens, bounded by listings.
// forge-lint: disable-start(calls-loop)
abstract contract RiskModuleBorrowScope is RiskModuleBase {
    /// @dev No reserve borrowed (a withdraw-with-debt or a status read).
    uint256 internal constant NO_RESERVE = type(uint256).max;

    struct Scope {
        address proxy;
        address spoke;
        uint256 marketId;
        Market m;
        uint256 borrowed;
        uint256[] debt;
        DebtReserveDef[] defs;
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

    function _scope(
        address proxy,
        uint256 debtReserveId,
        bool borrow
    ) internal view returns (Scope memory s) {
        s.proxy = proxy;
        (s.spoke, s.marketId) = _account(proxy);
        if (!_registry().getSpoke(s.spoke).approved) revert UnknownSpoke(s.spoke);
        s.m = _market(s.marketId);
        if (s.m.spoke != s.spoke || (s.m.status != MarketStatus.Active && s.m.status != MarketStatus.Offboarding)) {
            revert UnknownCollateral(s.m.reserveId);
        }
        s.borrowed = borrow ? debtReserveId : NO_RESERVE;
        s.debt = _debtScope(s);
        uint256 n = s.debt.length;
        s.defs = new DebtReserveDef[](n);
        IAaveV4Spoke sp = IAaveV4Spoke(s.spoke);
        for (uint256 i = 0; i < n; ++i) {
            uint256 r = s.debt[i];
            if (!_registry().isApprovedDebtReserve(s.spoke, r)) {
                // One unapproved debt reserve refuses the whole action.
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert ConfigDrift(0, DriftReason.BorrowedUnapprovedReserve);
            }
            DebtReserveDef memory d = _registry().getDebtReserve(s.spoke, r);
            IAaveV4Spoke.Reserve memory res = sp.getReserve(r);
            if (
                res.underlying != d.asset || res.hub != d.fundingHub || res.assetId != d.hubAssetId
                    || res.decimals != d.decimals
            ) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert ConfigDrift(0, DriftReason.DebtReserveMismatch);
            }
            s.defs[i] = d;
        }
    }

    /// @dev Collateral mapping and the debt scope in reserve order, the borrowed reserve appended when not yet held.
    function _debtScope(
        Scope memory s
    ) internal view returns (uint256[] memory debt) {
        IAaveV4Spoke sp = IAaveV4Spoke(s.spoke);
        uint256 count = sp.getReserveCount();
        uint256[] memory buf = new uint256[](count + 1);
        uint256 n = 0;
        bool held = false;
        for (uint256 r = 0; r < count; ++r) {
            (bool collateral, bool borrowing) = sp.getUserReserveStatus(r, s.proxy);
            if (collateral && (r != s.m.reserveId || _registry().marketOfReserve(s.spoke, r) != s.marketId)) {
                // forge-lint: disable-next-line(require-revert-in-loop)
                revert UnknownCollateral(r);
            }
            if (borrowing) {
                buf[n++] = r;
                if (r == s.borrowed) held = true;
            }
        }
        if (s.borrowed != NO_RESERVE && !held) buf[n++] = s.borrowed;
        debt = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            debt[i] = buf[i];
        }
    }

    /// @dev The first debt reserve into whose asset some non-debt pool token has no usable swap route.
    function _routeHalt(
        Scope memory s
    ) internal view returns (bool halted, uint256 reserveId) {
        address[] memory tokens = s.m.tokens;
        for (uint256 i = 0; i < s.debt.length; ++i) {
            address asset = s.defs[i].asset;
            for (uint256 j = 0; j < tokens.length; ++j) {
                if (_isDebtAsset(s, tokens[j])) continue;
                // Only whether the route is usable matters here.
                // forge-lint: disable-next-line(unused-return)
                (, bool primary) = _registry().getRoute(s.marketId, tokens[j], asset, 0);
                if (primary) continue;
                // Only whether the route is usable matters here.
                // forge-lint: disable-next-line(unused-return)
                (, bool backup) = _registry().getRoute(s.marketId, tokens[j], asset, 1);
                if (!backup) return (true, s.debt[i]);
            }
        }
    }

    function _isDebtAsset(
        Scope memory s,
        address token
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < s.defs.length; ++i) {
            if (s.defs[i].asset == token) return true;
        }
        return false;
    }
}
// forge-lint: disable-end(calls-loop)
