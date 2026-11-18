// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultEvents
/// @notice Events of every LPVault (AMM integration).
/// @dev Amount arrays are in the market's pool token order.
interface ILPVaultEvents {
    /// @notice A market was bound to this integration at listing.
    /// @param pool Pool address, or 0 for an AMM protocol keyed by id.
    /// @param poolId Pool id inside a singleton, or 0 for an AMM protocol keyed by address.
    /// @param tickLower Lower tick of a CL market; 0 for other shapes.
    /// @param tickUpper Upper tick of a CL market; 0 for other shapes.
    event MarketBound(uint256 indexed marketId, address pool, bytes32 poolId, int24 tickLower, int24 tickUpper);

    event PositionReceived(
        bytes32 indexed positionKey, uint256 indexed marketId, address indexed depositor, uint128 units
    );

    /// @notice A custodied position was sent, whole, to its depositor of record.
    event PositionReturned(bytes32 indexed positionKey, address indexed depositor);

    /// @notice Units were removed from a custodied position and exactly their principal sent to `recipient`.
    event UnitsUnwound(bytes32 indexed positionKey, uint128 units, address indexed recipient, uint256[] amounts);

    /// @notice Units were removed from a custodied position and their principal sent to the depositor of record.
    event UnitsReleased(bytes32 indexed positionKey, uint128 units, address indexed depositor, uint256[] amounts);

    event FeesCollected(bytes32 indexed positionKey, address indexed depositor, uint256[] amounts);

    /// @notice A position arrived outside `receivePosition` and was accepted as stray.
    event StrayReceived(bytes32 indexed positionKey, address from, address operator);

    /// @notice A stray position was sent to the recipient governance established as its owner.
    event StrayReturned(bytes32 indexed positionKey, address recipient);
}
