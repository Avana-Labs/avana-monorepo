// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../../types/PositionRef.sol";

/// @notice Arguments of `AaveAdapter.repayWithCollateral`.
/// @dev Asset amounts are debt-asset base units; `minHealthFactor` is WAD.
struct RepayWithCollateralParams {
    uint256 marketId;
    PositionRef position;
    uint128 units;
    uint256 debtReserveId;
    uint256[] minAmounts;
    uint256 minDebtRepaid;
    // Least debt asset paid to the wallet after the flash loan and its premium.
    uint256 minAssetOut;
    uint256 deadline;
    // Least health factor after the call while debt remains.
    uint256 minHealthFactor;
}
