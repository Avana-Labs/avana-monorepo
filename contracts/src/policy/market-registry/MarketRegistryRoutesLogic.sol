// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../liquidation/settlement-routes/ISettlementRoute.sol";
import {Market} from "../../types/Market.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {IssuerProbe} from "./types/IssuerProbe.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {TokenDef} from "./types/TokenDef.sol";

/// @title MarketRegistryRoutesLogic
/// @notice Bodies of the swap-route writes (`setRoute` normal delay, `disableRoute` and `restoreRoute` short delay)
/// and of the standby switch (`useStandbyRoute`, `cancelStandbySwitch`, `restorePriceRoute`).
/// @dev Reached only by delegatecall from the MarketRegistry, which checks the caller first; see
/// `IMarketRegistryLogic`. Every external call is a view. A standby switch changes only the registry's record and
/// `priceRouteVersion`; each oracle sees the new routes on its next read (REQ-CONFIG-003).
/// @custom:spec REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, REQ-CONFIG-061, REQ-CONFIG-062, REQ-MREG-011, REQ-MREG-012, REQ-MREG-013, REQ-MREG-028, Q-248, Q-379
// Each function carries the body of a selector declared in an IMarketRegistry piece that the MarketRegistry itself
// implements; this contract inherits only `IMarketRegistryRoutes`, the one piece it serves in full.
// solhint-disable comprehensive-interface
// Every external call made here is a view (STATICCALL), so none can re-enter the registry or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistryRoutesLogic is MarketRegistryStorage, IMarketRegistryRoutes, IMarketRegistryLogic {
    /// @notice Fixes the implementation immutables; they must equal the MarketRegistry's.
    /// @param im The per-chain Avana addresses.
    /// @custom:spec REQ-CONFIG-005
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    /// @custom:spec REQ-CONFIG-005
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryRoutesLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IMarketRegistryRoutes
    /// @dev Body of `setRoute`.
    /// @custom:spec REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, Q-379
    function setRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external override {
        _onlyDelegated();
        Layout storage l = _s();
        _checkRoute(marketId, token, debtAsset, kind, route);
        bytes32 key = _slotKey(marketId, token, debtAsset, kind);
        l.routes[key] = RouteRecord({route: route, active: true});
        l.approvedBefore[key][route] = true;
        l.knownRoute[route] = true;
        emit RouteSet(marketId, token, debtAsset, kind, route);
    }

    /// @inheritdoc IMarketRegistryRoutes
    /// @dev Body of `disableRoute`.
    /// @custom:spec REQ-CONFIG-061, REQ-MREG-012
    function disableRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external override {
        _onlyDelegated();
        RouteRecord storage r = _s().routes[_slotKey(marketId, token, debtAsset, kind)];
        if (r.route == address(0)) revert InvalidRoute();
        r.active = false;
        emit RouteDisabled(marketId, token, debtAsset, kind, msg.sender);
    }

    /// @inheritdoc IMarketRegistryRoutes
    /// @dev Body of `restoreRoute`.
    /// @custom:spec REQ-CONFIG-062, REQ-MREG-012, Q-151
    function restoreRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) external override {
        _onlyDelegated();
        Layout storage l = _s();
        bytes32 key = _slotKey(marketId, token, debtAsset, kind);
        if (!l.approvedBefore[key][route]) revert NotPreviouslyApproved();
        _checkRoute(marketId, token, debtAsset, kind, route);
        l.routes[key] = RouteRecord({route: route, active: true});
        emit RouteRestored(marketId, token, debtAsset, kind, route);
    }

    /// @notice Body of `useStandbyRoute`.
    /// @custom:spec REQ-MREG-028, REQ-CONFIG-021, Q-248, Q-262
    function useStandbyRoute(
        address token,
        RouteSlot slot
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (slot != RouteSlot.Primary && slot != RouteSlot.Alternate) revert InvalidRouteSlot();
        TokenDef storage t = l.tokens[token];
        if (!t.listed) revert TokenNotListed(token);
        if (t.standbyRoute.length == 0) revert NoStandbyRoute(token);
        if (t.replacedSlot != RouteSlot.None) revert StandbyAlreadyActive(token);
        address[] memory standby = t.standbyRoute;
        bytes32 bad = _routeLegsCheck(standby);
        if (bad != 0) revert ListingCheckFailed(bad);
        // The router refused a guardian while a DAO cancel's lock holds; a switch that runs ends any lock.
        delete l.standbyCancelledAt[token];
        t.replacedSlot = slot;
        ++l.priceRouteVersion[token];
        emit StandbyRouteActivated(token, slot, msg.sender);
    }

    /// @notice Body of `cancelStandbySwitch`.
    /// @custom:spec REQ-MREG-028, Q-248
    function cancelStandbySwitch(
        address token
    ) external {
        _onlyDelegated();
        _clearStandby(token);
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        _s().standbyCancelledAt[token] = uint64(block.timestamp);
        emit StandbySwitchCancelled(token, msg.sender);
    }

    /// @notice Body of `restorePriceRoute`.
    /// @custom:spec REQ-MREG-028, Q-248
    function restorePriceRoute(
        address token
    ) external {
        _onlyDelegated();
        _clearStandby(token);
        emit PriceRouteRestored(token);
    }

    /// @dev Returns the replaced slot to its recorded route; `StandbyNotActive` when none is replaced.
    function _clearStandby(
        address token
    ) private {
        Layout storage l = _s();
        TokenDef storage t = l.tokens[token];
        if (t.replacedSlot == RouteSlot.None) revert StandbyNotActive(token);
        t.replacedSlot = RouteSlot.None;
        ++l.priceRouteVersion[token];
    }

    /// @dev The route checks of REQ-CONFIG-039, REQ-CONFIG-040 and REQ-CONFIG-060 for one slot, and REQ-ROUTE-008's
    /// listing check: no token the route pays into a contract requiring the exact amount (`exactAmountInputs`) is a
    /// listed token whose issuer can switch on a transfer fee (`IssuerProbe.UsdtFeeRate`).
    function _checkRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) private view {
        Market storage m = _checkSlot(marketId, token, debtAsset, kind, route);
        ISettlementRoute r = ISettlementRoute(route);
        if (
            r.tokenIn() != token || r.tokenOut() != debtAsset || r.LP_VAULT_SWAP() != _LP_VAULT_SWAP
                || !r.supportsTokenClass(uint8(_s().spokes[m.spoke].riskTier))
        ) revert InvalidRoute();
        address[] memory deps = r.dependencies();
        if (_contains(deps, m.pool) || _contains(deps, m.integration)) revert InvalidRoute();
        if (m.pool == address(0) && _dependsOnIntegration(m.integrationId, deps)) revert InvalidRoute();
        if (kind == _BACKUP && _touchesPegModule(m.tokens, deps)) revert InvalidRoute();
        address[] memory exact = r.exactAmountInputs();
        bool feeSwitch = false;
        for (uint256 i = 0; i < exact.length && !feeSwitch; ++i) {
            feeSwitch = _s().tokens[exact[i]].issuerProbe == IssuerProbe.UsdtFeeRate;
        }
        // A transfer fee switched on would revert that leg, possibly in both slots at once (REQ-ROUTE-003, REQ-ROUTE-008).
        if (feeSwitch) revert InvalidRoute();
        address other = _s().routes[_slotKey(marketId, token, debtAsset, kind == _PRIMARY ? _BACKUP : _PRIMARY)].route;
        if (other != address(0) && (other == route || _shareFeed(deps, ISettlementRoute(other).dependencies()))) {
            revert InvalidRoute();
        }
    }

    /// @dev The slot's keys: a market that is neither unknown, Cancelled nor Closed, one of its pool tokens, a debt
    /// asset of its Spoke (an enabled reserve's asset, a listed token, or an asset with a Coverage Spoke on the home
    /// Hub, so routes can be set in the batch that enables the reserve), the kind and a non-zero route.
    function _checkSlot(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route
    ) private view returns (Market storage m) {
        Layout storage l = _s();
        m = l.markets[marketId];
        MarketStatus st = m.status;
        if (st == MarketStatus.None || st == MarketStatus.Cancelled || st == MarketStatus.Closed) {
            revert UnknownMarket(marketId);
        }
        if (!_isPoolToken(m.tokens, token)) revert TokenNotListed(token);
        if (
            !_isDebtAssetOf(m.spoke, debtAsset) && !l.tokens[debtAsset].listed
                && l.coverageSpokeOf[l.spokes[m.spoke].hub][debtAsset] == address(0)
        ) revert TokenNotListed(debtAsset);
        if (kind > _BACKUP || route == address(0) || token == debtAsset) revert InvalidRoute();
    }

    /// @dev REQ-CONFIG-040 for a market keyed by pool identifier: its pool lives inside the AMM protocol's singleton, and
    /// a dependency list of addresses cannot show which pool of the singleton a route trades, so a route that names any
    /// AMM contract recorded for the integration is refused; with none recorded, every route is refused (fail closed).
    function _dependsOnIntegration(
        uint32 integrationId,
        address[] memory deps
    ) private view returns (bool) {
        address[] storage amm = _s().integrationContracts[integrationId];
        if (amm.length == 0) return true;
        for (uint256 i = 0; i < amm.length; ++i) {
            if (_contains(deps, amm[i])) return true;
        }
        return false;
    }

    /// @dev True when any dependency is the peg module of one of the market's pool tokens.
    function _touchesPegModule(
        address[] storage tokens,
        address[] memory deps
    ) private view returns (bool) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            address peg = _s().tokens[tokens[i]].pegModule;
            if (peg != address(0) && _contains(deps, peg)) return true;
        }
        return false;
    }

    /// @dev True when `list` holds `a` (a zero `a` never matches).
    function _contains(
        address[] memory list,
        address a
    ) private pure returns (bool) {
        if (a == address(0)) return false;
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

    /// @dev True when `token` is one of the market's pool tokens.
    function _isPoolToken(
        address[] storage tokens,
        address token
    ) private view returns (bool) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            if (tokens[i] == token) return true;
        }
        return false;
    }
}
