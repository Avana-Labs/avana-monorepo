// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultErrors
/// @notice Errors of every LPVault (AMM integration): caller and lock checks of the custody functions, market binding,
/// position validation, ownership and custody, recipients, fees, stray positions and views called while the lock is
/// held.
/// @custom:spec REQ-VAULT-153, REQ-AMM-CORE-005, Q-371
interface ILPVaultErrors {
    /// @notice A custody, unwind or fee function was called by an address other than Collateralization.
    /// @custom:spec REQ-VAULT-147, REQ-VAULT-148, REQ-VAULT-149, REQ-VAULT-156, REQ-VAULT-161
    error NotCollateralization();

    /// @notice A custody function was called while neither the AaveAdapter nor LPVaultSwap holds the lock.
    /// @custom:spec REQ-VAULT-147, REQ-VAULT-148, REQ-VAULT-149, REQ-VAULT-157
    error LockNotHeld();

    /// @notice `bindMarket` was called by an address other than the MarketRegistry.
    /// @custom:spec REQ-AMM-CORE-004
    error NotMarketRegistry();

    /// @notice `bindMarket` named a market already bound, or a market is not bound to this integration.
    /// @param marketId The market.
    /// @custom:spec REQ-AMM-CORE-004
    error MarketBinding(uint256 marketId);

    /// @notice The pool is not one of this AMM protocol's canonical pools, its tokens are outside 2..8, or the
    /// listing data fails the integration's guards (hook flags, factory generation, minimum supply, observation buffer).
    /// @custom:spec REQ-AMM-CORE-004, REQ-AMM-CORE-014
    error InvalidPool();

    /// @notice The shape is malformed: kind differs from the integration's, ticks unordered, misaligned under signed
    /// int24 `tick % tickSpacing`, or outside the usable ticks.
    /// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004
    error InvalidShape();

    /// @notice The position's pool differs from the market's pool.
    /// @custom:spec REQ-VAULT-008, REQ-VAULT-103
    error PoolMismatch();

    /// @notice The position's range differs from the market's exact range (AMMN-RT-01).
    /// @dev The tick fields are CL-specific (Uniswap v3, Slipstream); an integration of any other shape reports 0
    /// for both.
    /// @param tickLower Position lower tick; 0 for other shapes.
    /// @param tickUpper Position upper tick; 0 for other shapes.
    /// @custom:spec REQ-VAULT-009, REQ-VAULT-104, REQ-AMM-CORE-003, SPEC-BACK-001
    error RangeMismatch(int24 tickLower, int24 tickUpper);

    /// @notice The pool's reentrancy lock is held (Uniswap v3 and Slipstream `slot0().unlocked == false`; Curve and
    /// Balancer reentrancy guard entered).
    /// @custom:spec REQ-VAULT-010, REQ-VAULT-105, REQ-AMM-CORE-013
    error PoolLocked();

    /// @notice The owner named in `receivePosition` is the LPVault itself or does not own the position.
    /// @custom:spec REQ-VAULT-147, REQ-VAULT-101, Q-258
    error NotTokenOwner();

    /// @notice The position is staked in a gauge or subscribed to a notifier; only unstaked positions are accepted.
    /// @custom:spec REQ-AMM-SLIP-004, REQ-AMM-V4-003
    error PositionEncumbered();

    /// @notice The position holds no units after custody.
    /// @custom:spec REQ-VAULT-012, REQ-VAULT-107
    error ZeroUnits();

    /// @notice The position is not in custody for an open record.
    /// @custom:spec REQ-VAULT-148, REQ-VAULT-149, REQ-VAULT-161, REQ-VAULT-162, REQ-VAULT-064, REQ-VAULT-120, REQ-VAULT-158
    error NotInCustody();

    /// @notice The depositor named for a fee collection is not the depositor of record.
    /// @custom:spec REQ-VAULT-064, REQ-VAULT-120
    error NotDepositor();

    /// @notice The position is not a stray position (not held by the LPVault, or it has a depositor of record).
    /// @custom:spec REQ-VAULT-079, REQ-VAULT-083, REQ-VAULT-122
    error NotStray();

    /// @notice A stray-position or principal recipient is `address(0)` or the LPVault.
    /// @custom:spec REQ-VAULT-080, REQ-VAULT-122, REQ-VAULT-149, REQ-VAULT-159
    error InvalidRecipient();

    /// @notice An NFT receiver callback came from a contract other than a position manager bound to this integration.
    /// @custom:spec REQ-VAULT-078, REQ-VAULT-124
    error UnsupportedNft();

    /// @notice `returnStray` was called by an address other than the chain's AvanaTimelock.
    /// @custom:spec REQ-VAULT-080, REQ-VAULT-123
    error NotTimelock();

    /// @notice An n-token array has a length other than the market's token count.
    /// @param expected Market token count.
    /// @param actual Array length.
    /// @custom:spec REQ-AMM-CORE-002
    error LengthMismatch(uint256 expected, uint256 actual);

    /// @notice An unwind returned less than a per-token minimum.
    /// @param index Token index in pool order.
    /// @param received Raw amount received.
    /// @param minimum Raw minimum.
    /// @custom:spec REQ-AMM-CORE-007
    error BelowMinimum(uint256 index, uint256 received, uint256 minimum);

    /// @notice `collectFees` was called on an integration whose fees compound into the position.
    /// @custom:spec REQ-AMM-CORE-011
    error FeesRolledIn();

    /// @notice A price vector entry is 0 or the vector cannot be converted to a pool price.
    /// @custom:spec REQ-AMM-CORE-006
    error InvalidPrices();

    /// @notice A custody view was called while the lock is held, by an address other than Collateralization.
    /// @custom:spec REQ-VAULT-151, REQ-VAULT-160
    error Locked();

    /// @notice `topUpPosition` was called on an integration whose positions are added to through the AMM protocol.
    /// @custom:spec REQ-AMM-CORE-011, REQ-COLL-037
    error TopUpNotSupported();

    /// @notice A constructor argument is zero, two Avana bindings coincide, or the AMM protocol bindings do not belong
    /// together (for example a position manager whose `factory()` is not the pinned factory).
    /// @custom:spec REQ-VAULT-155, REQ-AMM-V3-001
    error InvalidDeployment();
}
