// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../../src/types/PriceState.sol";
import {TokenPriceView} from "../../../src/types/TokenPriceView.sol";
import {RiskDebtOracleMock, RiskLPOracleMock} from "./RiskModuleMocks.sol";

/// @notice An LPOracle for every reader of the integration world: the RiskModule's report (`RiskLPOracleMock`) with
/// the served price, the accepted price and the per-token valuation prices kept equal across `latestAnswer`,
/// `lastAcceptedPrice`, `getPriceState` and `getTokenPrices`, and it is the AaveOracle source of its vault-token
/// reserve, so Aave, LPVaultSwap, the RiskModule and the Lens read one price.
contract IntegLPOracleMock is RiskLPOracleMock {
    constructor(
        uint256 id,
        address amm
    ) RiskLPOracleMock(id, amm) {}

    /// @notice Sets the served and accepted price (8 decimals).
    function setAnswer(
        int256 answer
    ) external {
        _pv.answer = answer;
        _pv.acceptedAnswer = answer;
        _pv.freshAnswer = answer;
        // A non-positive answer is a failed read; the accepted price keeps its last positive value.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (answer > 0) accepted = uint256(answer);
    }

    /// @notice One-leg report per token at `at`, valuation and quote `prices[i]`.
    function setTokenReport(
        address[] calldata tokens,
        address[] calldata feeds,
        uint256[] calldata prices,
        uint64 at
    ) external {
        delete _pv.tokens;
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenPriceView storage t = _pv.tokens.push();
            t.token = tokens[i];
            t.legFeeds[0] = feeds[i];
            t.legUpdatedAt[0] = at;
            t.updatedAt = at;
            t.quote = prices[i];
            t.valuationPrice = prices[i];
            t.routeUsed = 1;
        }
        _pv.servedUpdatedAt = at;
        _pv.acceptedUpdatedAt = at;
    }

    /// @notice Sets token `token`'s quote and valuation price (8 decimals), as a new round of its feed would.
    function setTokenPrice(
        address token,
        uint256 price8
    ) external {
        for (uint256 i = 0; i < _pv.tokens.length; ++i) {
            if (_pv.tokens[i].token == token) (_pv.tokens[i].quote, _pv.tokens[i].valuationPrice) = (price8, price8);
        }
    }

    /// @notice Moves every leg's `updatedAt` to `at` (fresh feed rounds).
    function refresh(
        uint64 at
    ) external {
        for (uint256 i = 0; i < _pv.tokens.length; ++i) {
            _pv.tokens[i].legUpdatedAt[0] = at;
            _pv.tokens[i].updatedAt = at;
        }
        _pv.servedUpdatedAt = at;
        _pv.acceptedUpdatedAt = at;
    }

    function setFlags(
        bool liquidationPaused,
        bool disagreementPauseActive,
        bool inGrace
    ) external {
        (_pv.liquidationPaused, _pv.disagreementPauseActive, _pv.inGrace) =
        (liquidationPaused, disagreementPauseActive, inGrace);
    }

    function getTokenPrices() external view returns (uint256[] memory prices, uint64 servedUpdatedAt, PriceState s) {
        prices = new uint256[](_pv.tokens.length);
        for (uint256 i = 0; i < prices.length; ++i) {
            prices[i] = _pv.tokens[i].valuationPrice;
        }
        return (prices, _pv.servedUpdatedAt, _pv.state);
    }
}

/// @notice A non-fixed debt reserve's DebtOracle for every reader: identity and report of `RiskDebtOracleMock`, the
/// served answer the AaveOracle reads, one leg checked against `liquidationPriceMaxAge`, and the accepted price.
contract IntegDebtOracleMock is RiskDebtOracleMock {
    constructor(
        address asset,
        address registry,
        address store,
        address feed,
        int256 answer
    ) RiskDebtOracleMock(asset, registry, store) {
        _dv.legFeeds[0] = feed;
        _dv.legUpdatedAt[0] = uint64(block.timestamp);
        _setAnswer(answer);
    }

    function setAnswer(
        int256 answer
    ) external {
        _setAnswer(answer);
    }

    /// @notice A new round of the feed at `updatedAt`, accepted (the accepted price's source timestamp follows the
    /// serving leg while the oracle is Live).
    function setLeg(
        uint64 updatedAt
    ) external {
        _dv.legUpdatedAt[0] = updatedAt;
        _dv.servedUpdatedAt = updatedAt;
        _dv.acceptedUpdatedAt = updatedAt;
    }

    function setLiquidationPaused(
        bool on
    ) external {
        _dv.liquidationPaused = on;
    }

    /// @notice The accepted price's stored source timestamp alone, as when the feed has posted rounds since the last
    /// poke: the served route and its leg keep their own timestamps.
    function setAcceptedAt(
        uint64 at
    ) external {
        _dv.acceptedUpdatedAt = at;
    }

    function lastAcceptedPrice() external view returns (uint256, uint64) {
        return (_dv.acceptedAnswer, _dv.acceptedUpdatedAt);
    }

    function _setAnswer(
        int256 answer
    ) internal {
        latestAnswer = answer;
        _dv.answer = answer;
        // Positive answers only (a non-positive one is a failed read).
        // forge-lint: disable-next-line(unsafe-typecast)
        if (answer > 0) _dv.acceptedAnswer = uint256(answer);
        _dv.acceptedUpdatedAt = uint64(block.timestamp);
    }
}
