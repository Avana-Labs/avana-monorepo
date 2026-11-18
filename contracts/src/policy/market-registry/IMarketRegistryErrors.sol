// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IMarketRegistryErrors
/// @notice Errors of the MarketRegistry's listing, activation, debt-reserve, route and pause checks.
interface IMarketRegistryErrors {
    /// @notice A write would map a pool, vault token, LPOracle, Hub asset or Spoke reserve to a second market.
    error DuplicateMarketKey();

    /// @notice A restore named an address never set for that slot through the timelock.
    error NotPreviouslyApproved();

    error InvalidRoute();

    /// @notice A debt asset charges a non-zero transfer fee at listing (its issuer probe reads a fee rate above 0).
    error TransferFeeActive(address asset);

    error UnknownMarket(uint256 marketId);

    error MarketNotRegistered(uint256 marketId);

    error MarketNotActive(uint256 marketId);

    error TokenNotListed(address token);

    /// @notice The Spoke is not approved, or failed the `approveSpoke` checks.
    error InvalidSpoke(address spoke);

    /// @notice The vault token does not match the factory registry or the market definition.
    error VaultTokenMismatch();

    error ListingCheckFailed(bytes32 check);

    error ActivationCheckFailed(uint256 marketId, bytes32 check);

    error UnknownDebtReserve(address spoke, uint256 reserveId);

    /// @notice The debt reserve still has debt owed or an uncovered deficit.
    error DebtReserveInUse(address spoke, uint256 reserveId);

    error InvalidDebtReserve(bytes32 check);

    /// @notice `freeze()` while Frozen.
    error AlreadyFrozen();

    /// @notice `freeze()` while Paused.
    error AlreadyPaused();

    /// @notice `unfreeze()` while None.
    error NotFrozen();

    /// @notice `unpause()` while not Paused.
    error NotPaused();

    /// @notice `unfreeze()` while Paused.
    error CannotUnfreezeWhilePaused();

    /// @notice The caller holds neither the required guardian role nor `APPLICATION_ADMIN`.
    error Unauthorized(address caller);

    /// @notice `pause(None)`, or `pause(reason)` with the current reason while Paused.
    error InvalidPauseReason();

    /// @notice `freezeAddress` on an address of the protected set.
    error ProtectedAddress(address account);

    /// @notice `freezeAddress` on a frozen address.
    error AddressAlreadyFrozen(address account);

    /// @notice `unfreezeAddress` on an address that is not frozen.
    error AddressNotFrozen(address account);

    /// @notice The caller reached `MAX_ADDRESS_FREEZES_PER_DAY` freezes in the current window.
    error FreezeLimitReached(address caller);

    /// @notice A breaker reset while no reason is latched.
    error NothingToReset();

    /// @notice A breaker reset while a latched security condition still holds.
    error ConditionStillHolds(bytes32 key, uint32 reasons);

    error NotRiskModule();

    /// @notice `useStandbyRoute` for a token with an empty standby route.
    error NoStandbyRoute(address token);

    /// @notice `useStandbyRoute` while a slot is already replaced.
    error StandbyAlreadyActive(address token);

    /// @notice `cancelStandbySwitch` or `restorePriceRoute` with no slot replaced.
    error StandbyNotActive(address token);

    /// @notice A route slot other than `Primary` or `Alternate`.
    error InvalidRouteSlot();

    /// @notice Liquidation of this (market, debt reserve) pair would have no usable swap route or flash source.
    error LivenessBound(address spoke, uint256 marketId, uint256 debtReserveId);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A new market would take the registry past `MAX_MARKET_COUNT` listings.
    error MarketCountLimit(uint256 limit);
}
