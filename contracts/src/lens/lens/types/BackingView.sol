// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Market-level backing and Aave configuration check: raw values and pass/fail flags.
/// @dev Hub values are the market's home Hub's; `stranded` never counts as backing.
struct BackingView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 marketId;
    address hub;
    address vaultToken;
    uint256 assetId;
    uint256 reserveId;
    uint256 totalSupply;
    uint256 totalCredited;
    uint256 pendingUnits;
    uint256[] pendingAmounts;
    uint256 unsettledSeizedUnits;
    uint256 hubBalance;
    uint256 hubLiquidity;
    uint256 stranded;
    uint256 addedAssets;
    uint256 addedShares;
    uint256 drawnShares;
    bool supplyEqualsCredited;
    bool hubHoldsSupplied;
    bool sharesEqualAssets;
    bool noDrawnShares;
    bool noDrawCap;
    bool singleBorrowSpoke;
    bool noLiquidityFee;
    bool noReinvestment;
    bool reserveFlags;
}
