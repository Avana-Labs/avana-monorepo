// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveV4ExtSload
/// @notice Raw storage read on an Aave V4 Spoke, used to read the Spoke proxy's implementation slot.
/// @dev ABI-equal to the pinned Aave V4 `IExtSload` (`a3ef63e`).
interface IAaveV4ExtSload {
    /// @notice Word stored at `slot` in the Spoke's storage.
    /// @dev Runs in the proxy's storage context, so the ERC-1967 implementation slot gives the live implementation.
    function extSload(
        bytes32 slot
    ) external view returns (bytes32 value);
}
