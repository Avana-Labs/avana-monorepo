// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One CDP Spoke's draw on a (Hub, asset) line.
/// @custom:spec REQ-LENS-043
struct SpokeDraw {
    // CDP Spoke.
    address spoke;
    // The Spoke's home Hub.
    address homeHub;
    // The Spoke's draw cap on the line, base units.
    uint256 drawCap;
    // Drawn amount, base units.
    uint256 drawn;
    // Recorded deficit of the Spoke on the Hub, base units.
    uint256 deficit;
}

/// @notice Exposure of one (Hub, asset) pair across every Spoke that draws on it, with its first-loss coverage.
/// @dev `coverageBoundHolds` is the `REQ-CONFIG-081` check `line × 10^dec × coverageRatioBps <= fundedBalance × 1e4`;
/// `uncovered` is `ILensRisk.uncoveredDeficit(hub, asset)`; `priceAdj` is the deficit-adjusted share price
/// `floor((A - uncovered) × 10^dec / Sh)` with `A` the Hub's added assets and `Sh` its added shares of the asset (0 when
/// no share exists), asset base units per whole share. `spokes` lists every Spoke registered on the Hub's asset.
/// `blockNumber` and `timestamp` are the block read (REQ-LENS-005).
/// @custom:spec REQ-LENS-043, REQ-LENS-005, REQ-CONFIG-081
struct HubAssetExposureView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address asset;
    address coverageSpoke;
    uint256 fundedBalance;
    uint256 line;
    bool coverageBoundHolds;
    uint256 uncovered;
    uint256 priceAdj;
    SpokeDraw[] spokes;
}
