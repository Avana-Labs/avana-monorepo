// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultBase
/// @notice Events and errors of every LPVault.
interface ILegacyLPVaultBase {
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

    error NotCollateralization();

    /// @notice A custody function was called while neither the AaveAdapter nor LPVaultSwap holds the lock.
    error LockNotHeld();

    error NotMarketRegistry();

    /// @notice `bindMarket` named a market already bound, or a market is not bound to this integration.
    error MarketBinding(uint256 marketId);

    /// @notice The pool is not canonical, has an unsupported token count, or fails the integration's listing guards.
    error InvalidPool();

    /// @notice The shape is malformed: wrong kind, or ticks unordered, misaligned or outside the usable range.
    error InvalidShape();

    error PoolMismatch();

    /// @notice The position's range differs from the market's exact range.
    /// @param tickLower Position lower tick; 0 for non-CL shapes.
    /// @param tickUpper Position upper tick; 0 for non-CL shapes.
    error RangeMismatch(int24 tickLower, int24 tickUpper);

    error PoolLocked();

    /// @notice The owner named in `receivePosition` is the LPVault itself or does not own the position.
    error NotTokenOwner();

    /// @notice The position is staked in a gauge or subscribed to a notifier; only unstaked positions are accepted.
    error PositionEncumbered();

    error ZeroUnits();

    error NotInCustody();

    error NotDepositor();

    /// @notice The position is not a stray position (not held by the LPVault, or it has a depositor of record).
    error NotStray();

    /// @notice A stray-position or principal recipient is `address(0)` or the LPVault.
    error InvalidRecipient();

    /// @notice An NFT receiver callback came from a contract other than a position manager bound to this integration.
    error UnsupportedNft();

    error LengthMismatch(uint256 expected, uint256 actual);

    error BelowMinimum(uint256 index, uint256 received, uint256 minimum);

    /// @notice `collectFees` was called on an integration whose fees compound into the position.
    error FeesRolledIn();

    /// @notice A price vector entry is 0 or the vector cannot be converted to a pool price.
    error InvalidPrices();

    /// @notice A custody view was called while the lock is held, by an address other than Collateralization.
    error Locked();

    /// @notice `topUpPosition` was called on an integration whose positions are added to through the AMM protocol.
    error TopUpNotSupported();

    /// @notice A constructor argument is zero, two bindings coincide, or the AMM protocol bindings do not match.
    error InvalidDeployment();
}
