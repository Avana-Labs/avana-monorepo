// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4PriceFeed} from "../dependencies/aave/IAaveV4PriceFeed.sol";

/// @title ILPOracle
/// @notice Aave price source of one band market's vault token. One vault token is one unit of liquidity spread over
/// the market's band `[A, B]`; its price is what `10^unitDecimals` units of that liquidity hold at the fair price `P`,
/// valued in USD with 8 decimals. `P` comes from Aave V4's own prices of token0 and token1: the `AaveOracle` of the
/// market's price Spoke, read live by reserve ID, never from the pool. The holdings at `P` are the AMM's own: all
/// token0 below the band, all token1 above it.
/// @dev Immutable and stateless: no proxy, no roles, no stored price. A source Aave governance sets for either
/// token's reserve on the price Spoke is followed on the next read. The design record is
/// `contracts/design/oracle.md`.
interface ILPOracle is IAaveV4PriceFeed {
    /// @notice A constructor argument is zero, out of range, or does not match the LPVault's market or the price
    /// Spoke's reserves.
    error InvalidParams();

    /// @notice Aave's price of the reserve is above `LPPriceMath.MAX_PRICE` ($10^10), past what the math is sized for.
    /// @param reserveId The price Spoke's reserve whose price is out of range.
    error PriceAboveBound(uint256 reserveId);

    /// @notice Constructor arguments.
    /// @param lpVault The LPVault that lists the market; the band ticks and tokens are read from it once.
    /// @param marketId The LPVault market the vault token belongs to.
    /// @param unitDecimals Decimals of the market's vault token: the answer prices `10^unitDecimals` liquidity units.
    /// @param priceSpoke The Aave V4 Spoke whose `AaveOracle` prices both tokens.
    /// @param reserveId0 The price Spoke's reserve of the market's token0.
    /// @param reserveId1 The price Spoke's reserve of the market's token1.
    /// @param description Human-readable name of the feed.
    struct Params {
        address lpVault;
        uint256 marketId;
        uint8 unitDecimals;
        address priceSpoke;
        uint256 reserveId0;
        uint256 reserveId1;
        string description;
    }

    /// @notice USD value of one whole vault token at the fair price, 8 decimals, rounded down and at least 1.
    /// @dev Reverts when Aave's `getReservePrice` reverts for either token (a source of 0 or below, or no source), as
    /// Aave's own reserves of that token do, and `PriceAboveBound` above $10^10. No staleness check: Aave V4 reads no
    /// round time, and a revert here would stop liquidations as well as borrows.
    function latestAnswer() external view override returns (int256 answer);

    /// @notice Always 8, the decimals of Aave V4's oracle.
    function decimals() external pure override returns (uint8);

    /// @notice Fixed description.
    function description() external view override returns (string memory);

    /// @notice Each token's price (8 decimals, as Aave V4 serves it) and the fair square-root price of the pool's
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

    /// @notice The Aave V4 Spoke whose oracle prices the tokens.
    function priceSpoke() external view returns (address spoke);

    /// @notice The price Spoke's `ORACLE()`, read once (immutable on the Spoke).
    function aaveOracle() external view returns (address oracle);

    /// @notice The price Spoke's reserves of token0 and token1.
    function reserveIds() external view returns (uint256 reserveId0, uint256 reserveId1);
}
