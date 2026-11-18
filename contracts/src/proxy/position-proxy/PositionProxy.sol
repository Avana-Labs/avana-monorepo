// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "./IPositionProxy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title PositionProxy
/// @notice A borrower's Aave V4 account for one (wallet, CDP Spoke, market): a logic-free, immutable contract that
/// makes exactly the calls the chain's AaveAdapter sends it, with no ETH.
/// @dev Not an upgrade proxy: no storage, `delegatecall`, `receive` or `fallback`.
contract PositionProxy is IPositionProxy {
    /// @dev The AaveAdapter, the only caller of `execute`.
    address private immutable _ADAPTER;

    address private immutable _WALLET;

    address private immutable _SPOKE;

    uint256 private immutable _MARKET_ID;

    /// @dev The ProxyManager that created this proxy, never a target of `execute`.
    address private immutable _PROXY_MANAGER;

    /// @notice Fixes the binding in the code; the ProxyManager runs it once, inside its CREATE2 creation.
    /// @param adapter The AaveAdapter; it needs no code yet.
    constructor(
        address adapter,
        address wallet,
        address spoke,
        uint256 marketId
    ) {
        if (adapter == address(0) || wallet == address(0) || spoke == address(0) || marketId == 0) {
            revert ZeroAddress();
        }
        _ADAPTER = adapter;
        _WALLET = wallet;
        _SPOKE = spoke;
        _MARKET_ID = marketId;
        _PROXY_MANAGER = msg.sender;
    }

    /// @inheritdoc IPositionProxy
    function execute(
        address target,
        bytes calldata data
    ) external override returns (bytes memory result) {
        if (msg.sender != _ADAPTER) revert OnlyAdapter();
        // The Adapter and the ProxyManager are never targets, so the proxy can never call either.
        if (
            target == address(this) || target == address(0) || target == _ADAPTER || target == _PROXY_MANAGER
                || target.code.length == 0
        ) revert InvalidTarget(target);
        bool success;
        // solhint-disable-next-line avoid-low-level-calls
        (success, result) = target.call(data);
        if (!success && result.length == 0) revert CallFailed(target);
        result = Address.verifyCallResult(success, result);
    }

    /// @inheritdoc IPositionProxy
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IPositionProxy
    function WALLET() external view override returns (address wallet) {
        wallet = _WALLET;
    }

    /// @inheritdoc IPositionProxy
    function SPOKE() external view override returns (address spoke) {
        spoke = _SPOKE;
    }

    /// @inheritdoc IPositionProxy
    function MARKET_ID() external view override returns (uint256 marketId) {
        marketId = _MARKET_ID;
    }
}
