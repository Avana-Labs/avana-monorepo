// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensActions} from "./LensActions.sol";
import {LensBase} from "./LensBase.sol";
import {LensPositions} from "./LensPositions.sol";
import {LensRemoval} from "./LensRemoval.sol";

/// @title LensPositionsModule
/// @notice Lens module serving `ILensPositions`, `ILensActions` and `previewMaxWithdraw`.
contract LensPositionsModule is LensPositions, LensActions, LensRemoval {
    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
