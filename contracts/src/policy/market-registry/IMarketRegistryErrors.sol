// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryErrors
/// @notice Errors of the MarketRegistry: listing, registration, activation, debt-reserve and route checks, and the
/// pause-state transitions.
interface IMarketRegistryErrors {
    /// @notice A write would map a pool, vault token, LPOracle, Hub asset or Spoke reserve to a second market.
    /// @custom:spec REQ-CONFIG-007
    error DuplicateMarketKey();

    /// @notice A restore named an address never set for that slot through the timelock.
    /// @custom:spec REQ-CONFIG-062, REQ-MREG-012
    error NotPreviouslyApproved();

    /// @notice A route failed the route checks (token in or out, LPVaultSwap address, own pool, shared dependency,
    /// identical slots, a peg module in a backup, or a token class the route does not cover).
    /// @custom:spec REQ-CONFIG-039, REQ-CONFIG-040, REQ-MREG-011, REQ-MREG-013
    error InvalidRoute();

    /// @notice A debt asset charges a non-zero transfer fee at listing (its issuer probe reads a fee rate above 0).
    /// @param asset The debt asset.
    /// @custom:spec REQ-SWAP-123, REQ-ARCH-014, Q-271
    error TransferFeeActive(address asset);

    /// @notice The market identifier is unknown.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-CONFIG-006
    error UnknownMarket(uint256 marketId);

    /// @notice The market is not in `Registered` status.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-CONFIG-042, REQ-CONFIG-048
    error MarketNotRegistered(uint256 marketId);

    /// @notice The market is not in `Active` status.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-MREG-015
    error MarketNotActive(uint256 marketId);

    /// @notice A pool token is not listed.
    /// @param token Token address.
    /// @custom:spec REQ-CONFIG-017, REQ-CONFIG-033
    error TokenNotListed(address token);

    /// @notice The Spoke is not approved, or failed the `approveSpoke` checks.
    /// @param spoke Spoke address.
    /// @custom:spec REQ-CONFIG-016, REQ-CONFIG-033, REQ-CONFIG-074
    error InvalidSpoke(address spoke);

    /// @notice The vault token does not match the market: the factory registry, or the token's pool, Hub, Spoke,
    /// market identifier, LPOracle, Adapter, Collateralization or LPVaultSwap differs from the market definition.
    /// @custom:spec REQ-CONFIG-032
    error VaultTokenMismatch();

    /// @notice A listing or registration check failed.
    /// @param check Name of the failed check.
    /// @custom:spec REQ-CONFIG-065, REQ-CONFIG-021, REQ-CONFIG-027
    error ListingCheckFailed(bytes32 check);

    /// @notice An activation check failed.
    /// @param marketId Market identifier.
    /// @param check Name of the failed check.
    /// @custom:spec REQ-CONFIG-066, REQ-CONFIG-047
    error ActivationCheckFailed(uint256 marketId, bytes32 check);

    /// @notice The debt reserve is not enabled on the Spoke.
    /// @param spoke CDP Spoke.
    /// @param reserveId Reserve identifier.
    /// @custom:spec REQ-MREG-010, REQ-MREG-018
    error UnknownDebtReserve(address spoke, uint256 reserveId);

    /// @notice The debt reserve still has debt owed or an uncovered deficit.
    /// @param spoke CDP Spoke.
    /// @param reserveId Reserve identifier.
    /// @custom:spec REQ-MREG-010
    error DebtReserveInUse(address spoke, uint256 reserveId);

    /// @notice A debt-reserve definition failed a check.
    /// @param check Name of the failed check.
    /// @custom:spec REQ-MREG-006, REQ-MREG-008, REQ-MREG-018
    error InvalidDebtReserve(bytes32 check);

    /// @notice `freeze()` while Frozen.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017
    error AlreadyFrozen();

    /// @notice `freeze()` while Paused.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017
    error AlreadyPaused();

    /// @notice `unfreeze()` while None.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017
    error NotFrozen();

    /// @notice `unpause()` while not Paused.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017
    error NotPaused();

    /// @notice `unfreeze()` while Paused.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017
    error CannotUnfreezeWhilePaused();

    /// @notice The caller holds neither the required guardian role nor `APPLICATION_ADMIN`.
    /// @param caller The caller.
    /// @custom:spec REQ-MREG-004, REQ-MREG-017
    error Unauthorized(address caller);

    /// @notice `pause(None)`, or `pause(reason)` with the current reason while Paused.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017, REQ-MREG-024
    error InvalidPauseReason();

    /// @notice `freezeAddress` on an address of the protected set.
    /// @param account The address.
    /// @custom:spec REQ-MREG-020
    error ProtectedAddress(address account);

    /// @notice `freezeAddress` on a frozen address.
    /// @param account The address.
    /// @custom:spec REQ-MREG-019
    error AddressAlreadyFrozen(address account);

    /// @notice `unfreezeAddress` on an address that is not frozen.
    /// @param account The address.
    /// @custom:spec REQ-MREG-022
    error AddressNotFrozen(address account);

    /// @notice The caller made `MAX_ADDRESS_FREEZES_PER_DAY` freezes in the 24 one-hour buckets ending with the current
    /// hour.
    /// @param caller The caller.
    /// @custom:spec REQ-MREG-019
    error FreezeLimitReached(address caller);

    /// @notice A breaker reset while no reason is latched.
    /// @custom:spec REQ-MREG-025, REQ-ACCESS-170
    error NothingToReset();

    /// @notice A breaker reset while a latched security condition still holds.
    /// @param key Breaker key.
    /// @param reasons Security reasons still holding.
    /// @custom:spec REQ-MREG-025, SPEC-BRK-008, REQ-ACCESS-170, Q-399
    error ConditionStillHolds(bytes32 key, uint32 reasons);

    /// @notice `recordBreach` called by an address other than the RiskModule.
    /// @custom:spec REQ-MREG-026, Q-399
    error NotRiskModule();

    /// @notice `useStandbyRoute` for a token with an empty standby route.
    /// @param token The token.
    /// @custom:spec REQ-MREG-028
    error NoStandbyRoute(address token);

    /// @notice `useStandbyRoute` while a slot is already replaced.
    /// @param token The token.
    /// @custom:spec REQ-MREG-028
    error StandbyAlreadyActive(address token);

    /// @notice `cancelStandbySwitch` or `restorePriceRoute` with no slot replaced.
    /// @param token The token.
    /// @custom:spec REQ-MREG-028
    error StandbyNotActive(address token);

    /// @notice A route slot other than `Primary` or `Alternate`.
    /// @custom:spec REQ-MREG-028
    error InvalidRouteSlot();

    /// @notice Liquidation of this (market, debt reserve) pair would have no usable swap route or flash source.
    /// @param spoke CDP Spoke.
    /// @param marketId The market.
    /// @param debtReserveId The debt reserve.
    /// @custom:spec REQ-MREG-032, REQ-PSTORE-021
    error LivenessBound(address spoke, uint256 marketId, uint256 debtReserveId);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    /// @param role The role.
    /// @param account The grantee.
    /// @custom:spec REQ-MREG-005, Q-259
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A new market would take the registry past `MAX_MARKET_COUNT` listings; a relisting reuses its
    /// identifier and is not counted again.
    /// @param limit The registry's `MAX_MARKET_COUNT`.
    /// @custom:spec REQ-MREG-034
    error MarketCountLimit(uint256 limit);
}
