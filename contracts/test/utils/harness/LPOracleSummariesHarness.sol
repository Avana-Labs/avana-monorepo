// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title LPOracleSummariesHarness
/// @notice External wrappers of the library functions certora/specs/LPOracle.spec summarises, so
/// certora/specs/LPOracleSummaries.spec can prove each summary against the library bytecode.
contract LPOracleSummariesHarness {
    function ozMulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) external pure returns (uint256) {
        return Math.mulDiv(x, y, denominator);
    }

    function fullMathMulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, denominator);
    }

    function ozSqrt(
        uint256 a
    ) external pure returns (uint256) {
        return Math.sqrt(a);
    }
}
