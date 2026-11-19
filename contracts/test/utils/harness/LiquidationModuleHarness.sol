// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationModule} from "../../../src/liquidation/liquidation-module/LiquidationModule.sol";
import {LiquidationMath} from "../../../src/liquidation/liquidation-module/libraries/LiquidationMath.sol";

/// @title LiquidationModuleHarness
/// @notice The LiquidationModule with external wrappers of the internal `LiquidationMath` steps, so one verified
/// contract carries both `liquidate` and each arithmetic step (certora/specs/LiquidationModule.spec).
contract LiquidationModuleHarness is LiquidationModule {
    constructor(
        address riskModule
    ) LiquidationModule(riskModule) {}

    function feeUnits(
        uint256 seized,
        uint256 bonusBps,
        uint256 feeShareBps
    ) external pure returns (uint256) {
        return LiquidationMath.feeUnits(seized, bonusBps, feeShareBps);
    }

    function creditFor(
        uint256 units,
        uint256 credit,
        uint256 cap
    ) external pure returns (uint256) {
        return LiquidationMath.creditFor(units, credit, cap);
    }

    function feePart(
        uint256 amount,
        uint256 fee,
        uint256 seized
    ) external pure returns (uint256) {
        return LiquidationMath.feePart(amount, fee, seized);
    }
}
