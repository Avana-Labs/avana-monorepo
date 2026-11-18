// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IPositionProxy
/// @notice A borrower's Aave V4 account for one market: one immutable, logic-free contract per (wallet, CDP Spoke,
/// market), so no market's collateral backs another market's debt.
/// @dev Only the AaveAdapter may call `execute`. No sweep: tokens sent here directly stay here.
interface IPositionProxy {
    /// @notice `execute` was called by an address other than the AaveAdapter, including the bound wallet.
    error OnlyAdapter();

    /// @notice `execute` named this proxy, zero, the AaveAdapter, the creating ProxyManager or an address without code.
    error InvalidTarget(address target);

    /// @notice The call made by `execute` reverted with empty revert data.
    error CallFailed(address target);

    /// @notice The constructor got a zero `adapter`, `wallet` or `spoke`, or a zero `marketId`.
    error ZeroAddress();

    /// @notice Calls `target` with `data` as this proxy, with no ETH.
    /// @dev Only the Adapter, which checks every balance delta. A revert propagates the callee's revert data.
    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory result);

    /// @notice Returns the chain's AaveAdapter, the only caller of `execute`.
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the bound wallet.
    function WALLET() external view returns (address wallet);

    /// @notice Returns the bound CDP Spoke.
    function SPOKE() external view returns (address spoke);

    /// @notice Returns the bound market, a MarketRegistry market identifier listed on `SPOKE`.
    function MARKET_ID() external view returns (uint256 marketId);
}
