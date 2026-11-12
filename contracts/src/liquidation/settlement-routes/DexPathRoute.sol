// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DexHops} from "./DexHops.sol";
import {ISettlementRoute} from "./ISettlementRoute.sol";
import {DexHop} from "./types/DexHop.sol";
import {RouteConfig} from "./types/RouteConfig.sol";

/// @title DexPathRoute
/// @notice Swap route type 1 (`DexPath`, 2.12): any listed token into an enabled debt asset through one to three fixed
/// hops over Uniswap v3, Aerodrome Slipstream, Curve StableSwap-NG or pinned legacy Curve pools (REQ-ROUTE-046).
/// @dev Legs: the hops of `DexHops`, the first on the input received, each on the whole output of the one before.
/// `dependencies()` lists every hop pool; `intermediates()` lists every hop output but the last. Example: a cbETH →
/// USDC route on Base hops through the cbETH/WETH and WETH/USDC pools, holds WETH between them, and returns any cbETH a
/// thin pool did not take and any WETH left over to LPVaultSwap with the USDC.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-004, REQ-ROUTE-009, REQ-ROUTE-013, REQ-ROUTE-016, REQ-ROUTE-042, REQ-ROUTE-043, Q-062, Q-339
contract DexPathRoute is DexHops {
    /// @notice Route type of `DexPath`.
    uint8 internal constant ROUTE_TYPE = 1;

    /// @notice Fixes the route; reverts `InvalidRouteConfig` on any failed check of `SwapRouteBase` or `DexHops`, or with
    /// no hop.
    /// @param config Shared constructor arguments.
    /// @param hops One to three hops from `config.tokenIn` to `config.tokenOut`.
    /// @custom:spec REQ-ROUTE-043, REQ-ROUTE-045
    constructor(
        RouteConfig memory config,
        DexHop[] memory hops
    ) DexHops(config, config.tokenIn, hops) {}

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005
    function routeType() external pure override returns (uint8 typeId) {
        typeId = ROUTE_TYPE;
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-004, REQ-ROUTE-043
    function dependencies() external view override returns (address[] memory contracts) {
        contracts = _hopPools();
    }

    /// @custom:spec REQ-ROUTE-008, REQ-ROUTE-009
    function _runLegs(
        uint256 amount
    ) internal override {
        _runHops(amount);
    }

    /// @custom:spec REQ-ROUTE-003
    function _intermediates() internal view override returns (address[] memory tokens) {
        tokens = _hopIntermediates();
    }
}
