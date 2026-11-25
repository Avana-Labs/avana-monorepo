// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModule} from "../../../src/RiskModule.sol";
import {ClTickMath} from "../../../src/libraries/ClTickMath.sol";

/// @title RiskModuleHarness
/// @notice The RiskModule plus a view of the tick `listPool` checks its Custom range band against, so a rule can
/// name the listing price (certora/specs/RiskModuleBands.spec).
contract RiskModuleHarness is RiskModule {
    constructor(
        address authority,
        address lpVault,
        address liquidationModule
    ) RiskModule(authority, lpVault, liquidationModule) {}

    /// @notice The tick of Aave's listing price `listPool` computes for `p`, reading the LPVault's market `marketId`
    /// for the tokens and the Spoke's price Spoke for their prices.
    function listingTickOf(
        ListPoolParams calldata p,
        uint256 marketId
    ) external view returns (int24) {
        return ClTickMath.getTickAtSqrtPrice(_listingPrice(p, _spokes[p.spoke].priceSpoke, marketId).sqrtPriceX96);
    }
}
