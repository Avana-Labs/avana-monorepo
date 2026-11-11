// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ShapeKind} from "../../types/ShapeKind.sol";
import {FeeMode} from "./FeeMode.sol";
import {PoolKeying} from "./PoolKeying.sol";
import {PricingMode} from "./PricingMode.sol";

/// @notice Fixed description of an AMM integration, returned by `IAmmIntegration.capabilities()`.
/// @dev Constant for the life of the integration (all LPVaults are immutable). The MarketRegistry reads it at listing
/// to choose the hooks it requires: `hasTwap == false` means the consistency check is off and the per-block
/// quote-change cap is the only spot guard; `reentrancyGuarded` means every read first calls `checkReadSafe`;
/// `nativeToken` means a pool leg is native ETH, carried everywhere in Avana as the wrapped token; `rateTokens`
/// means pool balances are scaled by per-token rate providers.
/// @custom:spec REQ-AMM-CORE-009, REQ-AMM-CORE-010, REQ-AMM-CORE-011, REQ-AMM-CORE-012, REQ-AMM-CORE-013, REQ-ORACLE-103, Q-371
struct IntegrationCapabilities {
    // Pool identification.
    PoolKeying poolKeying;
    // Fee payment.
    FeeMode feeMode;
    // Composition exactness.
    PricingMode pricingMode;
    // Position shape the integration custodies.
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
