// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Settlement parameters of one debt asset on the chain, in base units of that asset.
struct DebtReserveParams {
    // Allowance subtracted from the recovery floor, base units.
    uint256 floorRoundingAllowance;
}

/// @notice Chainlink feed definition held by the ParameterStore, for every LPOracle leg and debt-reserve price source.
/// @dev `setFeed` pins `maxAnswer` at `min(aggregator maxAnswer, maxAnswerCap)`.
struct FeedDef {
    uint8 decimals;
    int256 minAnswer;
    int256 maxAnswer;
    // Published heartbeat, seconds.
    uint32 feedHeartbeat;
    // Freshness margin added to the heartbeat, seconds.
    uint32 heartbeatMargin;
    // Maximum age of a valid answer, seconds.
    uint32 feedMaxAge;
    // Published deviation threshold, bps.
    uint16 feedDeviationThresholdBps;
    // Heartbeat drift allowance, bps.
    uint16 heartbeatDriftBps;
    // Borrow age limit, seconds.
    uint32 borrowPriceMaxAge;
    // Liquidation age limit, seconds.
    uint32 liquidationPriceMaxAge;
    // Avana's cap on the pinned maxAnswer (raw units), recorded at listing; type(int256).max for none.
    int256 maxAnswerCap;
}

/// @notice Chain-wide parameters written by `initialize`.
struct GlobalParams {
    // Most flash premium the IFlashSource may charge, bps of the amount lent.
    uint16 maxFlashFeeBps;
    // Avana share of realized liquidation surplus, bps.
    uint16 avanaFeeShareBps;
    address feeRecipient;
    // Largest per-leg slippage raise a caller shortfall top-up can buy, bps.
    uint16 maxShortfallBps;
}

/// @notice Per-market parameters, first written by `setInitialMarketParams` in the listing batch.
struct MarketParams {
    // Slippage allowance, bps.
    uint16 slippageAllowanceBps;
    // Liveness floor of the slippage allowance, bps.
    uint16 slippageAllowanceMinBps;
    // Pool risk factor, bps.
    uint16 poolRiskFactor;
    // Minimum value of one pledge, 8-decimal USD.
    uint256 minPledgeUsd;
}

/// @notice Dynamic borrow cap terms of one market, as in the Aave ARFC "Dynamic Caps Oracle: Rate Limiter".
/// @dev The buffer is `L = clamp(alpha * D, L_min, L_max)` on the market's debt `D`; an interval's cap is `D + L`.
struct MarketDynamicCap {
    // Interval `tau`, seconds.
    uint32 capInterval;
    // `alpha`, bps of the market's debt.
    uint16 capAlphaBps;
    // `L_min`, 8-decimal USD.
    uint96 capBufferMin;
    // `L_max`, 8-decimal USD.
    uint96 capBufferMax;
}

/// @notice Addresses of the five logic contracts a ParameterStore implementation delegatecalls.
struct ParameterStoreLogics {
    // Every tighten setter (short delay).
    address tighten;
    // Every loosen setter (normal delay).
    address loosen;
    // Listing, chain, Spoke and coverage setters.
    address listing;
    // Structural feed setters and liveness-checked setters.
    address adminOracle;
    // Structural risk setters and the initial parameter write.
    address adminRisk;
}
