// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensAccount} from "./LensAccount.sol";
import {LensBase} from "./LensBase.sol";
import {LensClose} from "./LensClose.sol";

/// @title LensAccountModule
/// @notice Lens module serving `ILensAccount` and `ILensSizing.previewCloseAccount`.
contract LensAccountModule is LensAccount, LensClose {
    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
