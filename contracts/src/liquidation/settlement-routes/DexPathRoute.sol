// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexHops} from "./DexHops.sol";
import {ISettlementRoute} from "./ISettlementRoute.sol";
import {DexHop, RouteConfig} from "./types/SettlementRouteTypes.sol";

/// @title DexPathRoute
/// @notice Swap route type 1 (`DexPath`): a listed token into a debt asset through one to three fixed DEX hops.
contract DexPathRoute is DexHops {
    uint8 internal constant ROUTE_TYPE = 1;

    /// @notice Fixes the route; reverts `InvalidRouteConfig` on any failed check or with no hop.
    /// @param hops One to three hops from `config.tokenIn` to `config.tokenOut`.
    constructor(
        RouteConfig memory config,
        DexHop[] memory hops
    ) DexHops(config, config.tokenIn, hops) {}

    /// @inheritdoc ISettlementRoute
    function routeType() external pure override returns (uint8 typeId) {
        typeId = ROUTE_TYPE;
    }

    /// @inheritdoc ISettlementRoute
    function dependencies() external view override returns (address[] memory contracts) {
        contracts = _hopPools();
    }

    function _runLegs(
        uint256 amount
    ) internal override {
        _runHops(amount);
    }

    function _intermediates() internal view override returns (address[] memory tokens) {
        tokens = _hopIntermediates();
    }
}
