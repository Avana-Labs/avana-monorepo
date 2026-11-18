// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultSwapAdmin
/// @notice Initialization of the LPVaultSwap proxy and governance of the committed-operator (keeper) registry.
/// @dev The registry gates no call.
interface ILPVaultSwapAdmin {
    /// @notice Initializes the proxy storage.
    /// @dev Grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` to `timelock` only.
    function initialize(
        address timelock,
        address[] calldata initialKeepers
    ) external;

    /// @notice Registers a committed operator, which commits to liquidate every account below HF 1 on the chain.
    /// @dev `APPLICATION_ADMIN` only. Registration grants no power over `liquidate`.
    function addKeeper(
        address keeper
    ) external;

    /// @notice Removes a committed operator from the registry.
    /// @dev `APPLICATION_ADMIN` only. Reverts `KeeperFloor` if fewer than `KEEPER_FLOOR` active operators would remain.
    function removeKeeper(
        address keeper
    ) external;
}
