// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpokeDraw} from "./HubAssetExposureView.sol";

/// @notice One Hub asset with its totals, rates, rate curve, price and one slice per Spoke (REQ-LENS-058).
/// @dev Amounts in the asset's base units. `liquidity` is the Hub's available liquidity of the asset
/// (`getAssetLiquidity`), the bound of every draw and withdrawal, which is not `added − owed`: the Hub holds
/// `added + accruedFees = liquidity + swept + owed + deficit` (each read rounds, so the two sides differ by a few
/// units). `owed = drawn + premium`; `deficit` rounded up; `utilizationBps` and `supplyRateRay` as REQ-LENS-046, rounded
/// down; rates RAY per year; strategy parameters bps. `lendSpoke` is the first Spoke of kind `Lend` (0 when none) and
/// `priceUsd8` its AaveOracle's price of the asset (8 decimals, 0 without a Lend Spoke), the one USD price of the
/// asset. `spokes` lists every Spoke registered on the asset in the Hub's order.
/// @custom:spec REQ-LENS-058, REQ-LENS-059, REQ-LENS-005
struct HubAssetView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    uint256 assetId;
    address underlying;
    uint8 decimals;
    uint256 added;
    uint256 addedShares;
    uint256 drawn;
    uint256 premium;
    uint256 owed;
    uint256 drawnShares;
    uint256 premiumShares;
    uint256 liquidity;
    uint256 swept;
    uint256 deficit;
    uint256 accruedFees;
    uint256 utilizationBps;
    uint256 drawnRateRay;
    uint256 supplyRateRay;
    uint256 liquidityFeeBps;
    address feeReceiver;
    address irStrategy;
    uint256 optimalUsageBps;
    uint256 baseDrawnRateBps;
    uint256 rateGrowthBeforeOptimalBps;
    uint256 rateGrowthAfterOptimalBps;
    address lendSpoke;
    uint256 priceUsd8;
    SpokeDraw[] spokes;
}
