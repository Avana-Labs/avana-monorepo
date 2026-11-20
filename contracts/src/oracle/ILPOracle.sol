// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4PriceFeed} from "../interfaces/external/aave/IAaveV4PriceFeed.sol";

/// @title ILPOracle
/// @notice Aave price source of one band market's vault token. One vault token is one unit of liquidity spread over
/// the market's band `[A, B]`; its price is what `10^unitDecimals` units of that liquidity hold at the fair price `P`,
/// valued in USD with 8 decimals. `P` comes from the market's own Chainlink feeds for token0 and token1, never from the
/// pool, and the holdings at `P` are the AMM's own: all token0 below the band, all token1 above it.
/// @dev Immutable and stateless: no proxy, no roles, no stored price. A feed change deploys a new LPOracle that the
/// Aave DAO sets as the reserve's source. The design record is `DESIGN.md` next to this file.
interface ILPOracle is IAaveV4PriceFeed {
    /// @notice A constructor argument is zero, out of range, or does not match the LPVault's market.
    error InvalidParams();

    /// @notice A feed answered zero or below, or the token's price is above `LPPriceMath.MAX_PRICE`.
    /// @param feed The feed whose answer failed, or the token's first feed when the product is out of range.
    error InvalidPrice(address feed);

    /// @notice One token's Chainlink route: one feed (TOKEN/USD) or two multiplied (TOKEN/X, then X/USD).
    /// @param feeds The feeds in multiplication order, one or two.
    /// @param usdStable A USD stablecoin, valued at most $1.
    struct TokenFeeds {
        address[] feeds;
        bool usdStable;
    }

    /// @notice Constructor arguments.
    /// @param lpVault The LPVault that lists the market; the band ticks and tokens are read from it once.
    /// @param marketId The LPVault market the vault token belongs to.
    /// @param unitDecimals Decimals of the market's vault token: the answer prices `10^unitDecimals` liquidity units.
    /// @param token0 The route of the market's token0.
    /// @param token1 The route of the market's token1.
    /// @param description Human-readable name of the feed.
    struct Params {
        address lpVault;
        uint256 marketId;
        uint8 unitDecimals;
        TokenFeeds token0;
        TokenFeeds token1;
        string description;
    }

    /// @notice USD value of one whole vault token at the fair price, 8 decimals, rounded down and at least 1.
    /// @dev Reverts `InvalidPrice` when a feed answers zero or below, like a Chainlink source Aave cannot read. No
    /// staleness check: Aave V4 reads no round time, and a revert here would stop liquidations as well as borrows.
    function latestAnswer() external view override returns (int256 answer);

    /// @notice Always 8, the decimals of Aave V4's oracle.
    function decimals() external pure override returns (uint8);

    /// @notice Fixed description.
    function description() external view override returns (string memory);

    /// @notice Each token's price (8 decimals, stable cap applied) and the fair square-root price of the pool's
    /// token1-per-token0 ratio in Q64.96, before the band clamp.
    function getPrices() external view returns (uint256 price0, uint256 price1, uint160 sqrtPriceX96);

    /// @notice Raw token amounts one whole vault token holds at the fair price, each rounded down.
    function getUnitAmounts() external view returns (uint256 amount0, uint256 amount1);

    /// @notice The LPVault whose market this oracle prices.
    function lpVault() external view returns (address vault);

    /// @notice The LPVault market ID.
    function marketId() external view returns (uint256 id);

    /// @notice The market's band ticks, as listed in the LPVault.
    function band() external view returns (int24 bandLower, int24 bandUpper);

    /// @notice The market's tokens, in pool order.
    function tokens() external view returns (address token0, address token1);

    /// @notice Decimals of the vault token priced; one whole vault token is `10^unitDecimals` liquidity units.
    function unitDecimals() external view returns (uint8 d);

    /// @notice The feeds of token `index` (0 or 1), in multiplication order.
    function feedsOf(
        uint256 index
    ) external view returns (address[] memory feeds);
}
