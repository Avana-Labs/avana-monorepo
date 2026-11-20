// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClTickMath} from "../../../src/integrations/shared/ClTickMath.sol";
import {RiskModule} from "../../../src/risk/RiskModule.sol";

/// @title RiskModuleHarness
/// @notice The RiskModule plus a view of the tick `listPool` checks its Custom range band against, so a rule can
/// name the listing price (certora/specs/RiskModuleBands.spec).
contract RiskModuleHarness is RiskModule {
    constructor(
        address authority,
        address lpVault,
        address liquidationModule
    ) RiskModule(authority, lpVault, liquidationModule) {}

    /// @notice The tick of the Chainlink listing price `listPool` computes for `p`, reading the LPVault's market
    /// `marketId` for the token decimals.
    function listingTickOf(
        ListPoolParams calldata p,
        uint256 marketId
    ) external view returns (int24) {
        return ClTickMath.getTickAtSqrtPrice(_listingPrice(p, marketId).sqrtPriceX96);
    }
}
