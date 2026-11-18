// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ShapeKind} from "../../types/ShapeKind.sol";
import {FeeMode} from "./FeeMode.sol";
import {PoolKeying} from "./PoolKeying.sol";
import {PricingMode} from "./PricingMode.sol";

/// @notice Fixed description of an AMM integration, returned by `IAmmIntegration.capabilities()`.
struct IntegrationCapabilities {
    PoolKeying poolKeying;
    FeeMode feeMode;
    PricingMode pricingMode;
    ShapeKind shapeKind;
    // The AMM protocol offers a time-weighted price for the consistency check.
    bool hasTwap;
    // Reads need a pool reentrancy-lock check.
    bool reentrancyGuarded;
    // A pool leg can be native ETH.
    bool nativeToken;
    // Pool balances are scaled by rate providers.
    bool rateTokens;
}
