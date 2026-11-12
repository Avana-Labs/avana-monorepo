// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {ISettlementRoute} from "../../liquidation/settlement-routes/ISettlementRoute.sol";
import {Market} from "../../types/Market.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {IMarketRegistryApprovals} from "./IMarketRegistryApprovals.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {MarketRegistryRouteChecks} from "./MarketRegistryRouteChecks.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {IssuerProbes} from "./types/IssuerProbe.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {TokenDef} from "./types/TokenDef.sol";

/// @title MarketRegistryRoutesLogic
/// @notice Bodies of the swap-route writes (`setRoute` normal delay, `disableRoute` and `restoreRoute` short delay),
/// of the AMM integration contract record (`recordIntegrationContracts`, `finalizeIntegrationContracts`, normal delay)
/// and of the standby switch (`useStandbyRoute`, `cancelStandbySwitch`, `restorePriceRoute`).
/// @dev Reached only by delegatecall from the MarketRegistry, which checks the caller first; see
/// `IMarketRegistryLogic`. Every external call is a view. A standby switch changes only the registry's record and
/// `priceRouteVersion`; each oracle sees the new routes on its next read (REQ-CONFIG-003).
/// @custom:spec REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, REQ-CONFIG-061, REQ-CONFIG-062, REQ-MREG-011, REQ-MREG-012, REQ-MREG-013, REQ-MREG-020, REQ-MREG-028, REQ-MREG-035, REQ-ROUTE-002, REQ-ROUTE-005, REQ-ROUTE-019, Q-248, Q-341, Q-342, Q-379
// Each function carries the body of a selector declared in an IMarketRegistry piece that the MarketRegistry itself
// implements; this contract inherits only `IMarketRegistryRoutes`, the one piece it serves in full.
// solhint-disable comprehensive-interface
// Every external call made here is a view (STATICCALL), so none can re-enter the registry or reorder its events.
// forge-lint: disable-start(reentrancy-events)
// An addition to a finalized integration record reads `dependencies()` of each route set for the integration's
// markets: bounded by MAX_MARKET_COUNT markets and the slots governance set, views only, and a reverting route is
// disabled rather than reverting the governance call.
// forge-lint: disable-start(calls-loop)
contract MarketRegistryRoutesLogic is MarketRegistryRouteChecks, IMarketRegistryRoutes, IMarketRegistryLogic {
    /// @dev Most AMM contracts one `recordIntegrationContracts` call records (Slipstream's four generations need 8).
    uint256 internal constant _MAX_INTEGRATION_CONTRACTS = 16;

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
    /// @custom:spec REQ-CONFIG-039, REQ-CONFIG-040, REQ-CONFIG-059, REQ-CONFIG-060, REQ-ROUTE-002, REQ-ROUTE-005, Q-341, Q-342, Q-379
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
        // REQ-MREG-035: the slot is listed once per market, so a later addition to the integration record re-checks it.
        bytes32 slotId = keccak256(abi.encode(marketId, token, debtAsset, kind));
        if (!l.routeSlotListed[slotId]) {
            l.routeSlotListed[slotId] = true;
            l.routeSlots[marketId].push(RouteSlotRef({token: token, debtAsset: debtAsset, kind: kind}));
        }
        emit RouteSet(marketId, token, debtAsset, kind, route);
    }

    /// @notice Body of `recordIntegrationContracts`.
    /// @custom:spec REQ-MREG-020, REQ-MREG-035, REQ-CONFIG-040
    function recordIntegrationContracts(
        uint32 integrationId,
        address[] calldata contracts
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        bytes32 recordKey = _integrationRecordKey(integrationId);
        IntegrationRecord storage rec = l.integrationRecords[integrationId];
        bytes32 stored = rec.key;
        address[] storage list = l.integrationContracts[integrationId];
        uint256 n = contracts.length;
        uint256 bad = n == 0 || n > _MAX_INTEGRATION_CONTRACTS || (stored != 0 && stored != recordKey) ? 1 : 0;
        // A bad entry ends the loop and reverts the whole call after it, so no partial record survives.
        for (uint256 i = 0; i < n && bad == 0; ++i) {
            address c = contracts[i];
            if (c == address(0) || c.code.length == 0 || _recorded(list, c)) {
                bad = 1;
            } else {
                list.push(c);
                l.knownIntegrationContract[c] = true;
            }
        }
        if (bad != 0) revert IMarketRegistryHubs.InvalidIntegration(integrationId);
        rec.key = recordKey;
        emit IMarketRegistryApprovals.IntegrationContractsRecorded(integrationId, recordKey, contracts);
        if (rec.finalized) _recheckRoutes(integrationId, contracts);
    }

    /// @notice Body of `finalizeIntegrationContracts`.
    /// @custom:spec REQ-MREG-035, REQ-CONFIG-040
    function finalizeIntegrationContracts(
        uint32 integrationId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        bytes32 recordKey = _integrationRecordKey(integrationId);
        uint256 count = l.integrationContracts[integrationId].length;
        IntegrationRecord storage rec = l.integrationRecords[integrationId];
        if (count == 0 || rec.finalized || rec.key != recordKey) {
            revert IMarketRegistryHubs.InvalidIntegration(integrationId);
        }
        rec.finalized = true;
        emit IMarketRegistryApprovals.IntegrationContractsFinalized(integrationId, recordKey, count);
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
    /// @custom:spec REQ-CONFIG-062, REQ-MREG-012, REQ-ROUTE-019, Q-151, Q-341, Q-342
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

    /// @dev The route checks of REQ-CONFIG-039, REQ-CONFIG-040 and REQ-CONFIG-060 for one slot, the route-type and
    /// GSM checks of REQ-ROUTE-002 and Q-341 and the ERC-777 check of Q-342 (`MarketRegistryRouteChecks`, run by
    /// `setRoute` and again by `restoreRoute`, REQ-ROUTE-019), and REQ-ROUTE-008's listing check: no token the route pays into a contract requiring the exact amount (`exactAmountInputs`) is a
    /// listed token whose issuer can switch on a transfer fee (a probe that reads `basisPointsRate()`: `UsdtFeeRate` or
    /// `UsdtFeeRateAndPaused`).
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
        if (_touchesMarketAmm(m, deps)) revert InvalidRoute();
        // REQ-ROUTE-002: the route type is admitted in the slot; a GSM route only as a live backup (Q-341).
        if (!_routeTypeAdmitted(route, kind, deps)) revert InvalidRoute();
        // Q-342: no token the route holds is an ERC-777 token.
        if (!_noErc777(token, debtAsset, r.intermediates())) revert InvalidRoute();
        if (kind == _BACKUP && _touchesPegModule(m.tokens, deps)) revert InvalidRoute();
        address[] memory exact = r.exactAmountInputs();
        bool feeSwitch = false;
        for (uint256 i = 0; i < exact.length && !feeSwitch; ++i) {
            feeSwitch = IssuerProbes.readsFeeRate(_s().tokens[exact[i]].issuerProbe);
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

    /// @dev REQ-CONFIG-040 and REQ-MREG-035: true when the market's integration has no finalized record that still
    /// matches it (no route is accepted then), or when `deps` names the market's own pool, its integration's LPVault
    /// or an AMM contract recorded for its integration.
    function _touchesMarketAmm(
        Market storage m,
        address[] memory deps
    ) private view returns (bool) {
        uint32 iid = m.integrationId;
        IntegrationRecord storage rec = _s().integrationRecords[iid];
        if (!rec.finalized || rec.key != _integrationRecordKey(iid)) return true;
        if (_contains(deps, m.pool) || _contains(deps, m.integration)) return true;
        address[] storage recorded = _s().integrationContracts[iid];
        for (uint256 i = 0; i < recorded.length; ++i) {
            if (_contains(deps, recorded[i])) return true;
        }
        return false;
    }

    /// @dev REQ-MREG-035: the key of an integration's record of AMM protocol contracts, from the chain, the LPVault's
    /// address and code hash (its version: an LPVault is immutable, so a new build is a new address and hash), its AMM
    /// protocol tag and its pool keying. A replacement integration has another key and needs its own record.
    /// `InvalidIntegration` for an unregistered integration.
    function _integrationRecordKey(
        uint32 integrationId
    ) private view returns (bytes32) {
        address lpVault = _s().integrationLpVault[integrationId];
        if (lpVault == address(0)) revert IMarketRegistryHubs.InvalidIntegration(integrationId);
        IAmmIntegration v = IAmmIntegration(lpVault);
        return
            keccak256(
                abi.encode(block.chainid, lpVault, lpVault.codehash, v.AMM_PROTOCOL(), v.capabilities().poolKeying)
            );
    }

    /// @dev REQ-MREG-035: after an addition to a finalized record, disables every active route of the integration's
    /// markets (not Cancelled or Closed) whose `dependencies()` names an added contract or cannot be read, so a newly
    /// protected address leaves no approved unsafe route usable. Each market's slots of its current registration are
    /// read through `routeEpoch`.
    function _recheckRoutes(
        uint32 integrationId,
        address[] calldata added
    ) private {
        Layout storage l = _s();
        uint256 count = l.marketCount;
        for (uint256 id = 1; id <= count; ++id) {
            if (l.markets[id].integrationId != integrationId || _keyFree(id)) continue;
            RouteSlotRef[] storage slots = l.routeSlots[id];
            for (uint256 j = 0; j < slots.length; ++j) {
                RouteSlotRef memory sl = slots[j];
                RouteRecord storage r = l.routes[_slotKey(id, sl.token, sl.debtAsset, sl.kind)];
                if (!r.active || !_routeNamesAny(r.route, added)) continue;
                r.active = false;
                emit RouteDisabled(id, sl.token, sl.debtAsset, sl.kind, msg.sender);
            }
        }
    }

    /// @dev True when the route's `dependencies()` names one of `added`, or cannot be read (fail closed).
    function _routeNamesAny(
        address route,
        address[] calldata added
    ) private view returns (bool) {
        try ISettlementRoute(route).dependencies() returns (address[] memory deps) {
            return _namesAny(deps, added);
        } catch {
            return true;
        }
    }

    /// @dev True when `deps` holds any address of `list`.
    function _namesAny(
        address[] memory deps,
        address[] memory list
    ) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (_contains(deps, list[i])) return true;
        }
        return false;
    }

    /// @dev True when `list` holds `a`.
    function _recorded(
        address[] storage list,
        address a
    ) private view returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return true;
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
// forge-lint: disable-end(calls-loop)
