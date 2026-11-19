// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FloorCreditMath} from "../../../src/custody/lp-vault/libraries/FloorCreditMath.sol";

/// @title FloorCreditMathHarness
/// @notice External wrappers of the internal `FloorCreditMath` functions, so suites can call them across a message call
/// (`vm.expectRevert` needs one) and read their reverts.
contract FloorCreditMathHarness {
    function credit(
        int24 tickLower,
        int24 tickUpper,
        int24 bandLower,
        int24 bandUpper,
        uint128 liquidity
    ) external pure returns (uint128) {
        return FloorCreditMath.credit(tickLower, tickUpper, bandLower, bandUpper, liquidity);
    }

    function creditAtSqrtPrices(
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint160 sqrtBandLower,
        uint160 sqrtBandUpper,
        uint128 liquidity
    ) external pure returns (uint128) {
        return FloorCreditMath.creditAtSqrtPrices(sqrtLower, sqrtUpper, sqrtBandLower, sqrtBandUpper, liquidity);
    }
}
