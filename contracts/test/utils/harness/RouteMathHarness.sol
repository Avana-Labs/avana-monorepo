// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMath} from "../../../src/liquidation/settlement-routes/RouteMath.sol";

/// @title RouteMathHarness
/// @notice External wrappers of the internal `RouteMath` functions, so fuzz, Halmos and property suites can call them.
contract RouteMathHarness {
    function litePsmGemAmt(
        uint256 dai,
        uint256 tout,
        uint256 conversion
    ) external pure returns (uint256) {
        return RouteMath.litePsmGemAmt(dai, tout, conversion);
    }

    function litePsmCost(
        uint256 gemAmt,
        uint256 tout,
        uint256 conversion
    ) external pure returns (uint256) {
        return RouteMath.litePsmCost(gemAmt, tout, conversion);
    }
}
