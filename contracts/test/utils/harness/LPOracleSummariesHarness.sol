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

    /// @notice The 512-bit product `x * y` as `(hi, lo)`, by schoolbook multiplication of 128-bit halves (no partial
    /// product overflows), so the spec can state a 512-bit fact with 256-bit words.
    function mul512(
        uint256 x,
        uint256 y
    ) external pure returns (uint256 hi, uint256 lo) {
        unchecked {
            uint256 m = type(uint128).max;
            uint256 xl = x & m;
            uint256 xh = x >> 128;
            uint256 yl = y & m;
            uint256 yh = y >> 128;
            uint256 ll = xl * yl;
            uint256 mid = xl * yh;
            uint256 hl = xh * yl;
            uint256 carryMid = 0;
            mid += hl;
            if (mid < hl) carryMid = 1;
            lo = ll + (mid << 128);
            uint256 carryLo = lo < ll ? 1 : 0;
            hi = xh * yh + (mid >> 128) + (carryMid << 128) + carryLo;
        }
    }

    /// @notice `mulmod(x, y, m)`, 0 for `m == 0` (the opcode's value) instead of Solidity's panic.
    function mulMod(
        uint256 x,
        uint256 y,
        uint256 m
    ) external pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := mulmod(x, y, m)
        }
    }
}
