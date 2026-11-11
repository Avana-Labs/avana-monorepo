// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterViews
/// @notice Account bindings, borrow nonces and implementation immutables of the AaveAdapter.
interface IAaveAdapterViews {
    /// @notice Returns the wallet's proxy for a market.
    /// @param wallet The wallet.
    /// @param marketId The market.
    /// @return proxy The proxy, or `address(0)` before the wallet's first pledge to the market.
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-049, REQ-PROXY-053, Q-375
    function proxyOf(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy);

    /// @notice Returns the wallet bound to a proxy.
    /// @param proxy The proxy.
    /// @return wallet The bound wallet, or `address(0)` if `proxy` was not created by this Adapter.
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-049, REQ-PROXY-055
    function walletOf(
        address proxy
    ) external view returns (address wallet);

    /// @notice Returns the binding the Adapter stored for a proxy at creation.
    /// @dev Written once in the creating pledge and never changed; repay, debt-free exits and `burnSeized` read it
    /// instead of the MarketRegistry, so exits never depend on registry state.
    /// @param proxy The proxy.
    /// @return spoke The bound CDP Spoke, or `address(0)` if `proxy` was not created by this Adapter.
    /// @return marketId The bound market.
    /// @return vaultToken The market's vault token.
    /// @return reserveId The vault token's reserve on `spoke`.
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-049, Q-375
    function accountOf(
        address proxy
    ) external view returns (address spoke, uint256 marketId, address vaultToken, uint256 reserveId);

    /// @notice Returns the CREATE2 address of `(wallet, market)`'s proxy, deployed or not.
    /// @dev Returns `proxyOf(wallet, marketId)` when non-zero, otherwise `ProxyManager.predictProxy(wallet, spoke,
    /// marketId)` with the market's CDP Spoke from the MarketRegistry.
    /// @param wallet The wallet.
    /// @param marketId The market.
    /// @return proxy The predicted proxy address.
    /// @custom:spec REQ-PROXY-049, REQ-PROXY-052, Q-268, Q-375
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy);

    /// @notice Returns the next expected borrow nonce of a proxy.
    /// @dev Starts at 0 and rises by exactly 1 per successful borrow of any asset; the app reads it on-chain before a
    /// borrow.
    /// @param proxy The proxy.
    /// @return nonce The nonce the next borrow must carry.
    /// @custom:spec REQ-PROXY-015, REQ-PROXY-049, INV-019, Q-106
    function borrowNonce(
        address proxy
    ) external view returns (uint256 nonce);

    /// @notice Returns the role identifier `keccak256("APPLICATION_ADMIN")`, held only by the timelock.
    /// @return role The role.
    /// @custom:spec REQ-ADAPTER-003
    function APPLICATION_ADMIN() external view returns (bytes32 role);

    /// @notice Returns the ProxyManager (implementation immutable).
    /// @return proxyManager The ProxyManager.
    /// @custom:spec REQ-ADAPTER-066, REQ-ADAPTER-074
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice Returns Collateralization (implementation immutable).
    /// @return collateralization Collateralization.
    /// @custom:spec REQ-ADAPTER-065, REQ-ADAPTER-074
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the RiskModule (implementation immutable).
    /// @return riskModule The RiskModule.
    /// @custom:spec REQ-ADAPTER-008, REQ-ADAPTER-074
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the MarketRegistry (implementation immutable).
    /// @return marketRegistry The MarketRegistry.
    /// @custom:spec REQ-ADAPTER-044, REQ-ADAPTER-074
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice Returns the ParameterStore (implementation immutable).
    /// @return parameterStore The ParameterStore.
    /// @custom:spec REQ-ADAPTER-074
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice Returns the chain's LPVaultSwap, the only caller of `burnSeized` (implementation immutable).
    /// @return lpVaultSwap LPVaultSwap.
    /// @custom:spec REQ-ADAPTER-070, REQ-ADAPTER-074
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the protocol Lock (implementation immutable).
    /// @return lock The Lock.
    /// @custom:spec REQ-ADAPTER-050, REQ-PROXY-048
    function LOCK() external view returns (address lock);

    /// @notice Returns the chain's VaultTokenFactory, used to check a market's vault token without the MarketRegistry
    /// (implementation immutable).
    /// @return vaultTokenFactory The VaultTokenFactory.
    /// @custom:spec REQ-ADAPTER-074, REQ-PROXY-033, REQ-ADAPTER-047, Q-260
    function VAULT_TOKEN_FACTORY() external view returns (address vaultTokenFactory);

    /// @notice Returns the only address that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` (implementation
    /// immutable).
    /// @return timelock The AvanaTimelock.
    /// @custom:spec REQ-ADAPTER-084, Q-259
    function TIMELOCK() external view returns (address timelock);
}
