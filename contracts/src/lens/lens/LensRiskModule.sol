// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensBase} from "./LensBase.sol";
import {LensHubAssets} from "./LensHubAssets.sol";

/// @title LensRiskModule
/// @notice The deployed part of the Lens that serves `ILensRisk` and `ILensHubAssets`: the `Lens` entry point forwards those calls here by
/// STATICCALL with the caller's calldata unchanged and returns this contract's answer unchanged.
/// @dev Immutable and read-only like the Lens: the nine core addresses as constructor immutables, no storage, no
/// owner, no event; every function is `view` and reverts with `Locked()` while the Lock is held, so a direct call
/// answers exactly as a call through the Lens.
/// @custom:spec REQ-LENS-001, REQ-LENS-006, REQ-LENS-020, REQ-LENS-034, REQ-LENS-037, REQ-LENS-039, REQ-LENS-042, REQ-LENS-043, REQ-LENS-058, REQ-LENS-059, REQ-LENS-060
contract LensRiskModule is LensHubAssets {
    /// @notice Fixes the chain's core addresses (see `LensBase`).
    /// @param core The nine core addresses, in `LensBase` order.
    /// @custom:spec REQ-LENS-001, REQ-LENS-002
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
