// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationLogic} from "aave-v4/spoke/libraries/LiquidationLogic.sol";

/// @title LensAaveSizing
/// @notice Aave V4's liquidation sizing at the pinned release (a3ef63e), compiled from the pinned `LiquidationLogic`
/// source with Aave's own compiler settings (the `aave` profile), for the Lens's `previewLiquidation`.
/// @dev Read-only: one `view` function that returns `LiquidationLogic._calculateLiquidationAmounts` for the inputs a
/// `liquidationCall` would build in the same block (account data, positions, the account's dynamic configuration,
/// AaveOracle prices, drawn index, premium debt in RAY). No storage, no owner. The Lens's `LensLiquidationModule` holds
/// its address as an immutable and calls it by STATICCALL through `ILensAaveSizing`, whose struct layout is the ABI of
/// `CalculateLiquidationAmountsParams` and `LiquidationAmounts` (a Hub is an address). Keeping Aave's source out of
/// Avana's `src/` keeps Avana's build, lint and static analysis on Avana code only.
/// @custom:spec REQ-LENS-017, REQ-LENS-029, REQ-LENS-003, Q-232
contract LensAaveSizing {
    /// @notice Aave's liquidation amounts for `params`, exactly as `liquidationCall` computes them before its
    /// `MustNotLeaveDust` check on `debtToCover`.
    /// @param params The sizing inputs.
    /// @return amounts Collateral shares to liquidate and to the liquidator, drawn shares and premium debt (RAY).
    /// @custom:spec REQ-LENS-017
    function calculateLiquidationAmounts(
        LiquidationLogic.CalculateLiquidationAmountsParams memory params
    ) external view returns (LiquidationLogic.LiquidationAmounts memory amounts) {
        amounts = LiquidationLogic._calculateLiquidationAmounts(params);
    }
}
