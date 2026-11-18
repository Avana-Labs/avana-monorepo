// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensBase} from "./LensBase.sol";
import {LensPrice} from "./LensPrice.sol";
import {LensSizing} from "./LensSizing.sol";

/// @title LensPriceModule
/// @notice Lens module serving the price and pause views of `ILensLiquidation`, and `previewDeleverageTo`.
contract LensPriceModule is LensPrice, LensSizing {
    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
