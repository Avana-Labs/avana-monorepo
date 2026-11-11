// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Market-level backing and Aave configuration check.
/// @dev Raw values: `totalSupply` (vault token), `totalCredited` (Collateralization), `pendingUnits` and
/// `pendingAmounts` (Collateralization pending-settlement balance, raw units of each pool token in the market's token
/// order), `unsettledSeizedUnits` (vault-token balance of
/// LPVaultSwap), `hubBalance` (vault-token balance of the Hub), `hubLiquidity` (`getAssetLiquidity`),
/// `stranded` (`hubBalance - hubLiquidity`, never backing), `addedAssets`, `addedShares`, `drawnShares`. Flags:
/// `supplyEqualsCredited` (`totalSupply == totalCredited + pendingUnits`), `hubHoldsSupplied`,
/// `sharesEqualAssets`, `noDrawnShares`, `noDrawCap` (every Spoke on the asset), `singleBorrowSpoke` (Spokes are
/// exactly the market's CDP Spoke and the fee receiver with `addCap == 0`), `noLiquidityFee` (`liquidationFee == 0`
/// or paid to Avana's fee receiver), `noReinvestment` (no reinvestment controller), `reserveFlags`
/// (`borrowable == false` and `receiveSharesEnabled == false`). The last three are the standard Spoke settings the
/// drift check enforces. Hub values are the market's home Hub's.
/// @custom:spec REQ-LENS-012, Q-378
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
