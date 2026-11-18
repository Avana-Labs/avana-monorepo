// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {RouteSlot} from "../../types/OracleTypes.sol";
import {BreakerScope} from "./types/Breaker.sol";

/// @title IMarketRegistryBase
/// @notice Errors and events of the MarketRegistry, shared with its logic contracts.
interface IMarketRegistryBase {
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

    /// @notice Emitted by `deployCdpSpoke`.
    event SpokeApproved(
        address indexed spoke,
        address indexed hub,
        uint32 indexed integrationId,
        address implementation,
        address aaveOracle
    );

    /// @notice Emitted by `enableDebtReserve`.
    event DebtReserveApproved(
        address indexed spoke,
        uint256 indexed reserveId,
        address asset,
        address fundingHub,
        uint256 hubAssetId,
        address priceSource,
        address firstLossReserve
    );

    /// @notice Emitted by `removeDebtReserve`.
    event DebtReserveRemoved(address indexed spoke, uint256 indexed reserveId);

    /// @notice Emitted by `listToken`.
    /// @param pegModule Peg module (GSM or PSM) a backup swap route must avoid, or address(0).
    event TokenListed(
        address token, uint8 decimals, address[] primaryRoute, address[] alternateRoute, address pegModule
    );

    /// @notice Emitted by `setPriceSource`.
    event PriceSourceSet(address token, address[] primaryRoute, address[] alternateRoute, address[] standbyRoute);

    /// @notice Emitted by `listCollateralMarket`.
    /// @param pool Pool address (address(0) for an AMM protocol keyed by identifier).
    /// @param poolId Pool identifier (bytes32(0) for an AMM protocol keyed by address).
    /// @param tokens Pool tokens in pool order.
    event MarketRegistered(
        uint256 indexed marketId,
        uint32 indexed integrationId,
        address pool,
        bytes32 poolId,
        address[] tokens,
        address vaultToken,
        address lpOracle,
        address indexed spoke
    );

    /// @notice Emitted by `activateMarket`; `(chainId, spoke, reserveId)` is the external market key.
    event MarketActivated(
        uint256 marketId, uint256 chainId, address spoke, uint256 reserveId, address hub, uint256 hubAssetId
    );

    /// @notice Emitted by `cancelRegistration`.
    event MarketRegistrationCancelled(uint256 marketId);

    /// @notice Emitted by `setMarketOffboarding`.
    event MarketOffboarding(uint256 marketId);

    /// @notice Emitted by `setRoute`.
    /// @param kind 0 primary, 1 backup.
    event RouteSet(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address route);

    /// @notice Emitted by `disableRoute`.
    /// @param kind 0 primary, 1 backup.
    event RouteDisabled(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address caller);

    /// @notice Emitted by `restoreRoute`.
    /// @param kind 0 primary, 1 backup.
    event RouteRestored(uint256 indexed marketId, address token, address debtAsset, uint8 kind, address route);

    /// @notice A Hub's pause state changed.
    event PauseStateChanged(
        address indexed hub, PauseState indexed previous, PauseState indexed current, address caller
    );

    event PauseReasonChanged(address indexed hub, PauseReason previous, PauseReason current, address indexed caller);

    event AddressFrozen(address indexed account, address indexed caller);

    event AddressUnfrozen(address indexed account);

    /// @notice A security freeze latched by `recordBreach` or a manual trip.
    /// @param reasons Latched reason bits after the call.
    event BreakerLatched(BreakerScope indexed scope, bytes32 indexed key, uint32 reasons);

    /// @notice `recordBreach` saw a temporary gate (`ORACLE`, `POOL_SHARE`, `POOL_DEPTH`) breached.
    /// @param at New `lastBreachAt(key)`, seconds.
    event GateBreached(bytes32 indexed key, uint32 reasons, uint64 at);

    event BreakerReset(BreakerScope indexed scope, bytes32 indexed key, address indexed caller);

    /// @notice A token's standby route replaced one of its routes.
    event StandbyRouteActivated(address indexed token, RouteSlot slot, address indexed caller);

    /// @notice The Aave governance executor undid a standby switch.
    event StandbySwitchCancelled(address indexed token, address indexed caller);

    /// @notice The replaced slot returned to its recorded route.
    event PriceRouteRestored(address indexed token);
}
