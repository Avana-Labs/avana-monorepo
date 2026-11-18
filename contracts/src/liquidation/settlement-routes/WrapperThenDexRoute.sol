// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDaiUsds} from "../../interfaces/external/sky/IDaiUsds.sol";
import {DexHops} from "./DexHops.sol";
import {ISettlementRoute} from "./ISettlementRoute.sol";
import {RouteMath} from "./RouteMath.sol";
import {DexHop, RouteConfig, WrapperKind, WrapperStep} from "./types/SettlementRouteTypes.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title WrapperThenDexRoute
/// @notice Swap route type 2 (`WrapperThenDex`): one unwrap or redeem step, then up to three fixed DEX hops.
contract WrapperThenDexRoute is DexHops {
    uint8 internal constant ROUTE_TYPE = 2;

    WrapperKind private immutable _WRAPPER_KIND;

    address private immutable _WRAPPER;

    address private immutable _UNDERLYING;

    /// @notice Fixes the route; reverts `InvalidRouteConfig` on any failed check, or when the wrapper is a hop pool.
    /// @param hops Up to three hops from `step.underlying` to `config.tokenOut` (none when the step yields it).
    constructor(
        RouteConfig memory config,
        WrapperStep memory step,
        DexHop[] memory hops
    ) DexHops(config, step.underlying, hops) {
        if (step.wrapper == address(0) || step.underlying == config.tokenIn) revert InvalidRouteConfig();
        if (step.kind == WrapperKind.Erc4626Redeem) {
            (bool okAsset, address asset) = RouteMath.addressOf(step.wrapper, abi.encodeCall(IERC4626.asset, ()));
            if (step.wrapper != config.tokenIn || !okAsset || asset != step.underlying) revert InvalidRouteConfig();
        } else {
            (bool okUsds, address usds) = RouteMath.addressOf(step.wrapper, abi.encodeCall(IDaiUsds.usds, ()));
            (bool okDai, address dai) = RouteMath.addressOf(step.wrapper, abi.encodeCall(IDaiUsds.dai, ()));
            if (
                step.wrapper == config.tokenIn || step.wrapper == config.tokenOut || !okUsds || !okDai
                    || usds != config.tokenIn || dai != step.underlying
            ) revert InvalidRouteConfig();
        }
        bool clash = step.wrapper == step.underlying;
        for (uint256 k = 0; k < hops.length; ++k) {
            clash = clash || hops[k].pool == step.wrapper || hops[k].tokenOut == step.wrapper;
        }
        if (clash) revert InvalidRouteConfig();
        _WRAPPER_KIND = step.kind;
        _WRAPPER = step.wrapper;
        _UNDERLYING = step.underlying;
    }

    /// @inheritdoc ISettlementRoute
    function routeType() external pure override returns (uint8 typeId) {
        typeId = ROUTE_TYPE;
    }

    /// @inheritdoc ISettlementRoute
    function dependencies() external view override returns (address[] memory contracts) {
        address[] memory pools = _hopPools();
        contracts = new address[](pools.length + 1);
        contracts[0] = _WRAPPER;
        for (uint256 k = 0; k < pools.length; ++k) {
            contracts[k + 1] = pools[k];
        }
    }

    function _runLegs(
        uint256 amount
    ) internal override {
        uint256 before = _balance(_UNDERLYING);
        if (_WRAPPER_KIND == WrapperKind.Erc4626Redeem) {
            // The assets are measured as the route's balance rise below, not taken from the return value.
            // forge-lint: disable-next-line(unused-return)
            IERC4626(_WRAPPER).redeem(amount, address(this), address(this));
        } else {
            _approve(_TOKEN_IN, _WRAPPER, amount);
            IDaiUsds(_WRAPPER).usdsToDai(address(this), amount);
            _approve(_TOKEN_IN, _WRAPPER, 0);
        }
        uint256 unwrapped = _rise(_UNDERLYING, before);
        if (unwrapped != 0) _runHops(unwrapped);
    }

    function _intermediates() internal view override returns (address[] memory tokens) {
        address[] memory hopTokens = _hopIntermediates();
        // The step's output is held between legs unless it is the debt asset itself (a route with no hops).
        uint256 lead = _UNDERLYING == _TOKEN_OUT ? 0 : 1;
        tokens = new address[](hopTokens.length + lead);
        if (lead == 1) tokens[0] = _UNDERLYING;
        for (uint256 k = 0; k < hopTokens.length; ++k) {
            tokens[k + lead] = hopTokens[k];
        }
    }
}
