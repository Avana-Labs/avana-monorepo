// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IGsm} from "../../interfaces/external/gho/IGsm.sol";
import {IPegModuleRoute} from "../../liquidation/settlement-routes/IPegModuleRoute.sol";
import {ISettlementRoute} from "../../liquidation/settlement-routes/ISettlementRoute.sol";
import {RouteReads} from "../../liquidation/settlement-routes/RouteReads.sol";
import {PegModuleKind} from "../../liquidation/settlement-routes/types/PegModuleStep.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {IERC1820Registry} from "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";

/// @title MarketRegistryRouteChecks
/// @notice The route-type and token checks `setRoute` and `restoreRoute` run on a swap route (2.12 REQ-ROUTE-002,
/// REQ-ROUTE-005, REQ-ROUTE-019): the route type is admitted in the slot, a GSM route fills only a backup slot and only
/// while its GSM is live (Q-341), and no token the route holds has an ERC-1820 `ERC777Token` implementer (Q-342).
/// @dev Every read is a static call through `RouteReads._staticRead` that forwards the gas left and copies at most one
/// byte more than the answer it expects; only an answer of exactly that length counts. A revert, an address without
/// code, a shorter or longer answer, or a word outside its type's range refuses the route (fail closed). Example: a
/// GSM answering `getIsFrozen()` with 64 bytes is refused even when its first word is `false`.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005, REQ-ROUTE-019, REQ-ROUTE-030, Q-341, Q-342
// The ERC-777 check reads the ERC-1820 registry once per token the route holds; static calls only.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryRouteChecks is MarketRegistryStorage {
    /// @dev The ERC-1820 registry, at the same address on every chain (deployed by a keyless transaction).
    address internal constant _ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;

    /// @dev The ERC-1820 interface hash an ERC-777 token registers for itself: `keccak256("ERC777Token")`.
    bytes32 internal constant _ERC777_TOKEN_HASH = keccak256("ERC777Token");

    /// @dev Route type of a `PegModule` route, and the highest route type (2, `WrapperThenDex`).
    uint256 internal constant _PEG_MODULE_ROUTE = 0;
    uint256 internal constant _MAX_ROUTE_TYPE = 2;

    /// @dev REQ-ROUTE-002 and REQ-ROUTE-005: true when `route.routeType()` is 0, 1 or 2 and admitted in slot `kind`.
    /// A `DexPath` or `WrapperThenDex` route is admitted in either slot. A `PegModule` route must name, through
    /// `pegModule()`, a kind of `Gsm` or `LitePsm` and a module listed in its `dependencies()`; a LitePSM route is
    /// admitted in either slot, a GSM route only in the backup slot and only while the GSM is live (`_gsmLive`, Q-341).
    function _routeTypeAdmitted(
        address route,
        uint8 kind,
        address[] memory deps
    ) internal view returns (bool) {
        (bool okType, uint256 routeType) = _readWord(route, abi.encodeCall(ISettlementRoute.routeType, ()));
        if (!okType || routeType > _MAX_ROUTE_TYPE) return false;
        if (routeType != _PEG_MODULE_ROUTE) return true;
        (bool okPeg, bytes memory ret) =
            RouteReads._staticRead(route, gasleft(), abi.encodeCall(IPegModuleRoute.pegModule, ()), 65);
        if (!okPeg || ret.length != 64) return false;
        (uint256 pegKind, uint256 moduleWord) = abi.decode(ret, (uint256, uint256));
        if (pegKind > uint256(PegModuleKind.LitePsm) || moduleWord >> 160 != 0) return false;
        // A word with no bit above 160 decodes as an address without reverting.
        (, address module) = abi.decode(ret, (uint256, address));
        if (!_listed(deps, module)) return false;
        if (pegKind == uint256(PegModuleKind.LitePsm)) return true;
        // The GSM is never a primary route (REQ-ROUTE-002).
        if (kind != _BACKUP) return false;
        return _gsmLive(module);
    }

    /// @dev Q-341: true when the GSM answers `getIsSeized() == false`, `getIsFrozen() == false` and
    /// `getExposureCap() > 0`, each with exactly one word in its type's range. A cap of 0 means the GSM takes no input.
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

    /// @dev Q-342 and REQ-ROUTE-005: true when none of `token`, `debtAsset` and the route's `intermediates` has an
    /// ERC-1820 `ERC777Token` implementer. A chain without the ERC-1820 registry has none: an ERC-777 token registers
    /// that implementer in its own constructor, so it cannot be deployed there. A registry read that fails or returns
    /// anything but exactly one zero word counts as an implementer.
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

    /// @dev True unless the ERC-1820 registry answers `getInterfaceImplementer(token, keccak256("ERC777Token"))` with
    /// exactly one zero word.
    function _hasErc777Implementer(
        address token
    ) private view returns (bool) {
        (bool ok, uint256 implementer) = _readWord(
            _ERC1820_REGISTRY, abi.encodeCall(IERC1820Registry.getInterfaceImplementer, (token, _ERC777_TOKEN_HASH))
        );
        return !ok || implementer != 0;
    }

    /// @dev One word read by a static call that forwards the gas left and copies at most 33 bytes; `ok` only for an
    /// answer of exactly 32 bytes. A read starved of gas fails, which refuses the route.
    function _readWord(
        address target,
        bytes memory data
    ) private view returns (bool ok, uint256 word) {
        bytes memory ret;
        (ok, ret) = RouteReads._staticRead(target, gasleft(), data, 33);
        if (!ok || ret.length != 32) return (false, 0);
        word = abi.decode(ret, (uint256));
    }

    /// @dev True when `list` holds the non-zero address `a`.
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
