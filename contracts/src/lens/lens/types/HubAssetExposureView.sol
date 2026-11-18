// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpokeKind} from "./SpokeKind.sol";

/// @notice One Spoke's slice of a Hub asset: its draw on the (Hub, asset) line and its supply.
/// @dev Amounts in the asset's base units, shares as the Hub stores them.
struct SpokeDraw {
    address spoke;
    address homeHub;
    uint256 drawCap;
    uint256 drawn;
    uint256 deficit;
    SpokeKind kind;
    // Added assets (`getSpokeAddedAssets`), rounded down.
    uint256 added;
    uint256 addedShares;
    // Add cap, whole asset units as the Hub stores it (`type(uint40).max` means none).
    uint256 addCap;
    // Drawn part of `drawn` (`getSpokeOwed`).
    uint256 drawnOwed;
    // Premium part of `drawn` (`getSpokeOwed`).
    uint256 premiumOwed;
    uint256 drawnShares;
    uint256 premiumShares;
    bool active;
    bool halted;
}

/// @notice Exposure of one (Hub, asset) pair across every Spoke that draws on it, with its first-loss coverage.
/// @dev `uncovered` is `ILensRisk.uncoveredDeficit(hub, asset)`; `priceAdj` is the deficit-adjusted share price.
struct HubAssetExposureView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address asset;
    address firstLossReserve;
    uint256 fundedBalance;
    uint256 line;
    bool coverageBoundHolds;
    uint256 uncovered;
    uint256 priceAdj;
    SpokeDraw[] spokes;
    address deficitOffset;
    uint256 offsetFunded;
}
