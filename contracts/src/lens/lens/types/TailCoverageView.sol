// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Cap-based tail coverage of the First-Loss Reserve of one (funding Hub, debt asset) pair.
/// @dev USD values 8 decimals; `ratioBps` measures `funded` alone, max when `tailUsd == 0`.
struct TailCoverageView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address debtAsset;
    address firstLossReserve;
    uint256 funded;
    uint256 minimum;
    uint256 fundedUsd;
    uint256 drawCapUsd;
    address worstToken;
    uint256 tailUsd;
    uint256 ratioBps;
    address deficitOffset;
    uint256 offsetFunded;
}
