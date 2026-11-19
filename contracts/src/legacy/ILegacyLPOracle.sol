// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4PriceFeed} from "../interfaces/external/aave/IAaveV4PriceFeed.sol";

/// @title ILegacyLPOracle
/// @notice Aave price source of one market's vault token: the USD value of one whole vault token, 8 decimals,
/// computed on every read from Chainlink token prices and the market's composition at those prices.
/// @dev Immutable and stateless: no proxy, no roles, no stored price. A feed change deploys a new LPOracle that the
/// Aave DAO sets as the reserve's source. The borrow and liquidation gates read `getPriceStatus`.
interface ILegacyLPOracle is IAaveV4PriceFeed {
    /// @notice A constructor argument does not describe a valid market.
    error InvalidMarket(uint256 marketId);

    /// @notice A Chainlink leg answered zero or below, above the price bound, or with a round from the future.
    error InvalidPrice(address feed);

    /// @notice The market's composition could not be valued.
    error InvalidComposition(uint256 marketId);

    /// @notice One token's Chainlink route: one leg (TOKEN/USD) or two multiplied (TOKEN/X, then X/USD).
    struct TokenRoute {
        address token;
        // USD stablecoin: valued at most $1.
        bool isUsdStable;
        address[] feeds;
    }

    /// @notice Constructor arguments.
    struct Params {
        uint256 marketId;
        // The market's AMM integration (LPVault), which returns the composition.
        address integration;
        // Holds each feed's borrow and liquidation age limits.
        address parameterStore;
        string description;
        // Decimals of the market's vault token (the LPVault's unit decimals at binding).
        uint8 vaultDecimals;
        // In pool order.
        TokenRoute[] routes;
    }

    /// @notice The served price and whether its inputs are fresh enough to borrow against or to liquidate.
    struct PriceStatus {
        int256 answer;
        // Oldest `updatedAt` of every leg.
        uint64 updatedAt;
        // Every leg within its `borrowPriceMaxAge`, none in the future.
        bool borrowFresh;
        // Every leg within its `liquidationPriceMaxAge`.
        bool liquidationFresh;
    }

    /// @notice USD value of one whole vault token, 8 decimals, at least 1.
    /// @dev Reverts `InvalidPrice` on a failed leg, like a Chainlink source Aave cannot read.
    function latestAnswer() external view override returns (int256 answer);

    /// @notice Always 8.
    function decimals() external pure override returns (uint8);

    /// @notice Fixed description.
    function description() external view override returns (string memory);

    /// @notice Chainlink-shaped view of the served price; `updatedAt` is the oldest leg's.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Valuation price of each token in pool order (8 decimals, stable ceiling applied) and the oldest leg.
    function getTokenPrices() external view returns (uint256[] memory prices, uint64 updatedAt);

    /// @notice The served price with its freshness for the borrow and liquidation gates.
    function getPriceStatus() external view returns (PriceStatus memory status);

    /// @notice The token's Chainlink feeds, in multiplication order.
    function feedsOf(
        uint256 index
    ) external view returns (address[] memory feeds);

    /// @notice The MarketRegistry identifier of the market.
    function marketId() external view returns (uint256 id);

    /// @notice The market's AMM integration (LPVault).
    function integration() external view returns (address amm);

    /// @notice The market's tokens in pool order.
    function tokens() external view returns (address[] memory list);

    /// @notice Decimals of the vault token priced; one whole vault token is `10^vaultDecimals` units.
    function vaultDecimals() external view returns (uint8 d);

    /// @notice The ParameterStore holding the feeds' age limits.
    function parameterStore() external view returns (address store);
}
