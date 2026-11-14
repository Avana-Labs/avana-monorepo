// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpokeKind} from "./SpokeKind.sol";

/// @notice One Spoke's slice of a Hub asset: its draw on the (Hub, asset) line and its supply.
/// @dev Amounts in the asset's base units, shares as the Hub stores them. Over every Spoke of the asset in one block the
/// slices add up to the Hub: added shares, drawn shares and premium shares exactly; added assets to at most the Hub's
/// added assets and owed to at least the Hub's owed, each within one unit per Spoke (REQ-LENS-059).
/// @custom:spec REQ-LENS-043, REQ-LENS-059
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
    // The Spoke's role on the asset.
    SpokeKind kind;
    // Added assets (`getSpokeAddedAssets`), rounded down.
    uint256 added;
    // Added shares.
    uint256 addedShares;
    // Add cap, whole asset units as the Hub stores it (`type(uint40).max` means none).
    uint256 addCap;
    // Drawn part of `drawn` (`getSpokeOwed`).
    uint256 drawnOwed;
    // Premium part of `drawn` (`getSpokeOwed`).
    uint256 premiumOwed;
    // Drawn shares.
    uint256 drawnShares;
    // Premium shares.
    uint256 premiumShares;
    // The Hub lets the Spoke act.
    bool active;
    // The Hub halts the Spoke's liquidity-changing actions.
    bool halted;
}

/// @notice Exposure of one (Hub, asset) pair across every Spoke that draws on it, with its first-loss coverage.
/// @dev `coverageBoundHolds` is the `REQ-CONFIG-081` check `line × 10^dec × coverageRatioBps <= fundedBalance × 1e4`;
/// `uncovered` is `ILensRisk.uncoveredDeficit(hub, asset)`; `priceAdj` is the deficit-adjusted share price
/// `floor((A - uncovered) × 10^dec / Sh)` with `A` the Hub's added assets and `Sh` its added shares of the asset (0 when
/// no share exists), asset base units per whole share. `spokes` lists every Spoke registered on the Hub's asset.
/// `blockNumber` and `timestamp` are the block read (REQ-LENS-005). `fundedBalance` is the First-Loss Reserve's (the first
/// loss layer, which the coverage bound tests); `deficitOffset` is the pair's DAO deficit offset (the first listed Spoke
/// whose `FIRST_LOSS_LAYER()` is `firstLossReserve`, 0 when none) and `offsetFunded` the added assets of every such Spoke,
/// the second loss layer, which `uncovered` subtracts too.
/// @custom:spec REQ-LENS-043, REQ-LENS-042, REQ-LENS-005, REQ-CONFIG-081, REQ-FLR-046
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
