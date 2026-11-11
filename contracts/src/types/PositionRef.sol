// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Identity of one AMM position held in custody.
/// @dev `integrationId` is the MarketRegistry identifier of the AMM integration (one LPVault per AMM protocol per
/// chain); `positionKey` is that integration's key for the position: `bytes32(tokenId)` for Uniswap v3,
/// `bytes32((uint256(generation) << 248) | tokenId)` with `tokenId < 2^248` for Slipstream (the high byte names
/// the market's position manager and factory generation, because token IDs repeat across Slipstream's three
/// position managers), `keccak256(abi.encode(marketId, depositor, nonce))` for a fungible LP-token balance
/// (Uniswap v2, Curve, Balancer) and the PositionManager token ID as `bytes32` for Uniswap v4. A key is unique
/// within its integration, so the pair is unique per chain.
/// @custom:spec REQ-AMM-CORE-001, SPEC-AMM-CORE-002, Q-369
struct PositionRef {
    // AMM integration identifier.
    uint32 integrationId;
    // Integration-defined position key.
    bytes32 positionKey;
}
