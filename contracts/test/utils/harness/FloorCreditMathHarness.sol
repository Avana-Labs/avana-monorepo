// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FloorCreditMath} from "../../../src/vault/libraries/FloorCreditMath.sol";

/// @title FloorCreditMathHarness
/// @notice External wrapper of the internal `FloorCreditMath.credit`, so suites can call it across a message call
/// (`vm.expectRevert` needs one) and read its reverts.
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
}
