// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Chain-wide parameters written by `initialize`.
struct GlobalParams {
    // Cached-state length, seconds.
    uint32 cachedWindow;
    // Maximum disagreement liquidation pause, seconds.
    uint32 disagreementPauseMax;
    // Lower USD band level, 8 decimals per 1 USD at peg.
    uint256 usdBandLow;
    // Upper USD band level, 8 decimals per 1 USD at peg.
    uint256 usdBandHigh;
    // Recovery grace length, seconds.
    uint32 graceDuration;
    // HF below which liquidation is allowed during grace, WAD (< 1e18).
    uint256 graceHealthFactor;
    // Most flash premium the IFlashSource may charge, bps of the amount lent.
    uint16 maxFlashFeeBps;
    // Avana share of realized liquidation surplus, bps.
    uint16 avanaFeeShareBps;
    address feeRecipient;
    // Margin added to the feed-agreement lower bound, bps.
    uint16 feedAgreementMarginBps;
    // Healthy-observation window before a temporary gate reopens, seconds.
    uint64 gateRecoverySeconds;
    // Largest per-leg slippage raise a caller shortfall top-up can buy, bps.
    uint16 maxShortfallBps;
}
