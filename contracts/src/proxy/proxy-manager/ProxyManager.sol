// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryFreeze} from "../../policy/market-registry/IMarketRegistryFreeze.sol";
import {PositionProxy} from "../position-proxy/PositionProxy.sol";
import {IProxyManager} from "./IProxyManager.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/// @title ProxyManager
/// @notice The chain's only creator of PositionProxies: one immutable proxy per (wallet, CDP Spoke, market), created
/// with CREATE2 on the AaveAdapter's call at an address fixed by those three values.
/// @dev Immutable, with no storage, owner, role, pause, setter, upgrade path, `receive` or `fallback`. The salt and
/// the constructor arguments both carry `(wallet, spoke, marketId)` and the init code carries `ADAPTER`, so a proxy
/// address names exactly one binding, and only this contract can create code at it. Keeps no wallet-to-proxy map
/// (the Adapter keeps the binding and registers proxies in the vault tokens). Reads only `isFrozenAddress` of the
/// MarketRegistry, and only in `deployProxy`.
/// @custom:spec REQ-PROXY-001, REQ-PROXY-006, REQ-PROXY-050, REQ-PROXY-053, REQ-PROXY-054, REQ-PROXY-055, REQ-PROXY-085, REQ-PROXY-086, REQ-PROXY-100, REQ-PROXY-101, REQ-PROXY-103, INV-064, INV-065, Q-226, Q-276, Q-375
contract ProxyManager is IProxyManager {
    /// @dev The chain's AaveAdapter: the only caller of `deployProxy` and the `ADAPTER` of every proxy.
    address private immutable _ADAPTER;

    /// @dev The MarketRegistry, read for the address freeze.
    address private immutable _MARKET_REGISTRY;

    /// @dev `keccak256(type(PositionProxy).creationCode)`, recorded in the deployment manifest.
    bytes32 private immutable _PROXY_CREATION_CODE_HASH;

    /// @notice Fixes the Adapter, the MarketRegistry and the proxy creation-code hash.
    /// @param adapter The AaveAdapter's CREATE3-predicted fixed proxy address; it needs no code yet.
    /// @param marketRegistry The MarketRegistry's proxy address; it needs no code yet.
    /// @custom:spec REQ-PROXY-050, REQ-PROXY-085
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
    /// @custom:spec REQ-PROXY-051, REQ-PROXY-052, REQ-PROXY-053, REQ-PROXY-056, REQ-PROXY-097, REQ-PROXY-099, REQ-PROXY-100, REQ-PROXY-102, INV-012, INV-064, Q-242, Q-375
    function deployProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external override returns (address proxy) {
        if (msg.sender != _ADAPTER) revert OnlyAdapter();
        if (wallet == address(0) || spoke == address(0) || marketId == 0) revert ZeroAddress();
        // The same salt and init-code bytes give the prediction and the creation, so the two cannot drift apart.
        bytes32 salt = _salt(wallet, spoke, marketId);
        bytes memory initCode = _initCode(wallet, spoke, marketId);
        address predicted = Create2.computeAddress(salt, keccak256(initCode));
        if (predicted.code.length != 0) revert ProxyExists(wallet, spoke, marketId);
        if (IMarketRegistryFreeze(_MARKET_REGISTRY).isFrozenAddress(wallet)) revert AddressIsFrozen(wallet);
        proxy = Create2.deploy(0, salt, initCode);
        if (proxy != predicted) revert ProxyAddressMismatch(proxy, predicted);
        // The only call before the event is the creation itself: the new proxy's constructor stores four immutables and
        // calls nothing, so no code can run in between (the registry read is a STATICCALL before the creation).
        // forge-lint: disable-next-line(reentrancy-events)
        emit ProxyDeployed(wallet, spoke, marketId, proxy);
    }

    /// @inheritdoc IProxyManager
    /// @custom:spec REQ-PROXY-052, REQ-PROXY-055, REQ-PROXY-097, REQ-PROXY-099, Q-375
    function predictProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external view override returns (address predicted) {
        if (wallet == address(0) || spoke == address(0) || marketId == 0) revert ZeroAddress();
        predicted = _predict(wallet, spoke, marketId);
    }

    /// @inheritdoc IProxyManager
    /// @custom:spec REQ-PROXY-052, REQ-PROXY-055, REQ-PROXY-085
    function PROXY_CREATION_CODE_HASH() external view override returns (bytes32 codeHash) {
        codeHash = _PROXY_CREATION_CODE_HASH;
    }

    /// @inheritdoc IProxyManager
    /// @custom:spec REQ-PROXY-051, REQ-PROXY-085
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IProxyManager
    /// @custom:spec REQ-PROXY-085, REQ-PROXY-099
    function MARKET_REGISTRY() external view override returns (address marketRegistry) {
        marketRegistry = _MARKET_REGISTRY;
    }

    /// @dev CREATE2 address of the proxy of `(wallet, spoke, marketId)` from this contract (REQ-PROXY-052).
    /// @custom:spec REQ-PROXY-052, REQ-PROXY-053
    function _predict(
        address wallet,
        address spoke,
        uint256 marketId
    ) private view returns (address predicted) {
        predicted =
            Create2.computeAddress(_salt(wallet, spoke, marketId), keccak256(_initCode(wallet, spoke, marketId)));
    }

    // The proxy key `(wallet, spoke, marketId)` is turned into bytes only in the two functions below: the CREATE2 salt
    // and the constructor arguments of the init code. `deployProxy` and `predictProxy` both go through them.

    /// @dev `keccak256(abi.encode(wallet, spoke, marketId))` (REQ-PROXY-001).
    /// @custom:spec REQ-PROXY-001, REQ-PROXY-052
    function _salt(
        address wallet,
        address spoke,
        uint256 marketId
    ) private pure returns (bytes32 salt) {
        salt = keccak256(abi.encode(wallet, spoke, marketId));
    }

    /// @dev `type(PositionProxy).creationCode ‖ abi.encode(ADAPTER, wallet, spoke, marketId)` (REQ-PROXY-001).
    /// @custom:spec REQ-PROXY-001, REQ-PROXY-004, REQ-PROXY-052
    function _initCode(
        address wallet,
        address spoke,
        uint256 marketId
    ) private view returns (bytes memory initCode) {
        initCode = bytes.concat(type(PositionProxy).creationCode, abi.encode(_ADAPTER, wallet, spoke, marketId));
    }
}
