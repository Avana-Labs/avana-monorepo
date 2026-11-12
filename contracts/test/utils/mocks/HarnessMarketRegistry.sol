// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {Market} from "../../../src/types/Market.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";

/// @title HarnessMarketRegistry
/// @notice The MarketRegistry views the ParameterStore logic reads in the property harnesses, for one Registered
/// market (identifier 1) of two listed tokens in an address-keyed pool, with no price routes and no Hub. Small on
/// purpose: each harness deploys it beside a logic contract under the 49,152-byte initcode limit.
contract HarnessMarketRegistry {
    address public pool;
    address public integration;
    address public lpOracle;
    address public token0;
    address public token1;

    /// @notice One market, whatever its definition holds.
    uint256 public constant marketCount = 1;

    function set(
        address pool_,
        address integration_,
        address lpOracle_,
        address token0_,
        address token1_
    ) external {
        (pool, integration, lpOracle, token0, token1) = (pool_, integration_, lpOracle_, token0_, token1_);
    }

    function getMarket(
        uint256 id
    ) external view returns (Market memory m) {
        if (id != 1) return m;
        m.integration = integration;
        m.pool = pool;
        m.shape.kind = ShapeKind.TickRange;
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (token0, token1);
        m.tokenDecimals = new uint8[](2);
        (m.tokenDecimals[0], m.tokenDecimals[1]) = (6, 6);
        m.lpOracle = lpOracle;
        m.status = MarketStatus.Registered;
    }

    function getToken(
        address token
    ) external view returns (TokenDef memory d) {
        d.listed = token != address(0) && (token == token0 || token == token1);
        d.decimals = 6;
    }

    function isRecordedHub(
        address
    ) external pure returns (bool) {
        return false;
    }
}
