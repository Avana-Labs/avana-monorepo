// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensBase} from "./LensBase.sol";
import {LensFees} from "./LensFees.sol";
import {LensMarkets} from "./LensMarkets.sol";

/// @title LensMarketsModule
/// @notice Lens module serving `ILensMarkets` and `ILensFees`.
contract LensMarketsModule is LensMarkets, LensFees {
    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
