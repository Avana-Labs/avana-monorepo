// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../integrations/shared/ClTickMath.sol";
import {ILPVault} from "../vault/interfaces/ILPVault.sol";
import {IAggregatorV3} from "../dependencies/chainlink/IAggregatorV3.sol";
import {ILPOracle} from "./interfaces/ILPOracle.sol";
import {LPPriceMath} from "./libraries/LPPriceMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracle
/// @notice Stateless price of one band market's vault token, read by Aave V4 as the reserve's price source.
/// @dev Each read prices token0 and token1 through their Chainlink routes, caps a USD stablecoin at $1, takes the fair
/// square-root price of the two, clamps it to the band, and values the amounts one whole vault token holds there,
/// rounded down. The band, tokens and decimals are fixed at construction from the LPVault's market, so the oracle and
/// the credit always describe the same liquidity. Works unchanged for a full-range market (the band is the pool's
/// usable tick range, where the clamp never binds) and for any custom band.
contract LPOracle is ILPOracle {
    uint8 internal constant _ANSWER_DECIMALS = 8;
    uint8 internal constant _MIN_UNIT_DECIMALS = 6;
    uint8 internal constant _MAX_UNIT_DECIMALS = 18;

    address internal immutable _LP_VAULT;
    uint256 internal immutable _MARKET_ID;
    int24 internal immutable _BAND_LOWER;
    int24 internal immutable _BAND_UPPER;
    uint160 internal immutable _SQRT_LOWER;
    uint160 internal immutable _SQRT_UPPER;
    address internal immutable _TOKEN0;
    address internal immutable _TOKEN1;
    uint8 internal immutable _DECIMALS0;
    uint8 internal immutable _DECIMALS1;
    uint8 internal immutable _UNIT_DECIMALS;
    uint128 internal immutable _UNIT;
    bool internal immutable _STABLE0;
    bool internal immutable _STABLE1;
    // Up to two feeds per token; the second is zero for a one-feed route.
    address internal immutable _FEED0A;
    address internal immutable _FEED0B;
    address internal immutable _FEED1A;
    address internal immutable _FEED1B;
    uint8 internal immutable _FEED0A_DECIMALS;
    uint8 internal immutable _FEED0B_DECIMALS;
    uint8 internal immutable _FEED1A_DECIMALS;
    uint8 internal immutable _FEED1B_DECIMALS;

    string internal _description;

    /// @dev Reads the market from the LPVault and each token's and feed's decimals once. Reverts `InvalidParams` for an
    /// unlisted market, a vault-token decimals outside [6, 18], a token or feed with more than 18 decimals, or a route
    /// of zero, more than two, or zero-address feeds.
    constructor(
        Params memory p
    ) {
        if (p.lpVault == address(0) || p.unitDecimals < _MIN_UNIT_DECIMALS || p.unitDecimals > _MAX_UNIT_DECIMALS) {
            revert InvalidParams();
        }
        ILPVault.Market memory m = ILPVault(p.lpVault).getMarket(p.marketId);
        if (m.pool == bytes32(0) || m.bandLower >= m.bandUpper) revert InvalidParams();
        (_LP_VAULT, _MARKET_ID, _BAND_LOWER, _BAND_UPPER) = (p.lpVault, p.marketId, m.bandLower, m.bandUpper);
        _SQRT_LOWER = ClTickMath.getSqrtPriceAtTick(m.bandLower);
        _SQRT_UPPER = ClTickMath.getSqrtPriceAtTick(m.bandUpper);
        (_TOKEN0, _TOKEN1) = (m.token0, m.token1);
        _DECIMALS0 = _decimalsOf(m.token0);
        _DECIMALS1 = _decimalsOf(m.token1);
        _UNIT_DECIMALS = p.unitDecimals;
        // At most 10^18 < 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _UNIT = uint128(10 ** p.unitDecimals);
        (_STABLE0, _STABLE1) = (p.token0.usdStable, p.token1.usdStable);
        (_FEED0A, _FEED0B, _FEED0A_DECIMALS, _FEED0B_DECIMALS) = _route(p.token0.feeds);
        (_FEED1A, _FEED1B, _FEED1A_DECIMALS, _FEED1B_DECIMALS) = _route(p.token1.feeds);
        _description = p.description;
    }

    /// @inheritdoc ILPOracle
    function latestAnswer() external view override returns (int256 answer) {
        (uint256 p0, uint256 p1, uint160 s) = _prices();
        (uint256 a0, uint256 a1) = LPPriceMath.amounts(s, _SQRT_LOWER, _SQRT_UPPER, _UNIT);
        uint256 v = LPPriceMath.value(a0, a1, p0, p1, _DECIMALS0, _DECIMALS1);
        // Aave V4 refuses an answer of 0; a vault token worth less than 10^-8 USD is served at the smallest price.
        return SafeCast.toInt256(Math.max(v, 1));
    }

    /// @inheritdoc ILPOracle
    function decimals() external pure override returns (uint8) {
        return _ANSWER_DECIMALS;
    }

    /// @inheritdoc ILPOracle
    function description() external view override returns (string memory) {
        return _description;
    }

    /// @inheritdoc ILPOracle
    function getPrices() external view override returns (uint256 price0, uint256 price1, uint160 sqrtPriceX96) {
        return _prices();
    }

    /// @inheritdoc ILPOracle
    function getUnitAmounts() external view override returns (uint256 amount0, uint256 amount1) {
        (,, uint160 s) = _prices();
        return LPPriceMath.amounts(s, _SQRT_LOWER, _SQRT_UPPER, _UNIT);
    }

    /// @inheritdoc ILPOracle
    function lpVault() external view override returns (address) {
        return _LP_VAULT;
    }

    /// @inheritdoc ILPOracle
    function marketId() external view override returns (uint256) {
        return _MARKET_ID;
    }

    /// @inheritdoc ILPOracle
    function band() external view override returns (int24 bandLower, int24 bandUpper) {
        return (_BAND_LOWER, _BAND_UPPER);
    }

    /// @inheritdoc ILPOracle
    function tokens() external view override returns (address token0, address token1) {
        return (_TOKEN0, _TOKEN1);
    }

    /// @inheritdoc ILPOracle
    function unitDecimals() external view override returns (uint8) {
        return _UNIT_DECIMALS;
    }

    /// @inheritdoc ILPOracle
    function feedsOf(
        uint256 index
    ) external view override returns (address[] memory feeds) {
        (address a, address b) = index == 0 ? (_FEED0A, _FEED0B) : (_FEED1A, _FEED1B);
        if (index > 1) return feeds;
        feeds = new address[](b == address(0) ? 1 : 2);
        feeds[0] = a;
        if (b != address(0)) feeds[1] = b;
    }

    /// @dev Both tokens' prices and their fair square-root price.
    function _prices() internal view returns (uint256 p0, uint256 p1, uint160 s) {
        p0 = _tokenPrice(_FEED0A, _FEED0A_DECIMALS, _FEED0B, _FEED0B_DECIMALS, _STABLE0);
        p1 = _tokenPrice(_FEED1A, _FEED1A_DECIMALS, _FEED1B, _FEED1B_DECIMALS, _STABLE1);
        s = LPPriceMath.sqrtPriceX96(p0, p1, _DECIMALS0, _DECIMALS1);
    }

    /// @dev One token's 8-decimal price: the product of its legs, capped at $1 for a USD stablecoin.
    function _tokenPrice(
        address feedA,
        uint8 decA,
        address feedB,
        uint8 decB,
        bool usdStable
    ) internal view returns (uint256 price) {
        price = _leg(feedA, decA);
        if (feedB != address(0)) price = Math.mulDiv(price, _leg(feedB, decB), LPPriceMath.PRICE_UNIT);
        if (price == 0 || price > LPPriceMath.MAX_PRICE) revert InvalidPrice(feedA);
        if (usdStable && price > LPPriceMath.STABLE_CEILING) price = LPPriceMath.STABLE_CEILING;
    }

    /// @dev The one check on a feed: a positive answer below 2^128. The round's time is not read (see DESIGN.md).
    function _leg(
        address feed,
        uint8 feedDecimals
    ) internal view returns (uint256 price) {
        // Only the answer is used.
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        price = LPPriceMath.normalize(answer, feedDecimals);
        if (price == 0) revert InvalidPrice(feed);
    }

    function _route(
        address[] memory feeds
    ) internal view returns (address a, address b, uint8 decA, uint8 decB) {
        uint256 n = feeds.length;
        if (n == 0 || n > 2) revert InvalidParams();
        a = feeds[0];
        decA = _decimalsOf(a);
        if (n == 2) {
            b = feeds[1];
            decB = _decimalsOf(b);
        }
    }

    /// @dev A token's or a feed's `decimals()` (the same selector), at most 18.
    function _decimalsOf(
        address target
    ) internal view returns (uint8 d) {
        if (target == address(0)) revert InvalidParams();
        d = IERC20Metadata(target).decimals();
        if (d > LPPriceMath.MAX_DECIMALS) revert InvalidParams();
    }
}
