// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IGsm} from "../../interfaces/external/gho/IGsm.sol";
import {IPegModuleRoute} from "../../liquidation/settlement-routes/IPegModuleRoute.sol";
import {ISettlementRoute} from "../../liquidation/settlement-routes/ISettlementRoute.sol";
import {RouteMath} from "../../liquidation/settlement-routes/RouteMath.sol";
import {PegModuleKind} from "../../liquidation/settlement-routes/types/SettlementRouteTypes.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {IERC1820Registry} from "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";

/// @title MarketRegistryRouteChecks
/// @notice The route-type and ERC-777 checks `setRoute` and `restoreRoute` run on a swap route.
/// @dev Every read is a static call; only an answer of exactly the expected length counts, else the route is refused.
// The ERC-777 check reads the ERC-1820 registry once per token the route holds; static calls only.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryRouteChecks is MarketRegistryStorage {
    /// @dev The ERC-1820 registry, at the same address on every chain.
    address internal constant _ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;

    bytes32 internal constant _ERC777_TOKEN_HASH = keccak256("ERC777Token");

    /// @dev Route type of a `PegModule` route, and the highest route type (`WrapperThenDex`).
    uint256 internal constant _PEG_MODULE_ROUTE = 0;
    uint256 internal constant _MAX_ROUTE_TYPE = 2;

    /// @dev True when the route type is admitted in slot `kind`; a GSM route only as a live backup.
    function _routeTypeAdmitted(
        address route,
        uint8 kind,
        address[] memory deps
    ) internal view returns (bool) {
        (bool okType, uint256 routeType) = _readWord(route, abi.encodeCall(ISettlementRoute.routeType, ()));
        if (!okType || routeType > _MAX_ROUTE_TYPE) return false;
        if (routeType != _PEG_MODULE_ROUTE) return true;
        (bool okPeg, bytes memory ret) =
            RouteMath._staticRead(route, gasleft(), abi.encodeCall(IPegModuleRoute.pegModule, ()), 65);
        if (!okPeg || ret.length != 64) return false;
        (uint256 pegKind, uint256 moduleWord) = abi.decode(ret, (uint256, uint256));
        if (pegKind > uint256(PegModuleKind.LitePsm) || moduleWord >> 160 != 0) return false;
        // A word with no bit above 160 decodes as an address without reverting.
        (, address module) = abi.decode(ret, (uint256, address));
        if (!_listed(deps, module)) return false;
        if (pegKind == uint256(PegModuleKind.LitePsm)) return true;
        if (kind != _BACKUP) return false;
        return _gsmLive(module);
    }

    function _gsmLive(
        address gsm
    ) internal view returns (bool) {
        (bool okSeized, uint256 seized) = _readWord(gsm, abi.encodeCall(IGsm.getIsSeized, ()));
        if (!okSeized || seized != 0) return false;
        (bool okFrozen, uint256 frozen) = _readWord(gsm, abi.encodeCall(IGsm.getIsFrozen, ()));
        if (!okFrozen || frozen != 0) return false;
        (bool okCap, uint256 cap) = _readWord(gsm, abi.encodeCall(IGsm.getExposureCap, ()));
        return okCap && cap != 0 && cap <= type(uint128).max;
    }

    function _noErc777(
        address token,
        address debtAsset,
        address[] memory intermediates
    ) internal view returns (bool) {
        if (_ERC1820_REGISTRY.code.length == 0) return true;
        if (_hasErc777Implementer(token) || _hasErc777Implementer(debtAsset)) return false;
        for (uint256 i = 0; i < intermediates.length; ++i) {
            if (_hasErc777Implementer(intermediates[i])) return false;
        }
        return true;
    }

    function _isErc777Token(
        address token
    ) internal view returns (bool) {
        return _ERC1820_REGISTRY.code.length != 0 && _hasErc777Implementer(token);
    }

    /// @dev Fails closed: a failed read counts as an implementer.
    function _hasErc777Implementer(
        address token
    ) private view returns (bool) {
        (bool ok, uint256 implementer) = _readWord(
            _ERC1820_REGISTRY, abi.encodeCall(IERC1820Registry.getInterfaceImplementer, (token, _ERC777_TOKEN_HASH))
        );
        return !ok || implementer != 0;
    }

    function _readWord(
        address target,
        bytes memory data
    ) private view returns (bool ok, uint256 word) {
        bytes memory ret;
        (ok, ret) = RouteMath._staticRead(target, gasleft(), data, 33);
        if (!ok || ret.length != 32) return (false, 0);
        word = abi.decode(ret, (uint256));
    }

    function _listed(
        address[] memory list,
        address a
    ) private pure returns (bool) {
        if (a == address(0)) return false;
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}
// forge-lint: disable-end(calls-loop)
