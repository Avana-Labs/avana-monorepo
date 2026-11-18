// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason, Market, MarketDef, PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {IMarketRegistryBase} from "./IMarketRegistryBase.sol";
import {IMarketRegistryRoutes} from "./IMarketRegistryRoutes.sol";
import {DebtReserveDef, RiskTier, SpokeDef, TokenDef, WindDownState} from "./types/MarketRegistryTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IMarketRegistry
/// @notice The chain's registry of Hubs, integrations, CDP Spokes, debt reserves, markets, routes and safety state.
/// @dev UUPS proxy; only the timelock can upgrade it. Holds no funds and stores no risk parameter.
interface IMarketRegistry is IAccessControl, IMarketRegistryBase, IMarketRegistryRoutes {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, with the proxy deployment. Reverts `AdminRoleOnlyTimelock` unless `timelock == TIMELOCK`.
    function initialize(
        address timelock
    ) external;

    /// @notice Records a standard Aave V4 CDP Spoke, or re-approves a recorded one after an Aave upgrade.
    /// @dev The Spoke's implementation code hash must be approved, and the RiskModule's Aave config check must pass.
    function deployCdpSpoke(
        SpokeDef calldata def
    ) external returns (address spoke);

    /// @notice Enables a debt reserve on a CDP Spoke, with its funding Hub, price source and First-Loss Reserve.
    /// @dev Reverts `TransferFeeActive` if the asset charges a transfer fee, `LivenessBound` if a market loses routes.
    function enableDebtReserve(
        address spoke,
        DebtReserveDef calldata def
    ) external;

    /// @notice Removes a debt reserve that has nothing owed.
    /// @dev Reverts `DebtReserveInUse` while debt or deficit remains, or a live market settles in it.
    function removeDebtReserve(
        address spoke,
        uint256 reserveId
    ) external;

    /// @notice Lists a pool token or debt asset with its Chainlink routes and issuer probe.
    /// @dev An empty alternate route makes a monitoring-only listing. ERC-777 tokens are refused.
    function listToken(
        address token,
        TokenDef calldata def
    ) external;

    /// @notice Replaces a token's two Chainlink routes.
    /// @dev Re-runs the route checks for every market using the token.
    function setPriceSource(
        address token,
        address[] calldata primaryRoute,
        address[] calldata alternateRoute
    ) external;

    /// @notice Registers a collateral market on a CDP Spoke in `Registered` status, or re-registers a cancelled one.
    /// @dev The vault token must come from the factory and match the market; runs the registration checks.
    /// @return marketId Sequential identifier from 1, or the reserved identifier on a relisting.
    function listCollateralMarket(
        MarketDef calldata def
    ) external returns (uint256 marketId);

    /// @notice Runs the activation checks and sets the market `Active`.
    /// @dev Reverts `ActivationCheckFailed` or `LivenessBound` on the first failed check.
    function activateMarket(
        uint256 marketId
    ) external;

    /// @notice Cancels a `Registered` market, freeing its keys and reserving its identifier for its pool.
    function cancelRegistration(
        uint256 marketId
    ) external;

    /// @notice Moves an `Active` market to `Offboarding`, for good.
    /// @dev Blocks new pledges and borrowing against the market; repay, withdrawals and liquidation continue.
    function setMarketOffboarding(
        uint256 marketId
    ) external;

    event HubRecorded(address indexed hub, RiskTier tier);

    event IntegrationRegistered(uint32 indexed integrationId, address lpVault, address pricing);

    event AvanaFirstLossReserveSet(address indexed hub, address indexed asset, address firstLossReserve);

    /// @param previous The previous source (address(0) for the first).
    event FlashSourceSet(address indexed previous, address indexed current);

    /// @notice A Hub argument is zero, unrecorded, already recorded, of the wrong tier, or the borrowing Spoke's home.
    error InvalidHub(address hub);

    /// @notice An integration identifier is 0 or already used, or the LPVault reports another identifier.
    error InvalidIntegration(uint32 integrationId);

    /// @notice The First-Loss Reserve does not report the Hub and asset, or the pair already has one.
    error InvalidAvanaFirstLossReserve(address firstLossReserve);

    /// @notice Records a Hub of the chain with its risk tier.
    /// @dev Reverts `InvalidRoute` when `hub` is the flash source's lender.
    function recordHub(
        address hub,
        RiskTier tier
    ) external;

    /// @notice Registers an AMM integration: the AMM protocol's LPVault on this chain and its pricing implementation.
    /// @dev Identifiers are never reused.
    function registerIntegration(
        uint32 integrationId,
        address lpVault,
        address pricing
    ) external;

    /// @notice Records the First-Loss Reserve of a (Hub, debt asset) pair.
    /// @dev Set once per pair; the reserve must report `hub` and `asset`.
    function setAvanaFirstLossReserve(
        address hub,
        address asset,
        address firstLossReserve
    ) external;

    /// @notice Risk tier of a recorded Hub (`None` for an unknown Hub).
    function hubTier(
        address hub
    ) external view returns (RiskTier tier);

    /// @notice Whether `account` is a Hub recorded on the chain (any tier).
    function isRecordedHub(
        address account
    ) external view returns (bool recorded);

    /// @notice Every recorded Hub of the chain, in recording order.
    function getHubs() external view returns (address[] memory hubs);

    /// @notice Home Hub of a CDP Spoke.
    /// @return hub The home Hub, or `address(0)`.
    function hubOf(
        address spoke
    ) external view returns (address hub);

    /// @notice The LPVault and pricing implementation of an AMM integration.
    /// @return lpVault The AMM protocol's LPVault, or `address(0)`.
    function integrationOf(
        uint32 integrationId
    ) external view returns (address lpVault, address pricing);

    /// @notice Integration identifier of an LPVault (0 if unknown).
    function integrationIdOf(
        address lpVault
    ) external view returns (uint32 integrationId);

    /// @notice First-Loss Reserve of a (Hub, debt asset) pair (`address(0)` if none).
    function firstLossReserveOf(
        address hub,
        address asset
    ) external view returns (address firstLossReserve);

    /// @notice Drift check of the standard Spoke settings Avana depends on, for every listed market of a CDP Spoke.
    /// @dev Never reverts; a failed read reports drift. `marketId` is 0 for a Spoke-wide drift.
    /// @return marketId First drifting market, or 0.
    /// @return reason The drift reason, `None` when the settings hold.
    function spokeSettingsDrift(
        address spoke
    ) external view returns (uint256 marketId, DriftReason reason);

    /// @notice Replaces the chain's IFlashSource implementation.
    /// @dev Reverts `InvalidRoute` if the source's lender is a recorded Hub.
    function setFlashSource(
        address newSource
    ) external;

    /// @notice Moves the state from None to Frozen.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`.
    function freeze(
        address hub
    ) external;

    /// @notice Moves the state from None or Frozen to Paused(reason), or changes the reason while Paused.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`.
    function pause(
        address hub,
        PauseReason reason
    ) external;

    /// @notice Applies `freeze` to every Hub registered on the chain in one call.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`; reverts `AlreadyFrozen` when no Hub changes.
    function freezeAll() external;

    /// @notice Applies `pause(hub, reason)` to every Hub registered on the chain in one call.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; reverts `AlreadyPaused` when no Hub changes.
    function pauseAll(
        PauseReason reason
    ) external;

    /// @notice Moves the state from Frozen to None.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; the freeze role alone cannot unfreeze.
    function unfreeze(
        address hub
    ) external;

    /// @notice Moves the state from Paused to None and clears the reason.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`. The state returns to None, never to Frozen.
    function unpause(
        address hub
    ) external;

    /// @notice A Hub's pause state.
    /// @return state None, Frozen or Paused (None for an unrecorded Hub).
    function pauseState(
        address hub
    ) external view returns (PauseState state);

    /// @notice The reason of a Hub's current pause.
    /// @return reason `None` exactly when the state is not Paused.
    function pauseReason(
        address hub
    ) external view returns (PauseReason reason);

    /// @notice Freezes an address for new activity.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`. Reverts `FreezeLimitReached` past the per-day limit.
    function freezeAddress(
        address account
    ) external;

    /// @notice Unfreezes an address.
    /// @dev `APPLICATION_ADMIN` only.
    function unfreezeAddress(
        address account
    ) external;

    /// @notice Whether an address is frozen. Never reverts.
    function isFrozenAddress(
        address account
    ) external view returns (bool frozen);

    /// @notice Freezes a caller made in the 24 one-hour buckets ending with the current one.
    /// @return count Freezes counted toward `MAX_ADDRESS_FREEZES_PER_DAY`.
    function freezesInWindow(
        address caller
    ) external view returns (uint256 count);

    /// @notice Most freezes one caller can make in the 24 one-hour buckets ending with the current hour.
    function MAX_ADDRESS_FREEZES_PER_DAY() external view returns (uint256 limit);

    /// @notice Records the reasons a `pokeBreakers` call observed for one key.
    /// @dev RiskModule only. Latches security reasons and stamps temporary-gate breach times; never clears a latch.
    function recordBreach(
        bytes32 key,
        uint32 reasons
    ) external;

    /// @notice Latches a manual breaker on a market until reset.
    /// @dev `APPLICATION_FREEZE_GUARDIAN` or `APPLICATION_ADMIN`.
    function tripMarketBreaker(
        uint256 marketId
    ) external;

    /// @notice Latches a manual breaker on a debt reserve until reset.
    /// @dev Same roles as `tripMarketBreaker`. Reverts `UnknownDebtReserve` unless approved.
    function tripDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice Clears a market's latched security freezes, `MANUAL` included.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` or `APPLICATION_ADMIN`; reverts while a latched condition still holds.
    function resetMarketBreaker(
        uint256 marketId
    ) external;

    /// @notice Clears a debt reserve's latched security freezes, `MANUAL` included.
    /// @dev Same roles and errors as `resetMarketBreaker`.
    function resetDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external;

    /// @notice A market's latched security freezes and last temporary-gate breach. Never reverts.
    /// @return latchedReasons Latched `BreakerReasons` bits, 0 when none.
    /// @return lastBreach Latest time `pokeBreakers` recorded a temporary gate breached, 0 if never.
    function marketBreaker(
        uint256 marketId
    ) external view returns (uint32 latchedReasons, uint64 lastBreach);

    /// @notice A debt reserve's latched security freezes and last temporary-gate breach. Never reverts.
    /// @return latchedReasons Latched `BreakerReasons` bits, 0 when none.
    /// @return lastBreach Latest time `pokeBreakers` recorded a temporary gate breached, 0 if never.
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 latchedReasons, uint64 lastBreach);

    /// @notice Latest time `pokeBreakers` recorded a temporary gate breached for `key`, 0 if never. Never reverts.
    /// @dev With a per-reason key (`BreakerReasons.breachKey`), the latest breach of that reason alone.
    /// @return at Block timestamp, seconds.
    function lastBreachAt(
        bytes32 key
    ) external view returns (uint64 at);

    /// @notice Number of the Spoke's markets that are Active or Offboarding. Never reverts; 0 for an unknown Spoke.
    function activeMarketCount(
        address spoke
    ) external view returns (uint256 count);

    /// @notice The First-Loss Reserve of `(hub, asset)` is below the coverage ratio for the summed draw caps.
    error CoverageBelowRatio(address hub, address asset, uint256 required, uint256 funded);

    /// @notice A debt reserve names a First-Loss Reserve other than `firstLossReserveOf(hub, asset)`.
    error AvanaFirstLossReserveMismatch(address hub, address asset, address firstLossReserve);

    /// @notice The First-Loss Reserve of `(hub, asset)` holds less than its `firstLossReserveMinimum`.
    error CoverageNotFunded(address hub, address asset);

    /// @notice First-loss coverage of `(hub, asset)`: the summed live Aave draw caps of every CDP Spoke with an enabled
    /// debt reserve of the pair, against the First-Loss Reserve's funded balance.
    /// @dev Covered when `required <= funded`; `required` rounds up. `enableDebtReserve` and every borrow of the asset
    /// require it, so a draw-cap raise past the cover stops new borrowing until the reserve is funded or the cap cut.
    /// @return drawCapSum Sum of the draw caps, whole tokens (an unbounded cap counts `2^128`).
    /// @return required Balance the caps require, base units: `drawCapSum x 10^decimals x coverageRatioBps / 10^4`.
    /// @return funded First-Loss Reserve balance, base units.
    function drawCapCoverage(
        address hub,
        address asset
    ) external view returns (uint256 drawCapSum, uint256 required, uint256 funded);

    event MarketClosed(uint256 indexed marketId);

    event SettlementReserveSet(uint256 indexed marketId, uint256 debtReserveId);

    error MarketNotOffboarding(uint256 marketId);

    /// @notice The offboarding notice has not passed.
    /// @param notBefore First timestamp at which the market may close.
    error OffboardNoticeRunning(uint256 notBefore);

    /// @notice An account of the market still has debt (`Collateralization.getMarketDebtFree` is false).
    error MarketHasDebt(uint256 marketId);

    /// @notice Closes an `Offboarding` market once the notice period has passed and none of its accounts has debt.
    /// @dev Callable by anyone.
    function closeMarket(
        uint256 marketId
    ) external;

    /// @notice The offboarding record of a market.
    /// @dev Never reverts; all zeros for a market that never entered `Offboarding`.
    function windDownState(
        uint256 marketId
    ) external view returns (WindDownState memory state);

    /// @notice The debt reserve of the market's CDP Spoke into whose asset pending settlement converts.
    /// @dev Defaults to the Spoke's first enabled debt reserve at listing.
    function settlementReserve(
        uint256 marketId
    ) external view returns (uint256 debtReserveId);

    /// @notice Changes a market's settlement debt reserve.
    /// @dev `APPLICATION_ADMIN` only. The reserve must be enabled on the market's Spoke.
    function setSettlementReserve(
        uint256 marketId,
        uint256 debtReserveId
    ) external;

    event SpokeCodeHashApproved(bytes32 indexed codeHash);

    /// @param recordKey The record's key (chain, LPVault, its code hash, AMM protocol and pool keying).
    event IntegrationContractsRecorded(uint32 indexed integrationId, bytes32 indexed recordKey, address[] contracts);

    /// @notice The AMM protocol contracts of an integration were declared complete; its settlement routes can be set.
    event IntegrationContractsFinalized(uint32 indexed integrationId, bytes32 indexed recordKey, uint256 count);

    /// @notice The hash is 0, the hash of empty code, or already approved.
    error InvalidSpokeCodeHash(bytes32 codeHash);

    /// @notice Approves the code hash of a CDP Spoke implementation.
    /// @dev `APPLICATION_ADMIN` only. Approvals are never withdrawn.
    function approveSpokeCodeHash(
        bytes32 codeHash
    ) external;

    /// @notice Whether `codeHash` is an approved CDP Spoke implementation hash.
    /// @dev Includes `STANDARD_SPOKE_IMPLEMENTATION`'s hash. Never reverts.
    function isApprovedSpokeCodeHash(
        bytes32 codeHash
    ) external view returns (bool approved);

    /// @notice The implementation behind a recorded Spoke and whether it is still the one `deployCdpSpoke` approved.
    /// @dev Never reverts; zeros for an unknown Spoke or an unreadable slot.
    function spokeImplementationStatus(
        address spoke
    ) external view returns (address implementation, bytes32 codeHash, bool current);

    /// @notice Records AMM protocol contracts an integration's LPVault pins (position managers, factories).
    /// @dev `APPLICATION_ADMIN` only. After finalization, disables any active route that depends on an added address.
    function recordIntegrationContracts(
        uint32 integrationId,
        address[] calldata contracts
    ) external;

    /// @notice Finalizes an integration's AMM contract record; no route of its markets is accepted before.
    /// @dev `APPLICATION_ADMIN` only. Reverts `InvalidIntegration` if the record is empty, final or its key is stale.
    function finalizeIntegrationContracts(
        uint32 integrationId
    ) external;

    /// @notice The AMM protocol contracts recorded for an integration, in recording order.
    function integrationContracts(
        uint32 integrationId
    ) external view returns (address[] memory contracts);

    /// @notice Returns a market definition.
    function getMarket(
        uint256 marketId
    ) external view returns (Market memory market);

    /// @notice Returns a token definition.
    function getToken(
        address token
    ) external view returns (TokenDef memory def);

    /// @notice Returns a CDP Spoke record.
    function getSpoke(
        address spoke
    ) external view returns (SpokeDef memory def);

    /// @notice Every CDP Spoke ever approved, in approval order.
    function getSpokes() external view returns (address[] memory spokes);

    /// @notice Market identifiers listed on a CDP Spoke, in listing order.
    function marketsOfSpoke(
        address spoke
    ) external view returns (uint256[] memory marketIds);

    /// @notice Market identifier of a market key.
    /// @dev `key = VaultTokenFactory.marketKeyOf(...)`: one live market per (integration, pool, exact shape).
    function marketOfKey(
        bytes32 key
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a vault token.
    function marketOfVaultToken(
        address vaultToken
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of an LPOracle feed.
    function marketOfLpOracle(
        address lpOracle
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a CDP Spoke reserve.
    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (uint256 marketId);

    /// @notice Market identifier of a Hub asset.
    /// @dev Keyed by Hub, since each Hub numbers its assets from 0.
    function marketOfHubAsset(
        address hub,
        uint256 hubAssetId
    ) external view returns (uint256 marketId);

    /// @notice Last assigned market identifier.
    function marketCount() external view returns (uint256 count);

    /// @notice The most markets the registry ever lists (implementation immutable).
    function MAX_MARKET_COUNT() external view returns (uint256 limit);

    /// @notice Immutable Collateralization contract (implementation immutable).
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice ProxyManager fixed proxy address (implementation immutable).
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice ParameterStore fixed proxy address (implementation immutable).
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice LPVaultSwap fixed proxy address (implementation immutable).
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Timelocked vault-token factory (implementation immutable).
    function VAULT_TOKEN_FACTORY() external view returns (address factory);

    /// @notice RiskModule fixed proxy address (implementation immutable).
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Aave Adapter fixed proxy address (implementation immutable).
    function AAVE_ADAPTER() external view returns (address adapter);

    /// @notice The Avana timelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    function TIMELOCK() external view returns (address timelock);

    /// @notice The Aave governance executor, protected from the address freeze.
    function AAVE_GOVERNANCE_EXECUTOR() external view returns (address executor);

    /// @notice The chain's IFlashSource implementation, replaceable through the timelock (protected from the freeze).
    function flashSource() external view returns (address source);

    /// @notice Lock (protected from the freeze).
    function LOCK() external view returns (address lock);

    /// @notice The standard Aave V4 Spoke implementation whose code hash is approved from deployment.
    function STANDARD_SPOKE_IMPLEMENTATION() external view returns (address implementation);

    /// @notice PayoutEscrow, the payout escrow (protected from the freeze).
    function PAYOUT_ESCROW() external view returns (address escrow);

    /// @notice The public flash liquidation helper (implementation immutable, protected from the freeze).
    function FLASH_LIQUIDATOR() external view returns (address helper);

    /// @notice Returns an approved debt reserve's record.
    /// @return def Stored record (`approved == false` if unknown).
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory def);

    /// @notice Approved debt-reserve identifiers of a Spoke, in approval order.
    function getDebtReserveIds(
        address spoke
    ) external view returns (uint256[] memory reserveIds);

    /// @notice Whether a reserve is an approved debt reserve of a Spoke.
    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (bool approved);

    /// @notice A swap route slot of a market's pool token into a debt asset, and whether it is usable now.
    /// @param kind 0 primary, 1 backup.
    /// @return route Route contract (`address(0)` for an unknown key).
    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable);
}
