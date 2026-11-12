// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensAccount} from "./LensAccount.sol";
import {LensBase} from "./LensBase.sol";

/// @title LensAccountModule
/// @notice The deployed part of the Lens that serves `ILensAccount`: the `Lens` entry point forwards those calls here by
/// STATICCALL with the caller's calldata unchanged and returns this contract's answer unchanged.
/// @dev Immutable and read-only like the Lens: the nine core addresses as constructor immutables, no storage, no
/// owner, no event; every function is `view` and reverts with `Locked()` while the Lock is held, so a direct call
/// answers exactly as a call through the Lens.
/// @custom:spec REQ-LENS-001, REQ-LENS-006, REQ-LENS-020, REQ-LENS-008, REQ-LENS-009, REQ-LENS-010, REQ-LENS-011, REQ-LENS-027, REQ-LENS-040
contract LensAccountModule is LensAccount {
    /// @notice Fixes the chain's core addresses (see `LensBase`).
    /// @param core The nine core addresses, in `LensBase` order.
    /// @custom:spec REQ-LENS-001, REQ-LENS-002
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
