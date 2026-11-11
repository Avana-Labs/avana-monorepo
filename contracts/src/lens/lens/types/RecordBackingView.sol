// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Custody and live liquidity against credited units for one open record of a market.
/// @dev `inCustody` is the market LPVault's custody answer for `positionKey`; `liveUnits` is the position's live units
/// as the market's AMM integration reports them; `backed` is `inCustody && liveUnits >= credited`; donated units stay
/// with the position and are never collateral.
/// @custom:spec REQ-LENS-014, Q-376
struct RecordBackingView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 recordId;
    uint32 integrationId;
    bytes32 positionKey;
    uint256 credited;
    uint256 liveUnits;
    bool inCustody;
    bool backed;
}
