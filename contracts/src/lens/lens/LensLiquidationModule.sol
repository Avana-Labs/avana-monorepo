// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensBase} from "./LensBase.sol";
import {LensLiquidation} from "./LensLiquidation.sol";

/// @title LensLiquidationModule
/// @notice The deployed part of the Lens that serves `ILensLiquidation.previewLiquidation`: the `Lens` entry point forwards those calls here by
/// STATICCALL with the caller's calldata unchanged and returns this contract's answer unchanged.
/// @dev Immutable and read-only like the Lens: the nine core addresses as constructor immutables, no storage, no
/// owner, no event; every function is `view` and reverts with `Locked()` while the Lock is held, so a direct call
/// answers exactly as a call through the Lens.
/// @custom:spec REQ-LENS-001, REQ-LENS-006, REQ-LENS-020, REQ-LENS-016, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029, REQ-LENS-032, REQ-LENS-033
contract LensLiquidationModule is LensLiquidation {
    /// @notice Fixes the chain's core addresses (see `LensBase`).
    /// @param core The nine core addresses, in `LensBase` order.
    /// @param sizing `LensAaveSizing`, Aave's pinned liquidation sizing.
    /// @custom:spec REQ-LENS-001, REQ-LENS-002, REQ-LENS-017
    constructor(
        address[9] memory core,
        address sizing
    ) LensBase(core) LensLiquidation(sizing) {}
}
