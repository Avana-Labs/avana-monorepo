// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AmmConstants} from "../types/AmmConstants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LegacyPriceMath
/// @notice Pure arithmetic of the LP price: Chainlink answers to 8 decimals, the stable ceiling, the value of a
/// composition and the age rules the borrow and liquidation gates apply.
/// @dev Fails closed (0 or `valid = false`) instead of reverting; prices round down.
library LegacyPriceMath {
    uint8 internal constant DECIMALS = 8;
    uint256 internal constant PRICE_UNIT = 1e8;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant STABLE_CEILING_USD = 1e8;
    /// @notice Largest token price the oracle serves; small enough that no price-path product overflows.
    uint256 internal constant MAX_ROUTE_ANSWER = 1e18;
    /// @notice Exclusive upper bound of a raw answer and of a composition amount.
    uint256 internal constant ANSWER_BOUND = 2 ** 128;
    uint8 internal constant MIN_VAULT_DECIMALS = 6;
    uint8 internal constant MAX_VAULT_DECIMALS = 18;
    /// @notice Largest token decimals `lpPrice` accepts: `10^77 < 2^256 < 10^78`.
    uint8 internal constant MAX_TOKEN_DECIMALS = 77;
    /// @notice Value of a bound or product that would need more than 256 bits.
    uint256 internal constant SATURATED = type(uint256).max;

    /// @notice `timestamp − updatedAt`, 0 for a timestamp in the future.
    function age(
        uint256 updatedAt
    ) internal view returns (uint256) {
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    /// @notice Borrow-side age rule: not in the future and `age ≤ maxAge`.
    function borrowFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge;
    }

    /// @notice Liquidation-side age rule: `age ≤ maxAge`, with a future timestamp counted as age 0.
    function liquidationFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return age(updatedAt) <= maxAge;
    }

    /// @notice 8-decimal value of a signed Chainlink answer with `decimals` decimals, rounded down.
    /// @dev 0 (a failure, never a price) for `answer <= 0` or `answer >= 2^128`.
    function normalizeAnswer(
        int256 answer,
        uint8 decimals
    ) internal pure returns (uint256 normalized) {
        if (answer <= 0) return 0;
        uint256 a = SafeCast.toUint256(answer);
        if (a >= ANSWER_BOUND) return 0;
        if (decimals <= DECIMALS) return a * 10 ** (DECIMALS - decimals);
        return decimals - DECIMALS > MAX_TOKEN_DECIMALS ? 0 : a / 10 ** (decimals - DECIMALS);
    }

    /// @notice The price a token is valued at: its quote, capped at $1 for a USD stablecoin.
    function valuationPrice(
        uint256 quote,
        bool isUsdStable
    ) internal pure returns (uint256 price) {
        return isUsdStable && quote > STABLE_CEILING_USD ? STABLE_CEILING_USD : quote;
    }

    /// @notice Price of one whole vault token from its composition: `max(1, sum_i floor((a_i - 1) * v_i / 10^d_i))`.
    /// @dev Rounds down, so the price never exceeds the holdings' value. `valid = false` for malformed inputs.
    function lpPrice(
        uint256[] memory amounts,
        uint256[] memory prices,
        uint8[] memory tokenDecimals
    ) internal pure returns (bool valid, uint256 price8) {
        uint256 n = amounts.length;
        if (n < AmmConstants.MIN_POOL_TOKENS || n > AmmConstants.MAX_POOL_TOKENS) return (false, 0);
        if (prices.length != n || tokenDecimals.length != n) return (false, 0);
        for (uint256 i = 0; i < n; ++i) {
            uint256 a = amounts[i];
            uint8 d = tokenDecimals[i];
            if (a >= ANSWER_BOUND || prices[i] == 0 || prices[i] > MAX_ROUTE_ANSWER || d > MAX_TOKEN_DECIMALS) {
                return (false, 0);
            }
            if (a > 1) price8 += Math.mulDiv(a - 1, prices[i], 10 ** d);
        }
        return (true, price8 == 0 ? 1 : price8);
    }

    /// @notice Observation buffer a pool needs for a window: `ceil(window / blockTime) + 1`.
    /// @dev A block time of 0 saturates, so the listing check fails closed.
    function minObservations(
        uint256 window,
        uint256 blockTime
    ) internal pure returns (uint256 observations) {
        if (blockTime == 0) return SATURATED;
        uint256 k = Math.ceilDiv(window, blockTime);
        return k == SATURATED ? SATURATED : k + 1;
    }
}
