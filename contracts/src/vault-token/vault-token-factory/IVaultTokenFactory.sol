// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../amm/types/PoolKeying.sol";
import {PositionShape} from "../../types/PositionShape.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {VaultTokenBindings} from "../../types/VaultTokenBindings.sol";

/// @title IVaultTokenFactory
/// @notice The chain's registry of AMM integrations and vault tokens: registers each AMM protocol's LPVault once, and
/// deploys each market's vault token with CREATE3 salted by (CDP Spoke, market key), keeping one token per pair.
/// @dev Non-upgradeable; holds no power over deployed tokens or LPVaults. Constructor arguments: `adapter`,
/// `lpVaultSwap`, `collateralization` (immutables passed to every token), `timelock` (the chain's AvanaTimelock, the
/// only caller of `registerIntegration` and `deployVaultToken`) and `marketRegistry` (the MarketRegistry every
/// registered LPVault must name). Both registries are append-only: an entry is written
/// once and never cleared or changed, so Collateralization, itself immutable, relies on them as immutable sources when
/// validating a token and its LPVault, and a new AMM protocol or market needs no new ledger or Lock. The market key is
/// `keccak256(abi.encode(block.chainid, integrationId, pool, poolId, shape.kind, shape.tickLower, shape.tickUpper))`
/// and the registry key is the pair (`spoke`, `marketKey`): two ranges of one pool are two markets with two tokens; the
/// same pool and range on another integration is another market; a market wound down on one CDP Spoke can be relisted
/// on a successor Spoke with a new token (Q-299, Q-355). Keys are canonical: each integration's pool keying and shape
/// kind are recorded at registration, and a listing must use exactly that keying (a pool address or a `poolId`, never
/// the other) and a well-formed shape of that kind (`FullPool` with both ticks 0, `TickRange` with
/// `tickLower < tickUpper`), so one pool and range has exactly one market key per integration.
/// @custom:spec REQ-VTOKEN-019, REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-023, REQ-VTOKEN-028, REQ-VTOKEN-038, REQ-AMM-CORE-001, Q-068, Q-228, Q-299, Q-355, Q-374
interface IVaultTokenFactory {
    /// @notice An AMM integration's LPVault was registered.
    /// @param integrationId The new integration identifier.
    /// @param lpVault The integration's LPVault.
    /// @param ammProtocol The LPVault's `AMM_PROTOCOL()`.
    /// @param poolKeying The integration's pool keying, recorded for every later listing.
    /// @param shapeKind The integration's shape kind, recorded for every later listing.
    /// @custom:spec REQ-AMM-CORE-001, REQ-VTOKEN-049, Q-374
    event IntegrationRegistered(
        uint32 indexed integrationId,
        address indexed lpVault,
        bytes32 ammProtocol,
        PoolKeying poolKeying,
        ShapeKind shapeKind
    );

    /// @notice A vault token was deployed and registered for its (CDP Spoke, market key) pair.
    /// @dev Carries every constructor binding of the token and the market definition the key hashes, so an indexer
    /// rebuilds the market key and the token's bindings from the event alone.
    /// @param vaultToken The new token.
    /// @param marketId The market's MarketRegistry `marketId` bound into the token.
    /// @param spoke CDP Spoke holding the token's reserve.
    /// @param bindings Every constructor binding of the token, name and symbol included.
    /// @param pool The pool address, or 0 for an integration keyed by `poolId`.
    /// @param poolId The pool identifier, or 0 for an integration keyed by address.
    /// @param shape The market's exact position shape.
    /// @custom:spec REQ-VTOKEN-024, REQ-VTOKEN-038, Q-076
    event VaultTokenDeployed(
        address indexed vaultToken,
        uint256 indexed marketId,
        address indexed spoke,
        VaultTokenBindings bindings,
        address pool,
        bytes32 poolId,
        PositionShape shape
    );

    /// @notice `registerIntegration` or `deployVaultToken` was called by an address other than the AvanaTimelock.
    /// @custom:spec REQ-VTOKEN-019, REQ-VTOKEN-037
    error NotTimelock();

    /// @notice The integration identifier is 0 or already registered, the LPVault is zero, a factory binding or already
    /// registered, one of its identity getters (`INTEGRATION_ID()`, `COLLATERALIZATION()`, `LOCK()`, `TIMELOCK()`,
    /// `MARKET_REGISTRY()`, `AMM_PROTOCOL()`, `capabilities()`) reverts, returns malformed data or does not match, or
    /// Collateralization's `VAULT_TOKEN_FACTORY()`, `ADAPTER()` or `LP_VAULT_SWAP()` is not this factory and its
    /// bindings.
    /// @custom:spec REQ-AMM-CORE-001, REQ-VTOKEN-044, Q-374
    error InvalidIntegration();

    /// @notice The integration identifier is not registered.
    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-036
    error UnknownIntegration(uint32 integrationId);

    /// @notice The (CDP Spoke, market key) pair already has a vault token.
    /// @custom:spec REQ-VTOKEN-021, REQ-VTOKEN-035, Q-299
    error TokenExistsForMarket();

    /// @notice `decimals` lies outside [6, 18].
    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-036, SPEC-UNIT-001
    error DecimalsOutOfRange();

    /// @notice `hub`, `spoke` or `lpOracle` is the zero address, a constructor argument is zero, or the pool key the
    /// integration's keying requires (`pool` for `Address`, `poolId` for `Id`) is zero or the other one is set.
    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-036, REQ-VTOKEN-049
    error ZeroAddress();

    /// @notice The shape is not a canonical shape of the integration's kind: another kind (`None` included), a
    /// `FullPool` with a non-zero tick, or a `TickRange` with `tickLower >= tickUpper`.
    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-049
    error InvalidShape();

    /// @notice `marketId` is 0 or not below `2^32`.
    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-036
    error InvalidMarketId();

    /// @notice `name` is empty or longer than 128 bytes, or `symbol` is empty or longer than 32 bytes.
    /// @custom:spec REQ-VTOKEN-022, REQ-VTOKEN-050
    error InvalidTokenMetadata();

    /// @notice Registers the LPVault of an AMM protocol under a new integration identifier; append-only.
    /// @dev Reverts with `NotTimelock` unless `msg.sender == TIMELOCK` (normal delay; any `CANCELLER_ROLE` holder can
    /// cancel). Requires `integrationId != 0`, a non-zero `lpVault` other than `ADAPTER`, `LP_VAULT_SWAP` and
    /// `COLLATERALIZATION`, neither the identifier nor the LPVault registered before; then, read with `STATICCALL` and
    /// each answer length-checked, `lpVault.INTEGRATION_ID() == integrationId`, `COLLATERALIZATION() ==
    /// COLLATERALIZATION`, `LOCK()` equal to Collateralization's `LOCK()`, `TIMELOCK() == TIMELOCK`,
    /// `MARKET_REGISTRY() == MARKET_REGISTRY`, `AMM_PROTOCOL() != 0`, a `capabilities()` shape kind other than `None`,
    /// and Collateralization's `VAULT_TOKEN_FACTORY() == address(this)`, `ADAPTER() == ADAPTER` and
    /// `LP_VAULT_SWAP() == LP_VAULT_SWAP` (`InvalidIntegration` for any failure, a reverting or short answer
    /// included). Records the LPVault and the integration's pool keying and shape kind, and emits
    /// `IntegrationRegistered`.
    /// @custom:spec REQ-AMM-CORE-001, REQ-VTOKEN-044, REQ-VTOKEN-049, Q-374
    function registerIntegration(
        uint32 integrationId,
        address lpVault
    ) external;

    /// @notice Deploys and registers the vault token of one market.
    /// @dev Reverts with `NotTimelock` unless `msg.sender == TIMELOCK`. It executes in the `listCollateralMarket`
    /// timelock batch together with `MarketRegistry.listCollateralMarket`, with `marketId = marketCount + 1` at
    /// execution; the registry requires the token's `marketKey()`, `integrationId()`, `integration()`, `marketId()`,
    /// `lpOracle()`, `hub()`, `spoke()` and `decimals()` to match the market, and `tokenOf(spoke, marketKey)` to be the
    /// token, so a mismatch reverts the batch and leaves the (Spoke, market key) pair unregistered. Checks in order:
    /// registered integration (`UnknownIntegration`); non-zero `hub`, `spoke`, `lpOracle` and exactly the pool key the
    /// integration's keying requires (`ZeroAddress`); a canonical shape of the integration's kind (`InvalidShape`);
    /// `decimals` in [6, 18] (`DecimalsOutOfRange`); `0 < marketId < 2^32` (`InvalidMarketId`); no existing token for
    /// (`spoke`, `marketKey`) (`TokenExistsForMarket`); a `name` of 1 to 128 bytes and a `symbol` of 1 to 32 bytes
    /// (`InvalidTokenMetadata`); then the token's own `InvalidBinding` unless the seven address bindings are pairwise
    /// distinct and none is `predictAddress(spoke, marketKey)`, because the CREATE3 proxy returns no revert data from
    /// the token's constructor. Deploys with CREATE3 and `salt = keccak256(abi.encode(spoke, marketKey))`, passing
    /// `ADAPTER`, `LP_VAULT_SWAP`, `COLLATERALIZATION` and the registered LPVault, writes `tokenOf[spoke][marketKey]`
    /// once and emits `VaultTokenDeployed`. The symbol is `avLP-<marketId>` and the name the market's full description
    /// (`REQ-VTOKEN-050`); the listing review checks both, the factory only their lengths. The implementation is
    /// `public` with `name` and `symbol` in memory (same ABI and selector), because the calldata decoder of eleven
    /// parameters with two calldata strings does not fit the EVM stack.
    /// @custom:spec REQ-VTOKEN-004, REQ-VTOKEN-019, REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-022, REQ-VTOKEN-024, REQ-VTOKEN-035, REQ-VTOKEN-036, REQ-VTOKEN-037, REQ-VTOKEN-038, REQ-VTOKEN-049, REQ-VTOKEN-050, SPEC-UNIT-001, Q-191, Q-228, Q-299, Q-374
    function deployVaultToken(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        address hub,
        address spoke,
        uint256 marketId,
        address lpOracle,
        uint8 decimals,
        string calldata name,
        string calldata symbol
    ) external returns (address vaultToken);

    /// @notice Returns the market key of a market definition.
    /// @custom:spec REQ-VTOKEN-020
    function marketKeyOf(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape
    ) external view returns (bytes32 marketKey);

    /// @notice Returns the registered vault token of a market key on a CDP Spoke, or `address(0)`.
    /// @custom:spec REQ-VTOKEN-021, REQ-COLL-003, Q-299
    function tokenOf(
        address spoke,
        bytes32 marketKey
    ) external view returns (address vaultToken);

    /// @notice Returns whether `vaultToken` was deployed by this factory.
    /// @custom:spec REQ-VTOKEN-021, REQ-COLL-003
    function isVaultToken(
        address vaultToken
    ) external view returns (bool deployed);

    /// @notice Returns the LPVault registered for an integration identifier, or `address(0)`.
    /// @custom:spec REQ-AMM-CORE-001, REQ-COLL-004
    function lpVaultOf(
        uint32 integrationId
    ) external view returns (address lpVault);

    /// @notice Returns the pool keying and shape kind recorded for a registered integration.
    /// @dev `(PoolKeying.Address, ShapeKind.None)` for an identifier that is not registered; a registered one never
    /// has `ShapeKind.None`.
    /// @custom:spec REQ-VTOKEN-049
    function integrationKindOf(
        uint32 integrationId
    ) external view returns (PoolKeying poolKeying, ShapeKind shapeKind);

    /// @notice Returns the CREATE3 address the vault token of a market key on a CDP Spoke has or will have.
    /// @dev Depends only on the factory address, `spoke` and `marketKey` (salt `keccak256(abi.encode(spoke,
    /// marketKey))`), so the listing payload can reference it before it runs.
    /// @custom:spec REQ-VTOKEN-020, Q-299
    function predictAddress(
        address spoke,
        bytes32 marketKey
    ) external view returns (address predicted);

    /// @notice Returns the chain's AaveAdapter fixed proxy address bound into every token as minter and burner.
    /// @custom:spec REQ-VTOKEN-023
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the chain's LPVaultSwap fixed proxy address bound into every token.
    /// @custom:spec REQ-VTOKEN-023
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the chain's Collateralization, bound into every token.
    /// @custom:spec REQ-VTOKEN-023
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the chain's AvanaTimelock, the only caller of `registerIntegration` and `deployVaultToken`.
    /// @custom:spec REQ-VTOKEN-019, REQ-VTOKEN-023
    function TIMELOCK() external view returns (address timelock);

    /// @notice Returns the chain's MarketRegistry, which every registered LPVault must name as its `MARKET_REGISTRY()`.
    /// @custom:spec REQ-VTOKEN-023, REQ-VTOKEN-044
    function MARKET_REGISTRY() external view returns (address marketRegistry);
}
