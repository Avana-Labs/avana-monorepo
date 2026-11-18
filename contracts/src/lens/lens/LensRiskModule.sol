// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensBase} from "./LensBase.sol";
import {LensHubAssets} from "./LensHubAssets.sol";

/// @title LensRiskModule
/// @notice Lens module serving `ILensRisk` and `ILensHubAssets`.
contract LensRiskModule is LensHubAssets {
    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
