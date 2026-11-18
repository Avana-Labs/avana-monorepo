// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PoolKeying} from "../../amm/types/AmmTypes.sol";
import {VaultTokenBindings} from "../../types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../types/PositionTypes.sol";

/// @title IVaultTokenFactory
/// @notice Registry of AMM integrations and vault tokens; one vault token per (CDP Spoke, market key), via CREATE3.
/// @dev Both registries are append-only; only the AccessManager's governance role writes them.
interface IVaultTokenFactory {
    event IntegrationRegistered(
        uint32 indexed integrationId,
        address indexed lpVault,
        bytes32 ammProtocol,
        PoolKeying poolKeying,
        ShapeKind shapeKind
    );

    /// @notice A vault token was deployed and registered for its (CDP Spoke, market key) pair.
    /// @param pool The pool address, or 0 for an integration keyed by `poolId`.
    /// @param poolId The pool identifier, or 0 for an integration keyed by address.
    event VaultTokenDeployed(
        address indexed vaultToken,
        uint256 indexed marketId,
        address indexed spoke,
        VaultTokenBindings bindings,
        address pool,
        bytes32 poolId,
        PositionShape shape
    );

    /// @notice The integration identifier or LPVault is invalid, already registered, or its bindings do not match.
    error InvalidIntegration();

    error UnknownIntegration(uint32 integrationId);

    error TokenExistsForMarket();

    /// @notice `decimals` lies outside [6, 18].
    error DecimalsOutOfRange();

    /// @notice An address argument is zero, or the pool key does not match the integration's keying.
    error ZeroAddress();

    error InvalidShape();

    /// @notice `marketId` is 0 or not below `2^32`.
    error InvalidMarketId();

    /// @notice `name` is empty or longer than 128 bytes, or `symbol` is empty or longer than 32 bytes.
    error InvalidTokenMetadata();

    /// @notice Registers the LPVault of an AMM protocol under a new integration identifier; append-only.
    function registerIntegration(
        uint32 integrationId,
        address lpVault
    ) external;

    /// @notice Deploys and registers the vault token of one market.
    /// @dev Checks the token's bindings first, as CREATE3 returns no constructor revert data.
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
    function marketKeyOf(
        uint32 integrationId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape
    ) external view returns (bytes32 marketKey);

    /// @notice Returns the registered vault token of a market key on a CDP Spoke, or `address(0)`.
    function tokenOf(
        address spoke,
        bytes32 marketKey
    ) external view returns (address vaultToken);

    /// @notice Returns whether `vaultToken` was deployed by this factory.
    function isVaultToken(
        address vaultToken
    ) external view returns (bool deployed);

    /// @notice Returns the LPVault registered for an integration identifier, or `address(0)`.
    function lpVaultOf(
        uint32 integrationId
    ) external view returns (address lpVault);

    /// @notice Returns the integration identifier an LPVault is registered under, or 0 when it is not registered.
    function integrationIdOf(
        address lpVault
    ) external view returns (uint32 integrationId);

    /// @notice Returns the pool keying and shape kind recorded for a registered integration.
    /// @dev `(PoolKeying.Address, ShapeKind.None)` for an unregistered identifier.
    function integrationKindOf(
        uint32 integrationId
    ) external view returns (PoolKeying poolKeying, ShapeKind shapeKind);

    /// @notice Returns the CREATE3 address the vault token of a market key on a CDP Spoke has or will have.
    function predictAddress(
        address spoke,
        bytes32 marketKey
    ) external view returns (address predicted);

    /// @notice Returns the AaveAdapter bound into every token as minter and burner.
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns LPVaultSwap, bound into every token.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the chain's Collateralization, bound into every token.
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the chain's MarketRegistry, which every registered LPVault must name as its `MARKET_REGISTRY()`.
    function MARKET_REGISTRY() external view returns (address marketRegistry);
}
