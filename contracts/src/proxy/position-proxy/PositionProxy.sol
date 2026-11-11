// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "./IPositionProxy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title PositionProxy
/// @notice A borrower's Aave V4 account for one (wallet, CDP Spoke, market): a logic-free, immutable contract that
/// makes exactly the calls the chain's AaveAdapter sends it, as itself and with no ETH.
/// @dev Plain contract, not an upgrade proxy: no storage, no initializer, no `delegatecall`, no `selfdestruct`, no
/// `receive` or `fallback`, so a call matching no selector, and any ETH sent to it, reverts. The four bindings are
/// constructor immutables, so they are part of the code and of the CREATE2 address the ProxyManager computed; the
/// creating ProxyManager (`msg.sender` of the constructor) is a fifth immutable that is not a constructor argument, so
/// the init code and the address stay those of `predictProxy`. The only code check is on the callee of `execute`; no
/// caller is checked for code and `tx.origin` is never read.
/// @custom:spec REQ-PROXY-001, REQ-PROXY-002, REQ-PROXY-003, REQ-PROXY-004, REQ-PROXY-005, REQ-PROXY-006, REQ-PROXY-007, REQ-PROXY-010, REQ-PROXY-011, REQ-PROXY-012, REQ-PROXY-014, REQ-PROXY-078, REQ-PROXY-086, REQ-PROXY-101, REQ-PROXY-103, INV-016, INV-063, INV-065, Q-306, Q-375
contract PositionProxy is IPositionProxy {
    /// @dev The chain's AaveAdapter (its fixed ERC-1967 proxy address), the only caller of `execute`.
    address private immutable _ADAPTER;

    /// @dev The bound wallet.
    address private immutable _WALLET;

    /// @dev The bound CDP Spoke.
    address private immutable _SPOKE;

    /// @dev The bound market.
    uint256 private immutable _MARKET_ID;

    /// @dev The ProxyManager that created this proxy, never a target of `execute`.
    address private immutable _PROXY_MANAGER;

    /// @notice Fixes the binding in the code; the ProxyManager runs it once, inside its CREATE2 creation.
    /// @param adapter The chain's AaveAdapter; it needs no code yet (a CREATE3-predicted address).
    /// @param wallet The bound wallet.
    /// @param spoke The bound CDP Spoke.
    /// @param marketId The bound market.
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-003, REQ-PROXY-004, REQ-PROXY-092
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
    /// @custom:spec REQ-PROXY-007, REQ-PROXY-012, REQ-PROXY-040, REQ-PROXY-087, REQ-PROXY-088, REQ-PROXY-089, REQ-PROXY-091, REQ-PROXY-096, REQ-PROXY-098, INV-016, INV-063
    function execute(
        address target,
        bytes calldata data
    ) external override returns (bytes memory result) {
        if (msg.sender != _ADAPTER) revert OnlyAdapter();
        // The code check is on the callee, never on a caller (REQ-PROXY-006). The Adapter and the ProxyManager are never
        // targets, so no Adapter call path can make the proxy a caller of either (REQ-PROXY-091).
        if (
            target == address(this) || target == address(0) || target == _ADAPTER || target == _PROXY_MANAGER
                || target.code.length == 0
        ) revert InvalidTarget(target);
        bool success;
        // The target and calldata are the Adapter's: it builds every call and checks every balance delta around it, so
        // the proxy forwards them unchanged with no ETH (REQ-PROXY-007).
        // solhint-disable-next-line avoid-low-level-calls
        (success, result) = target.call(data);
        if (!success && result.length == 0) revert CallFailed(target);
        // Returns the return data on success and re-raises the callee's revert data unchanged otherwise (REQ-PROXY-012).
        result = Address.verifyCallResult(success, result);
    }

    /// @inheritdoc IPositionProxy
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-090
    function ADAPTER() external view override returns (address adapter) {
        adapter = _ADAPTER;
    }

    /// @inheritdoc IPositionProxy
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-005, REQ-PROXY-090
    function WALLET() external view override returns (address wallet) {
        wallet = _WALLET;
    }

    /// @inheritdoc IPositionProxy
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-005, REQ-PROXY-090
    function SPOKE() external view override returns (address spoke) {
        spoke = _SPOKE;
    }

    /// @inheritdoc IPositionProxy
    /// @custom:spec REQ-PROXY-002, REQ-PROXY-005, REQ-PROXY-090
    function MARKET_ID() external view override returns (uint256 marketId) {
        marketId = _MARKET_ID;
    }
}
