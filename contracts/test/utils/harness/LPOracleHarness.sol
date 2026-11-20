// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracle} from "../../../src/oracle/LPOracle.sol";
import {LPPriceMath} from "../../../src/oracle/libraries/LPPriceMath.sol";

/// @title LPOracleHarness
/// @notice The LPOracle with external wrappers of the internal `LPPriceMath` steps it prices with, so one verified
/// contract carries both the oracle's `latestAnswer` and each arithmetic step (certora/specs/LPOracle.spec).
contract LPOracleHarness is LPOracle {
    constructor(
        Params memory p
    ) LPOracle(p) {}

    function normalize(
        int256 answer,
        uint8 feedDecimals
    ) external pure returns (uint256) {
        return LPPriceMath.normalize(answer, feedDecimals);
    }

    function sqrtPriceX96(
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) external pure returns (uint160) {
        return LPPriceMath.sqrtPriceX96(p0, p1, d0, d1);
    }

    function amounts(
        uint160 s,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint128 units
    ) external pure returns (uint256 amount0, uint256 amount1) {
        return LPPriceMath.amounts(s, sqrtLower, sqrtUpper, units);
    }

    function value(
        uint256 amount0,
        uint256 amount1,
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) external pure returns (uint256) {
        return LPPriceMath.value(amount0, amount1, p0, p1, d0, d1);
    }
}
