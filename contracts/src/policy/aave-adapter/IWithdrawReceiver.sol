// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IWithdrawReceiver
/// @notice The callback of `IAaveAdapter.allowWithdraw`: a contract a wallet lets withdraw part of one position for
/// the length of one call, such as a repay-with-collateral helper.
interface IWithdrawReceiver {
    /// @notice Called by the AaveAdapter while the allowance is open. The operator may call `withdraw` for
    /// `positionKey`, in part only and up to `maxLiquidity` in total; the allowance closes when this returns.
    /// @param wallet The wallet that opened the allowance.
    /// @param positionKey The position.
    /// @param maxLiquidity Most liquidity the operator may remove.
    /// @param data The wallet's data, unchanged.
    function onWithdrawAllowed(
        address wallet,
        bytes32 positionKey,
        uint128 maxLiquidity,
        bytes calldata data
    ) external;
}
