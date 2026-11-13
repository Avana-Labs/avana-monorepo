// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../../types/PositionRef.sol";

/// @notice Arguments of `AaveAdapter.repayWithCollateral`.
/// @dev `minDebtRepaid` and `minAssetOut` are in base units of the debt reserve's asset; `minAmounts` holds one raw minimum per pool
/// token, in the market's token order, for the unwind of `units`; `minHealthFactor` is WAD and applies while debt
/// remains after the call. Every swap leg also carries its oracle `minOut`, so the caller's minimums only tighten it;
/// `minAssetOut` bounds the debt asset the call pays the wallet after the flash loan and its premium, which the legs'
/// oracle minimums alone leave open to a sandwich of up to the market's slippage allowance.
/// @custom:spec REQ-ADAPTER-080, Q-255, Q-376
struct RepayWithCollateralParams {
    // The account's market.
    uint256 marketId;
    // Position of the record whose units repay.
    PositionRef position;
    // Credited units released from the record.
    uint128 units;
    // Debt reserve repaid.
    uint256 debtReserveId;
    // Least raw amount of each pool token the unwind must return.
    uint256[] minAmounts;
    // Smallest repayment accepted, debt-asset base units.
    uint256 minDebtRepaid;
    // Least debt asset paid to the wallet after the flash loan and its premium, debt-asset base units.
    uint256 minAssetOut;
    // Last valid block.timestamp.
    uint256 deadline;
    // Least Aave health factor after the call while debt remains, WAD.
    uint256 minHealthFactor;
}
