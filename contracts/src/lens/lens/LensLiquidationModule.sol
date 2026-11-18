// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensBase} from "./LensBase.sol";
import {LensLiquidation} from "./LensLiquidation.sol";

/// @title LensLiquidationModule
/// @notice Lens module serving `ILensLiquidation.previewLiquidation`.
contract LensLiquidationModule is LensLiquidation {
    /// @param core The nine core addresses, in `LensBase` order.
    /// @param sizing `LensAaveSizing`, Aave's pinned liquidation sizing.
    constructor(
        address[9] memory core,
        address sizing
    ) LensBase(core) LensLiquidation(sizing) {}
}
