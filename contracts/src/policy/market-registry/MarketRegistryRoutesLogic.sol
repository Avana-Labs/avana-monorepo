// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {ISettlementRoute} from "../../liquidation/settlement-routes/ISettlementRoute.sol";
import {Market} from "../../types/MarketTypes.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {MarketRegistryRouteChecks} from "./MarketRegistryRouteChecks.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {IssuerProbes} from "./types/IssuerProbe.sol";
import {MarketRegistryImmutables, MarketStatus} from "./types/MarketRegistryTypes.sol";

/// @title MarketRegistryRoutesLogic
/// @notice Bodies of the swap-route writes and the AMM integration contract record.
/// @dev Runs only by delegatecall from the MarketRegistry, which checks the caller first.
// Bodies of IMarketRegistry selectors; inherits only `IMarketRegistryRoutes`, the one piece it serves in full.
// solhint-disable comprehensive-interface
// Every external call here is a view, so none can re-enter the registry.
// forge-lint: disable-start(reentrancy-events)
// Route re-checks read `dependencies()` per slot: views only, bounded by MAX_MARKET_COUNT and the slots set.
// forge-lint: disable-start(calls-loop)
contract MarketRegistryRoutesLogic is MarketRegistryRouteChecks, IMarketRegistryRoutes, IMarketRegistryLogic {
    /// @dev Most AMM contracts one `recordIntegrationContracts` call records.
    uint256 internal constant _MAX_INTEGRATION_CONTRACTS = 16;

    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryRoutesLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IMarketRegistryRoutes
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
        // A replaced route loses its approval, so `restoreRoute` cannot bring it back.
        address replaced = l.routes[key].route;
        if (replaced != address(0) && replaced != route) delete l.approvedBefore[key][replaced];
        l.routes[key] = RouteRecord({route: route, active: true});
        l.approvedBefore[key][route] = true;
        // List the slot once per market, so a later integration-record addition re-checks it.
        bytes32 slotId = keccak256(abi.encode(marketId, token, debtAsset, kind));
        if (!l.routeSlotListed[slotId]) {
            l.routeSlotListed[slotId] = true;
            l.routeSlots[marketId].push(RouteSlotRef({token: token, debtAsset: debtAsset, kind: kind}));
        }
        emit RouteSet(marketId, token, debtAsset, kind, route);
    }

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
            }
        }
        if (bad != 0) revert IMarketRegistry.InvalidIntegration(integrationId);
        rec.key = recordKey;
        emit IMarketRegistry.IntegrationContractsRecorded(integrationId, recordKey, contracts);
        if (rec.finalized) _recheckRoutes(integrationId, contracts);
    }

    function finalizeIntegrationContracts(
        uint32 integrationId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        bytes32 recordKey = _integrationRecordKey(integrationId);
        uint256 count = l.integrationContracts[integrationId].length;
        IntegrationRecord storage rec = l.integrationRecords[integrationId];
        if (count == 0 || rec.finalized || rec.key != recordKey) {
            revert IMarketRegistry.InvalidIntegration(integrationId);
        }
        rec.finalized = true;
        emit IMarketRegistry.IntegrationContractsFinalized(integrationId, recordKey, count);
    }

    /// @inheritdoc IMarketRegistryRoutes
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
        if (!_routeTypeAdmitted(route, kind, deps)) revert InvalidRoute();
        if (!_noErc777(token, debtAsset, r.intermediates())) revert InvalidRoute();
        if (kind == _BACKUP && _touchesPegModule(m.tokens, deps)) revert InvalidRoute();
        address[] memory exact = r.exactAmountInputs();
        bool feeSwitch = false;
        for (uint256 i = 0; i < exact.length && !feeSwitch; ++i) {
            feeSwitch = IssuerProbes.readsFeeRate(_s().tokens[exact[i]].issuerProbe);
        }
        // A transfer fee switched on would revert an exact-amount leg, possibly in both slots at once.
        if (feeSwitch) revert InvalidRoute();
        address other = _s().routes[_slotKey(marketId, token, debtAsset, kind == _PRIMARY ? _BACKUP : _PRIMARY)].route;
        // Primary and backup share no dependency or intermediate, so one failing pool or token cannot stop both.
        if (
            other != address(0)
                && (other == route
                    || _shareFeed(deps, ISettlementRoute(other).dependencies())
                    || _shareIntermediate(r.intermediates(), ISettlementRoute(other).intermediates(), debtAsset))
        ) revert InvalidRoute();
    }

    function _shareIntermediate(
        address[] memory a,
        address[] memory b,
        address debtAsset
    ) private pure returns (bool) {
        for (uint256 i = 0; i < a.length; ++i) {
            if (a[i] == debtAsset) continue;
            for (uint256 j = 0; j < b.length; ++j) {
                if (a[i] == b[j]) return true;
            }
        }
        return false;
    }

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
                && l.firstLossReserveOf[l.spokes[m.spoke].hub][debtAsset] == address(0)
        ) revert TokenNotListed(debtAsset);
        if (kind > _BACKUP || route == address(0) || token == debtAsset) revert InvalidRoute();
    }

    /// @dev Also true (fail closed) when the integration record is not final and current.
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

    function _integrationRecordKey(
        uint32 integrationId
    ) private view returns (bytes32) {
        address lpVault = IVaultTokenFactory(_VAULT_TOKEN_FACTORY).lpVaultOf(integrationId);
        if (lpVault == address(0)) revert IMarketRegistry.InvalidIntegration(integrationId);
        ILPVault v = ILPVault(lpVault);
        return
            keccak256(
                abi.encode(block.chainid, lpVault, lpVault.codehash, v.AMM_PROTOCOL(), v.capabilities().poolKeying)
            );
    }

    /// @dev Disables every active route of the integration's markets whose dependencies name an added contract.
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

    function _namesAny(
        address[] memory deps,
        address[] memory list
    ) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (_contains(deps, list[i])) return true;
        }
        return false;
    }

    function _recorded(
        address[] storage list,
        address a
    ) private view returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }

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
