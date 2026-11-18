// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ShapeKind} from "../../types/PositionTypes.sol";

/// @notice Integration-specific configuration of a concentrated-liquidity market, stored by `bindMarket`.
/// @dev Read on-chain at listing and never changed.
struct ClMarketConfig {
    address pool;
    address positionManager;
    address factory;
    address token0;
    address token1;
    // Uniswap v3: the fee tier, pips. Slipstream: always 0 (its fee is dynamic).
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint128 maxLiquidityPerTick;
}

/// @notice How an AMM protocol pays trading fees to a position: collected separately, or rolled into the reserves.
/// @dev Ordinal values are fixed.
enum FeeMode {
    Separate,
    RolledIn
}

/// @notice Fixed description of an AMM integration, returned by `ILPVault.capabilities()`.
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

/// @notice How an AMM protocol identifies a pool.
/// @dev `Address`: a pool contract address. `Id`: a `bytes32` identifier inside a singleton. Ordinal values are fixed.
enum PoolKeying {
    Address,
    Id
}

/// @notice Whether an AMM protocol's composition at an oracle price vector is exact.
/// @dev Ordinal values are fixed.
enum PricingMode {
    ClosedForm,
    LowerBound
}

/// @notice Risk metadata of one market and, optionally, one position, returned by `ILPVault.riskMetadata`.
/// @dev `avanaUnits` and `poolShareBps` are always 0: LPVaults keep no unit counter.
struct RiskMetadata {
    bool inRange;
    bool readSafe;
    uint256 avanaUnits;
    uint256 poolUnits;
    uint256 poolShareBps;
    // 0 when no position is named.
    uint128 positionUnits;
}

/// @notice Time-weighted pool depth of one market, returned by `ILPVault.riskStatus`.
struct RiskStatus {
    // Time-weighted depth over the window, the market's units.
    uint256 depthUnits;
    // False when the AMM protocol keeps no history covering the window.
    bool depthAvailable;
}
