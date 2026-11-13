// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../../../src/types/PositionShape.sol";
import {IntegLPVaultMock} from "./IntegLPVaultMock.sol";
import {RegistryCoverageSpokeMock} from "./MarketRegistryMocks.sol";

/// @title FullStackLPVaultMock
/// @notice `IntegLPVaultMock` (custody rules, unwind rates, depth) with the binding surface the real MarketRegistry
/// and the real concentrated-liquidity LPOracle read: `bindMarket` as `IAmmIntegration` declares it, called only by
/// the registry inside `listCollateralMarket`, and `rateProviders`, two zero addresses as the Uniswap v3 integration
/// returns them. The fixture prepares each market's tokens (pool order), unwind rates and unit decimals first.
contract FullStackLPVaultMock is IntegLPVaultMock {
    mapping(uint256 marketId => address[] tokens) internal _pendingTokens;
    mapping(uint256 marketId => uint256[] rates) internal _pendingRates;
    mapping(uint256 marketId => uint8 decimals) public unitDecimalsOf;

    constructor(
        uint32 integrationId,
        address collateralization,
        address lock,
        bytes32 ammProtocol
    ) IntegLPVaultMock(integrationId, collateralization, lock, ammProtocol) {}

    /// @notice The tokens, unwind rates and unit decimals `bindMarket` records for `marketId`.
    function prepare(
        uint256 marketId,
        address[] calldata tokens,
        uint256[] calldata rates,
        uint8 unitDecimals
    ) external {
        _pendingTokens[marketId] = tokens;
        _pendingRates[marketId] = rates;
        unitDecimalsOf[marketId] = unitDecimals;
    }

    /// @notice `IAmmIntegration.bindMarket`: records the pool, range, tokens and rates of `marketId`.
    function bindMarket(
        uint256 marketId,
        address pool,
        bytes32,
        PositionShape calldata shape,
        bytes calldata
    ) external returns (address[] memory tokens, uint8 unitDecimals) {
        if (msg.sender != MARKET_REGISTRY) revert NotMarketRegistry();
        if (_tokens[marketId].length != 0) revert MarketBinding(marketId);
        tokens = _pendingTokens[marketId];
        poolOf[marketId] = pool;
        _tokens[marketId] = tokens;
        _rates[marketId] = _pendingRates[marketId];
        _ticks[marketId] = [shape.tickLower, shape.tickUpper];
        unitDecimals = unitDecimalsOf[marketId];
    }

    /// @notice Unit exponent of a bound market: 0, one vault-token unit per unit of liquidity (USDC/USDT full range).
    function unitExponent(
        uint256 marketId
    ) external view returns (uint8) {
        if (_tokens[marketId].length == 0) revert MarketBinding(marketId);
        return 0;
    }

    /// @notice Rate providers of a bound market: none for a concentrated-liquidity pool.
    function rateProviders(
        uint256 marketId
    ) external view returns (address[] memory providers) {
        uint256 n = _tokens[marketId].length;
        if (n == 0) revert MarketBinding(marketId);
        providers = new address[](n);
    }
}

/// @title FullStackCoverageSpokeMock
/// @notice A Coverage Spoke as the MarketRegistry and the ParameterStore read it (`RegistryCoverageSpokeMock` plus the
/// first-loss reserve minimum the ParameterStore bounds its breaker and speed settings by).
contract FullStackCoverageSpokeMock is RegistryCoverageSpokeMock {
    uint256 public firstLossReserveMinimum;

    constructor(
        address hub,
        address asset,
        uint256 assetId,
        uint256 minimum
    ) RegistryCoverageSpokeMock(hub, asset, assetId) {
        firstLossReserveMinimum = minimum;
    }
}
