// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
import {ILensDynamicCap} from "./ILensDynamicCap.sol";
import {LensBase} from "./LensBase.sol";

/// @title LensDynamicCapModule
/// @notice Lens module serving `ILensDynamicCap`.
contract LensDynamicCapModule is LensBase, ILensDynamicCap {
    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}

    /// @inheritdoc ILensDynamicCap
    function getDynamicBorrowCap(
        uint256 marketId
    ) external view override returns (uint256 cap, uint256 debt, uint64 intervalStart) {
        _unlocked();
        (cap, debt, intervalStart) = IRiskModule(_RISK_MODULE).getDynamicBorrowCap(marketId);
    }
}
