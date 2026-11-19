// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "./IFlashLiquidator.sol";

/// @title IOperatorFlashLiquidator
/// @notice The operator variant of the flash liquidation helper: only `SIGNER` may call, and `FUNDING_SAFE` is the
/// only payer and recipient.
/// @dev A compromised signer can lose at most `MAX_TOP_UP_BPS` of the debt each call actually repaid.
interface IOperatorFlashLiquidator is IFlashLiquidator {
    /// @notice The only address allowed to call `flashLiquidate` and `claimEscrowed`.
    function SIGNER() external view returns (address signer);

    /// @notice The operator's funding Safe: payer of inventory and top-ups and recipient of every payout.
    function FUNDING_SAFE() external view returns (address safe);

    /// @notice Most net outlay of the Safe, and most top-up, per call as bps of the debt repaid (at most 10^4).
    function MAX_TOP_UP_BPS() external view returns (uint256 bps);
}
