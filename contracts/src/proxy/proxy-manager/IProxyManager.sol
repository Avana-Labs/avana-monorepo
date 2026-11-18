// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IProxyManager
/// @notice Creator of PositionProxies: one immutable proxy per (wallet, CDP Spoke, market), at a CREATE2 address
/// fixed by those three values.
/// @dev Immutable, no roles; only the AaveAdapter deploys.
interface IProxyManager {
    /// @notice A PositionProxy was deployed for `(wallet, spoke, marketId)`.
    event ProxyDeployed(address indexed wallet, address indexed spoke, uint256 indexed marketId, address proxy);

    /// @notice `deployProxy` was called by an address other than the AaveAdapter.
    error OnlyAdapter();

    /// @notice A proxy already exists at the predicted address of `(wallet, spoke, marketId)`.
    error ProxyExists(address wallet, address spoke, uint256 marketId);

    /// @notice `deployProxy` for a wallet the MarketRegistry has frozen.
    error AddressIsFrozen(address account);

    /// @notice A required address argument is zero, or `marketId` is 0.
    error ZeroAddress();

    /// @notice The created proxy is not at `predictProxy(wallet, spoke, marketId)`.
    /// @dev Unreachable while CREATE2 behaves as specified; a guard against a proxy the Adapter cannot predict.
    error ProxyAddressMismatch(address deployed, address predicted);

    /// @notice Deploys the PositionProxy of `(wallet, spoke, marketId)`.
    /// @dev Only the Adapter; reverts `AddressIsFrozen` for a frozen wallet.
    function deployProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external returns (address proxy);

    /// @notice Returns the CREATE2 address of `(wallet, spoke, marketId)`'s proxy, deployed or not.
    /// @dev Reverts `ZeroAddress` for a zero `wallet`, `spoke` or `marketId`.
    function predictProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external view returns (address predicted);

    /// @notice Returns `keccak256(type(PositionProxy).creationCode)`, without constructor arguments.
    function PROXY_CREATION_CODE_HASH() external view returns (bytes32 codeHash);

    /// @notice Returns the AaveAdapter, the only caller of `deployProxy` and the `ADAPTER` of every proxy.
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the MarketRegistry, read for the address freeze in `deployProxy`.
    function MARKET_REGISTRY() external view returns (address marketRegistry);
}
