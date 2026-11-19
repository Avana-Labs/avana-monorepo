// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorV3} from "../interfaces/external/chainlink/IAggregatorV3.sol";
import {ILegacyLPVault} from "../legacy/ILegacyLPVault.sol";
import {IParameterStore} from "../policy/parameter-store/IParameterStore.sol";
import {FeedDef} from "../policy/parameter-store/types/ParameterStoreTypes.sol";
import {AmmConstants} from "../types/AmmConstants.sol";
import {ILPOracle} from "./ILPOracle.sol";
import {LPPriceMath} from "./LPPriceMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracle
/// @notice Stateless fair-value price of one market's vault token, read by Aave V4 as the reserve's price source.
/// @dev Each read prices every token through its Chainlink route, caps USD stablecoins at $1, asks the LPVault for
/// the tokens one whole vault token holds at those prices, and sums their value rounded down. Nothing is stored after
/// construction, so there is nothing to poke, cache or recover.
contract LPOracle is ILPOracle {
    uint8 internal constant _DECIMALS = 8;
    uint256 internal constant _MAX_LEGS = 2;

    uint256 internal immutable _MARKET_ID;
    address internal immutable _INTEGRATION;
    address internal immutable _PARAMETER_STORE;
    uint8 internal immutable _VAULT_DECIMALS;

    string internal _description;
    address[] internal _tokens;
    uint8[] internal _tokenDecimals;
    bool[] internal _isUsdStable;
    address[][] internal _feeds;
    uint8[][] internal _feedDecimals;

    /// @dev Reverts `InvalidMarket` unless every token is readable, unique and has a 1- or 2-leg route.
    constructor(
        Params memory p
    ) {
        uint256 n = p.routes.length;
        if (
            p.marketId == 0 || p.integration == address(0) || p.parameterStore == address(0)
                || n < AmmConstants.MIN_POOL_TOKENS || n > AmmConstants.MAX_POOL_TOKENS
        ) revert InvalidMarket(p.marketId);
        (_MARKET_ID, _INTEGRATION, _PARAMETER_STORE, _description) =
        (p.marketId, p.integration, p.parameterStore, p.description);
        // Each token's and leg's decimals are read once here; a bad route refuses the whole deployment.
        // forge-lint: disable-start(calls-loop)
        // forge-lint: disable-start(require-revert-in-loop)
        for (uint256 i = 0; i < n; ++i) {
            TokenRoute memory r = p.routes[i];
            uint256 legs = r.feeds.length;
            if (r.token == address(0) || legs == 0 || legs > _MAX_LEGS) revert InvalidMarket(p.marketId);
            for (uint256 j = 0; j < i; ++j) {
                if (_tokens[j] == r.token) revert InvalidMarket(p.marketId);
            }
            uint8 dec = IERC20Metadata(r.token).decimals();
            if (dec > LPPriceMath.MAX_TOKEN_DECIMALS) revert InvalidMarket(p.marketId);
            uint8[] memory fd = new uint8[](legs);
            for (uint256 k = 0; k < legs; ++k) {
                if (r.feeds[k] == address(0)) revert InvalidMarket(p.marketId);
                fd[k] = IAggregatorV3(r.feeds[k]).decimals();
            }
            _tokens.push(r.token);
            _tokenDecimals.push(dec);
            _isUsdStable.push(r.isUsdStable);
            _feeds.push(r.feeds);
            _feedDecimals.push(fd);
        }
        // forge-lint: disable-end(require-revert-in-loop)
        // forge-lint: disable-end(calls-loop)
        if (p.vaultDecimals < LPPriceMath.MIN_VAULT_DECIMALS || p.vaultDecimals > LPPriceMath.MAX_VAULT_DECIMALS) {
            revert InvalidMarket(p.marketId);
        }
        _VAULT_DECIMALS = p.vaultDecimals;
    }

    /// @inheritdoc ILPOracle
    function latestAnswer() external view override returns (int256 answer) {
        (answer,) = _evaluate();
    }

    /// @inheritdoc ILPOracle
    function decimals() external pure override returns (uint8) {
        return _DECIMALS;
    }

    /// @inheritdoc ILPOracle
    function description() external view override returns (string memory) {
        return _description;
    }

    /// @inheritdoc ILPOracle
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        uint64 at;
        (answer, at) = _evaluate();
        return (0, answer, at, at, 0);
    }

    /// @inheritdoc ILPOracle
    function getTokenPrices() external view override returns (uint256[] memory prices, uint64 updatedAt) {
        (prices, updatedAt,,) = _prices(false);
    }

    /// @inheritdoc ILPOracle
    function getPriceStatus() external view override returns (PriceStatus memory status) {
        uint256[] memory prices;
        (prices, status.updatedAt, status.borrowFresh, status.liquidationFresh) = _prices(true);
        status.answer = _value(prices);
    }

    /// @inheritdoc ILPOracle
    function feedsOf(
        uint256 index
    ) external view override returns (address[] memory feeds) {
        return _feeds[index];
    }

    /// @inheritdoc ILPOracle
    function tokens() external view override returns (address[] memory list) {
        return _tokens;
    }

    /// @inheritdoc ILPOracle
    function marketId() external view override returns (uint256) {
        return _MARKET_ID;
    }

    /// @inheritdoc ILPOracle
    function integration() external view override returns (address) {
        return _INTEGRATION;
    }

    /// @inheritdoc ILPOracle
    function parameterStore() external view override returns (address) {
        return _PARAMETER_STORE;
    }

    /// @inheritdoc ILPOracle
    function vaultDecimals() external view override returns (uint8) {
        return _VAULT_DECIMALS;
    }

    function _evaluate() internal view returns (int256 answer, uint64 updatedAt) {
        uint256[] memory prices;
        (prices, updatedAt,,) = _prices(false);
        answer = _value(prices);
    }

    /// @dev Every token's valuation price and the oldest leg; with `ages`, also the gates' freshness. Reverts
    /// `InvalidPrice` on a failed leg.
    function _prices(
        bool ages
    ) internal view returns (uint256[] memory prices, uint64 updatedAt, bool borrowOk, bool liquidationOk) {
        uint256 n = _tokens.length;
        prices = new uint256[](n);
        (updatedAt, borrowOk, liquidationOk) = (type(uint64).max, true, true);
        // Every leg is read on every price; a leg that cannot be read reverts the read, as an unreadable Chainlink source
        // does for Aave.
        // forge-lint: disable-start(calls-loop)
        // forge-lint: disable-start(require-revert-in-loop)
        // forge-lint: disable-start(unused-return)
        for (uint256 i = 0; i < n; ++i) {
            address[] storage feeds = _feeds[i];
            uint256 price = LPPriceMath.PRICE_UNIT;
            for (uint256 k = 0; k < feeds.length; ++k) {
                address feed = feeds[k];
                (, int256 raw,, uint256 at,) = IAggregatorV3(feed).latestRoundData();
                uint256 leg = LPPriceMath.normalizeAnswer(raw, _feedDecimals[i][k]);
                if (leg == 0 || at > block.timestamp) revert InvalidPrice(feed);
                price = Math.mulDiv(price, leg, LPPriceMath.PRICE_UNIT);
                if (at < updatedAt) updatedAt = SafeCast.toUint64(at);
                if (ages) {
                    FeedDef memory d = IParameterStore(_PARAMETER_STORE).getFeed(feed);
                    borrowOk = borrowOk && LPPriceMath.borrowFresh(at, d.borrowPriceMaxAge);
                    liquidationOk = liquidationOk && LPPriceMath.liquidationFresh(at, d.liquidationPriceMaxAge);
                }
            }
            if (price == 0 || price > LPPriceMath.MAX_ROUTE_ANSWER) revert InvalidPrice(feeds[0]);
            prices[i] = LPPriceMath.valuationPrice(price, _isUsdStable[i]);
        }
        // forge-lint: disable-end(unused-return)
        // forge-lint: disable-end(require-revert-in-loop)
        // forge-lint: disable-end(calls-loop)
    }

    /// @dev USD value of one whole vault token at `prices`.
    function _value(
        uint256[] memory prices
    ) internal view returns (int256) {
        return SafeCast.toInt256(_priceOf(10 ** uint256(_VAULT_DECIMALS), prices));
    }

    function _priceOf(
        uint256 units,
        uint256[] memory prices
    ) internal view returns (uint256 price8) {
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory amounts,) = ILegacyLPVault(_INTEGRATION).composition(_MARKET_ID, units, prices);
        bool valid;
        (valid, price8) = LPPriceMath.lpPrice(amounts, prices, _tokenDecimals);
        if (!valid) revert InvalidComposition(_MARKET_ID);
    }
}
