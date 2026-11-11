// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultEvents
/// @notice Events of every LPVault (AMM integration): market bound, position received and returned, units unwound,
/// units released to the depositor, fees collected, stray positions received and returned.
/// @dev Record events (`CollateralPledged`, `CollateralReleased`, `RecordDebited`, `RecordReduced`,
/// `RecordRecredited`, seizure and pending events) are emitted by Collateralization. Amount arrays are in the
/// market's pool token order. Indexers key positions by `chainId + integrationId + positionKey`.
/// @custom:spec REQ-VAULT-147, REQ-VAULT-148, REQ-VAULT-149, REQ-AMM-CORE-001, Q-076, Q-371
interface ILPVaultEvents {
    /// @notice A market was bound to this integration at listing.
    /// @dev `tickLower` and `tickUpper` are the exact range of a concentrated-liquidity market (Uniswap v3,
    /// Slipstream); they are CL-specific and 0 for every other position shape.
    /// @param marketId Market identifier.
    /// @param pool Pool address, or 0 for an AMM protocol keyed by id.
    /// @param poolId Pool id inside a singleton, or 0 for an AMM protocol keyed by address.
    /// @param tickLower Exact lower tick of a concentrated-liquidity market; 0 for other shapes.
    /// @param tickUpper Exact upper tick of a concentrated-liquidity market; 0 for other shapes.
    /// @custom:spec REQ-AMM-CORE-004
    event MarketBound(uint256 indexed marketId, address pool, bytes32 poolId, int24 tickLower, int24 tickUpper);

    /// @notice A position entered custody for a new record.
    /// @custom:spec REQ-VAULT-147, DEP-008
    event PositionReceived(
        bytes32 indexed positionKey, uint256 indexed marketId, address indexed depositor, uint128 units
    );

    /// @notice A custodied position was sent, whole, to its depositor of record.
    /// @custom:spec REQ-VAULT-148
    event PositionReturned(bytes32 indexed positionKey, address indexed depositor);

    /// @notice Units were removed from a custodied position and exactly their principal sent to `recipient`.
    /// @custom:spec REQ-VAULT-149, SPEC-BACK-008
    event UnitsUnwound(bytes32 indexed positionKey, uint128 units, address indexed recipient, uint256[] amounts);

    /// @notice Units were removed from a custodied position and their principal sent to the depositor of record.
    /// @custom:spec REQ-VAULT-161, SPEC-BACK-008, Q-254
    event UnitsReleased(bytes32 indexed positionKey, uint128 units, address indexed depositor, uint256[] amounts);

    /// @notice Owed fees of a custodied position were collected to its depositor.
    /// @custom:spec REQ-VAULT-065, FEE-006
    event FeesCollected(bytes32 indexed positionKey, address indexed depositor, uint256[] amounts);

    /// @notice A position arrived outside `receivePosition` and was accepted as stray.
    /// @custom:spec REQ-VAULT-078
    event StrayReceived(bytes32 indexed positionKey, address from, address operator);

    /// @notice A stray position was sent to the recipient governance established as its owner.
    /// @custom:spec REQ-VAULT-080
    event StrayReturned(bytes32 indexed positionKey, address recipient);
}
