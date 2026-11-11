// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDaiUsds} from "../../interfaces/external/sky/IDaiUsds.sol";
import {DexHops} from "./DexHops.sol";
import {ISettlementRoute} from "./ISettlementRoute.sol";
import {RouteReads} from "./RouteReads.sol";
import {DexHop} from "./types/DexHop.sol";
import {RouteConfig} from "./types/RouteConfig.sol";
import {WrapperKind, WrapperStep} from "./types/WrapperStep.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title WrapperThenDexRoute
/// @notice Swap route type 2 (`WrapperThenDex`, 2.12): a wrapped or rate token into an enabled debt asset, by one unwrap
/// or redeem step (an ERC-4626 vault such as a static aToken or a savings-rate token, or the Sky DAI/USDS converter)
/// followed by up to three fixed DEX hops.
/// @dev Legs: (1) `IERC4626(TOKEN_IN).redeem(amount, route, route)` (no allowance: the route redeems its own shares) or
/// `usdsToDai(route, amount)` after approving the converter for exactly `amount`; (2) the hops of `DexHops` on the
/// step's measured output. `dependencies()` lists the wrapper first, then every hop pool; `intermediates()` lists the
/// step's output (unless it is the debt asset), then every hop output but the last. Example: sUSDS → USDC redeems
/// sUSDS for USDS, then hops through a USDS/USDC pool.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-003, REQ-ROUTE-004, REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-016, REQ-ROUTE-042, REQ-ROUTE-043, Q-062, Q-339
contract WrapperThenDexRoute is DexHops {
    /// @notice Route type of `WrapperThenDex`.
    uint8 internal constant ROUTE_TYPE = 2;

    /// @dev Unwrap step kind.
    WrapperKind private immutable _WRAPPER_KIND;

    /// @dev Contract the step calls: the ERC-4626 vault (`TOKEN_IN` itself) or the DAI/USDS converter.
    address private immutable _WRAPPER;

    /// @dev Token the step yields: the vault's asset, or DAI; the hops' path start.
    address private immutable _UNDERLYING;

    /// @notice Fixes the route; reverts `InvalidRouteConfig` on any failed check of `SwapRouteBase`, `DexHops` or the
    /// step (`WrapperStep`: an ERC-4626 step's `asset()` is the step's output; a converter's `usds()` and `dai()` are the
    /// input and the step's output; a contract that does not answer a read fails), or when the wrapper is one of the hop
    /// pools.
    /// @param config Shared constructor arguments.
    /// @param step The unwrap step.
    /// @param hops Up to three hops from `step.underlying` to `config.tokenOut` (none when the step yields it).
    /// @custom:spec REQ-ROUTE-043, REQ-ROUTE-045
    constructor(
        RouteConfig memory config,
        WrapperStep memory step,
        DexHop[] memory hops
    ) DexHops(config, step.underlying, hops) {
        if (step.wrapper == address(0) || step.underlying == config.tokenIn) revert InvalidRouteConfig();
        if (step.kind == WrapperKind.Erc4626Redeem) {
            (bool okAsset, address asset) = RouteReads.addressOf(step.wrapper, abi.encodeCall(IERC4626.asset, ()));
            if (step.wrapper != config.tokenIn || !okAsset || asset != step.underlying) revert InvalidRouteConfig();
        } else {
            (bool okUsds, address usds) = RouteReads.addressOf(step.wrapper, abi.encodeCall(IDaiUsds.usds, ()));
            (bool okDai, address dai) = RouteReads.addressOf(step.wrapper, abi.encodeCall(IDaiUsds.dai, ()));
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
    /// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005
    function routeType() external pure override returns (uint8 typeId) {
        typeId = ROUTE_TYPE;
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-004, REQ-ROUTE-043
    function dependencies() external view override returns (address[] memory contracts) {
        address[] memory pools = _hopPools();
        contracts = new address[](pools.length + 1);
        contracts[0] = _WRAPPER;
        for (uint256 k = 0; k < pools.length; ++k) {
            contracts[k + 1] = pools[k];
        }
    }

    /// @custom:spec REQ-ROUTE-008, REQ-ROUTE-009, REQ-ROUTE-010
    function _runLegs(
        uint256 amount
    ) internal override {
        uint256 before = _balance(_UNDERLYING);
        if (_WRAPPER_KIND == WrapperKind.Erc4626Redeem) {
            // The assets are measured as the route's balance rise below, never taken from the vault's return value
            // (REQ-ROUTE-008, REQ-ROUTE-015).
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

    /// @custom:spec REQ-ROUTE-003
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
