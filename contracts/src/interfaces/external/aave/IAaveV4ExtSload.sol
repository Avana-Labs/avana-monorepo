// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveV4ExtSload
/// @notice Raw storage read on an Aave V4 Spoke, which Avana uses to read the Spoke proxy's implementation slot.
/// @dev ABI checked against `src/interfaces/IExtSload.sol` of the pinned Aave V4 dependency (`a3ef63e`).
interface IAaveV4ExtSload {
    /// @notice Word stored at `slot` in the Spoke's storage.
    /// @dev The read runs in the proxy's storage context, so the ERC-1967 implementation slot
    /// `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` gives the Spoke's live implementation.
    /// Read by the MarketRegistry (`approveSpoke`, drift view) and the RiskModule drift check.
    /// @param slot Storage slot to read.
    /// @return value The 32-byte word at `slot`.
    /// @custom:spec REQ-HUB-097, REQ-HUB-098, REQ-ADAPTER-063, REQ-CONFIG-074
    function extSload(
        bytes32 slot
    ) external view returns (bytes32 value);
}
