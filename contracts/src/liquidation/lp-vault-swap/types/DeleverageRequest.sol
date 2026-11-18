// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../../types/PositionRef.sol";

/// @notice Arguments of `deleverage`, built by the AaveAdapter from the borrower's `repayWithCollateral` call.
/// @dev Amounts are in base units of the debt reserve's asset.
struct DeleverageRequest {
    address proxy;
    // Receives the leftover debt asset and any route residue.
    address wallet;
    address spoke;
    uint256 marketId;
    address vaultToken;
    PositionRef position;
    uint128 units;
    uint256 debtReserveId;
    // Least raw amount of each pool token the unwind must return, market token order.
    uint256[] minAmounts;
    uint256 minDebtRepaid;
}
