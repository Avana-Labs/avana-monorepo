// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {MockMarketRegistry} from "./MockMarketRegistry.sol";

/// @title GasMarketRegistry
/// @notice `MockMarketRegistry` with the storage reads of the real MarketRegistry's route views: `activePriceRoutes`
/// reads the token's replaced slot and its two route arrays from its `TokenDef`, `priceRouteVersion` reads a stored
/// counter. Deployed behind an ERC-1967 proxy, like the real registry, by the LPOracle gas benchmarks.
contract GasMarketRegistry is MockMarketRegistry {
    mapping(address token => uint64) internal _versions;

    /// @notice Puts the standby route in force in `slot` and bumps the route version, as `useStandbyRoute` does.
    function useStandby(
        address token,
        RouteSlot slot
    ) external {
        _tokens[token].replacedSlot = slot;
        ++_versions[token];
    }

    function activePriceRoutes(
        address token
    ) external view override returns (address[] memory primary, address[] memory alternate, RouteSlot replaced) {
        TokenDef storage t = _tokens[token];
        replaced = t.replacedSlot;
        primary = replaced == RouteSlot.Primary ? t.standbyRoute : t.primaryRoute;
        alternate = replaced == RouteSlot.Alternate ? t.standbyRoute : t.alternateRoute;
    }

    function priceRouteVersion(
        address token
    ) external view override returns (uint64) {
        return _versions[token];
    }
}
