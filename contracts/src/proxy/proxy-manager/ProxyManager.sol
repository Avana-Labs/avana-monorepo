// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionProxy} from "../position-proxy/PositionProxy.sol";
import {IProxyManager} from "./IProxyManager.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title ProxyManager
/// @notice Creator of PositionProxies: one immutable proxy per (wallet, CDP Spoke, market), created with CREATE2 on
/// the AaveAdapter's call.
/// @dev Immutable, with no owner, role or upgrade path.
contract ProxyManager is IProxyManager {
    /// @dev The AaveAdapter: the only caller of `deployProxy`.
    address private immutable _ADAPTER;

    /// @dev The MarketRegistry.
    address private immutable _MARKET_REGISTRY;

    /// @dev `keccak256(type(PositionProxy).creationCode)`.
    bytes32 private immutable _PROXY_CREATION_CODE_HASH;

    /// @notice Fixes the Adapter, the MarketRegistry and the proxy creation-code hash.
    /// @param adapter The AaveAdapter's CREATE3-predicted fixed proxy address; it needs no code yet.
    /// @param marketRegistry The MarketRegistry's proxy address; it needs no code yet.
    constructor(
        address adapter,
        address marketRegistry
    ) {
        if (adapter == address(0) || marketRegistry == address(0)) revert ZeroAddress();
        _ADAPTER = adapter;
        _MARKET_REGISTRY = marketRegistry;
        _PROXY_CREATION_CODE_HASH = keccak256(type(PositionProxy).creationCode);
    }

    /// @inheritdoc IProxyManager
    function deployProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external override returns (address proxy) {
        if (msg.sender != _ADAPTER) revert OnlyAdapter();
        if (wallet == address(0) || spoke == address(0) || marketId == 0) revert ZeroAddress();
        bytes32 salt = _salt(wallet, spoke, marketId);
        bytes memory initCode = _initCode(wallet, spoke, marketId);
        address predicted = Create2.computeAddress(salt, keccak256(initCode));
        if (predicted.code.length != 0) revert ProxyExists(wallet, spoke, marketId);
        proxy = Create2.deploy(0, salt, initCode);
        if (proxy != predicted) revert ProxyAddressMismatch(proxy, predicted);
        // Safe: the new proxy's constructor calls nothing, and the registry read is a STATICCALL.
        // forge-lint: disable-next-line(reentrancy-events)
        emit ProxyDeployed(wallet, spoke, marketId, proxy);
    }

    /// @inheritdoc IProxyManager
    function predictProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external view override returns (address predicted) {
        if (wallet == address(0) || spoke == address(0) || marketId == 0) revert ZeroAddress();
        predicted = _predict(wallet, spoke, marketId);
    }

    /// @inheritdoc IProxyManager
    function PROXY_CREATION_CODE_HASH() external view override returns (bytes32 codeHash) {
        codeHash = _PROXY_CREATION_CODE_HASH;
    }

    /// @inheritdoc IProxyManager
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IProxyManager
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    function _predict(
        address wallet,
        address spoke,
        uint256 marketId
    ) private view returns (address predicted) {
        predicted =
            Create2.computeAddress(_salt(wallet, spoke, marketId), keccak256(_initCode(wallet, spoke, marketId)));
    }

    function _salt(
        address wallet,
        address spoke,
        uint256 marketId
    ) private pure returns (bytes32 salt) {
        salt = keccak256(abi.encode(wallet, spoke, marketId));
    }

    function _initCode(
        address wallet,
        address spoke,
        uint256 marketId
    ) private view returns (bytes memory initCode) {
        initCode = bytes.concat(type(PositionProxy).creationCode, abi.encode(_ADAPTER, wallet, spoke, marketId));
    }
}
