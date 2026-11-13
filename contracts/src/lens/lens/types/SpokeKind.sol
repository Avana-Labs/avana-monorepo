// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The role of a Spoke registered on a Hub asset (REQ-LENS-059).
/// @dev `Cdp`: an Avana CDP Spoke (`MarketRegistry.hubOf(spoke) != 0`); `Coverage`: the asset's Coverage Spoke
/// (`coverageSpokeOf(hub, asset)`); `FeeReceiver`: the asset's fee receiver (`getAssetConfig(assetId).feeReceiver`);
/// `Lend`: any other Spoke of a lend asset, which REQ-HUB-015 makes the chain's Lend Spoke; `Other`: any other Spoke
/// of a market's vault-token asset, which the backing check reports; `DeficitOffset`: the asset's DAO deficit offset,
/// a Spoke whose `FIRST_LOSS_LAYER()` returns the asset's Coverage Spoke (REQ-FLR-046).
/// @custom:spec REQ-LENS-059, REQ-HUB-015, REQ-FLR-046
enum SpokeKind {
    Lend,
    Cdp,
    Coverage,
    FeeReceiver,
    Other,
    DeficitOffset
}
