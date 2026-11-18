// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterViews
/// @notice Account bindings, borrow nonces and implementation immutables of the AaveAdapter.
interface IAaveAdapterViews {
    /// @notice Returns the wallet's proxy for a market.
    /// @return proxy The proxy, or `address(0)` before the wallet's first pledge to the market.
    function proxyOf(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy);

    /// @notice Returns the wallet bound to a proxy.
    /// @return wallet The bound wallet, or `address(0)` if `proxy` was not created by this Adapter.
    function walletOf(
        address proxy
    ) external view returns (address wallet);

    /// @notice Returns the binding the Adapter stored for a proxy at creation.
    /// @return spoke The bound CDP Spoke, or `address(0)` if `proxy` was not created by this Adapter.
    function accountOf(
        address proxy
    ) external view returns (address spoke, uint256 marketId, address vaultToken, uint256 reserveId);

    /// @notice Returns the CREATE2 address of `(wallet, market)`'s proxy, deployed or not.
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy);

    /// @notice Returns the next expected borrow nonce of a proxy.
    /// @dev Starts at 0 and rises by 1 per successful borrow of any asset.
    function borrowNonce(
        address proxy
    ) external view returns (uint256 nonce);

    /// @notice Returns the role identifier `keccak256("APPLICATION_ADMIN")`, held only by the timelock.
    function APPLICATION_ADMIN() external view returns (bytes32 role);

    /// @notice Returns the ProxyManager (implementation immutable).
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice Returns Collateralization (implementation immutable).
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the RiskModule (implementation immutable).
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the MarketRegistry (implementation immutable).
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice Returns the ParameterStore (implementation immutable).
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice Returns the chain's LPVaultSwap, the only caller of `burnSeized` (implementation immutable).
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the protocol Lock (implementation immutable).
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's VaultTokenFactory (implementation immutable).
    function VAULT_TOKEN_FACTORY() external view returns (address vaultTokenFactory);

    /// @notice Returns the only address that may hold the admin roles (implementation immutable).
    function TIMELOCK() external view returns (address timelock);
}
