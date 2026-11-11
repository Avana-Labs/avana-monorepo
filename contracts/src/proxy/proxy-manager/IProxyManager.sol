// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IProxyManager
/// @notice The chain's only creator of PositionProxies: one immutable proxy per (wallet, CDP Spoke, market), at a
/// CREATE2 address fixed by those three values.
/// @dev Immutable contract: no upgrade proxy, implementation setter, owner, role or pause. Constructor
/// immutables `ADAPTER` (the AaveAdapter's fixed proxy address) and `MARKET_REGISTRY`, each non-zero. Salt
/// `keccak256(abi.encode(wallet, spoke, marketId))`; init code `type(PositionProxy).creationCode` followed by
/// `abi.encode(ADAPTER, wallet, spoke, marketId)`. Because the binding is both in the salt and in the constructor
/// arguments, a proxy address names exactly one (wallet, Spoke, market), and no Hub, Spoke or market can occupy
/// another's address: only the Adapter deploys, and the Adapter deploys only for `msg.sender` on a market listed on
/// that Spoke (REQ-ADAPTER-066). Keeping the deployer immutable and separate from the upgradeable Adapter keeps every
/// proxy address stable across Adapter upgrades. Keeps no wallet-to-proxy map: the Adapter keeps the binding and
/// registers proxies in each vault token.
/// @custom:spec REQ-PROXY-001, REQ-PROXY-050, REQ-PROXY-053, REQ-PROXY-054, REQ-PROXY-055, REQ-PROXY-085, REQ-PROXY-100, REQ-PROXY-101, Q-226, Q-276, Q-375
interface IProxyManager {
    /// @notice A PositionProxy was deployed for `(wallet, spoke, marketId)`.
    /// @dev Emitted before the Adapter's first collateral supply through the proxy; the Adapter emits `UserProxyCreated`
    /// in the same call.
    /// @param wallet The bound wallet.
    /// @param spoke The bound CDP Spoke.
    /// @param marketId The bound market.
    /// @param proxy The new proxy.
    /// @custom:spec REQ-PROXY-052, REQ-PROXY-056, Q-076, Q-375
    event ProxyDeployed(address indexed wallet, address indexed spoke, uint256 indexed marketId, address proxy);

    /// @notice `deployProxy` was called by an address other than the AaveAdapter.
    /// @custom:spec REQ-PROXY-051, REQ-PROXY-097
    error OnlyAdapter();

    /// @notice A proxy already exists at the predicted address of `(wallet, spoke, marketId)`.
    /// @param wallet The wallet.
    /// @param spoke The CDP Spoke.
    /// @param marketId The market.
    /// @custom:spec REQ-PROXY-051, REQ-PROXY-053, REQ-PROXY-097
    error ProxyExists(address wallet, address spoke, uint256 marketId);

    /// @notice `deployProxy` for a wallet the MarketRegistry has frozen.
    /// @param account The frozen wallet.
    /// @custom:spec REQ-PROXY-099, REQ-PROXY-102, Q-242
    error AddressIsFrozen(address account);

    /// @notice A required address argument is zero, or `marketId` is 0 (in `deployProxy`, `predictProxy` and the
    /// constructor).
    /// @custom:spec REQ-PROXY-051, REQ-PROXY-097
    error ZeroAddress();

    /// @notice The created proxy is not at `predictProxy(wallet, spoke, marketId)`.
    /// @dev Unreachable while the EVM's CREATE2 rule holds, since both addresses hash the same deployer, salt and init
    /// code; the check keeps a compiler or chain that broke the rule from leaving a proxy the Adapter cannot predict.
    /// @param deployed The address the creation returned.
    /// @param predicted The address `predictProxy` returns.
    /// @custom:spec REQ-PROXY-052, REQ-PROXY-097
    error ProxyAddressMismatch(address deployed, address predicted);

    /// @notice Deploys the PositionProxy of `(wallet, spoke, marketId)`.
    /// @dev `OnlyAdapter`; `ZeroAddress` for a zero `wallet` or `spoke` or a zero `marketId`; `ProxyExists` if the
    /// predicted address holds code; `AddressIsFrozen` if `MARKET_REGISTRY.isFrozenAddress(wallet)`. Creates the proxy
    /// with CREATE2 from salt `keccak256(abi.encode(wallet, spoke, marketId))` and init code
    /// `type(PositionProxy).creationCode ‖ abi.encode(ADAPTER, wallet, spoke, marketId)`, the same bytes the prediction
    /// hashes, requires the result to equal `predictProxy` (`ProxyAddressMismatch` otherwise) and emits `ProxyDeployed`. Checks
    /// run in that order, so a call failing several reverts with the first. If the predicted address has no code but a
    /// nonce or storage (reachable only through an address collision), CREATE2 fails and the call reverts with
    /// OpenZeppelin's `Errors.FailedDeployment()`. The Adapter has already checked that `marketId` is listed on
    /// `spoke`; it also checks, at the proxy's first pledge, that the proxy's Spoke account holds no collateral and no
    /// debt (REQ-PROXY-055).
    /// @param wallet The wallet pledging to the market for the first time.
    /// @param spoke The market's CDP Spoke.
    /// @param marketId The market.
    /// @return proxy The new proxy.
    /// @custom:spec REQ-PROXY-051, REQ-PROXY-052, REQ-PROXY-053, REQ-PROXY-056, REQ-PROXY-099, INV-012, Q-242, Q-375
    function deployProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external returns (address proxy);

    /// @notice Returns the CREATE2 address of `(wallet, spoke, marketId)`'s proxy, deployed or not.
    /// @dev `Create2.computeAddress(keccak256(abi.encode(wallet, spoke, marketId)), keccak256(abi.encodePacked(
    /// type(PositionProxy).creationCode, abi.encode(ADAPTER, wallet, spoke, marketId))))`. Reverts `ZeroAddress` for a
    /// zero `wallet` or `spoke` or a zero `marketId`, the triples `deployProxy` can never deploy.
    /// @param wallet The wallet.
    /// @param spoke The CDP Spoke.
    /// @param marketId The market.
    /// @return predicted The proxy address.
    /// @custom:spec REQ-PROXY-052, REQ-PROXY-055, Q-375
    function predictProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external view returns (address predicted);

    /// @notice Returns `keccak256(type(PositionProxy).creationCode)`, fixed at deployment.
    /// @dev Recorded in the deployment manifest. A prediction hashes this creation code followed by the constructor
    /// arguments, so the init-code hash of each proxy differs from this value.
    /// @return codeHash The hash of the PositionProxy creation code without constructor arguments.
    /// @custom:spec REQ-PROXY-055, Q-375
    function PROXY_CREATION_CODE_HASH() external view returns (bytes32 codeHash);

    /// @notice Returns the AaveAdapter, the only caller of `deployProxy` and the `ADAPTER` of every proxy.
    /// @return adapter Constructor immutable.
    /// @custom:spec REQ-PROXY-051, REQ-PROXY-085
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the MarketRegistry, read for the address freeze in `deployProxy`.
    /// @return marketRegistry Constructor immutable.
    /// @custom:spec REQ-PROXY-099, Q-242
    function MARKET_REGISTRY() external view returns (address marketRegistry);
}
