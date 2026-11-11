// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../../types/PositionRef.sol";

/// @notice Arguments of `deleverage`, built by the AaveAdapter from the borrower's `repayWithCollateral` call.
/// @dev `units`, `minAmounts` and `minDebtRepaid` come from the borrower; the AaveAdapter fills `proxy`, `wallet` (the
/// caller of `repayWithCollateral`), `spoke`, `marketId` and `vaultToken` from its own binding. `minDebtRepaid` is in
/// base units of the debt reserve's asset; the flash loan, the swaps and the payout are all in that asset.
/// @custom:spec REQ-SWAP-106, SPEC-LIQ-020, Q-255, Q-379
struct DeleverageRequest {
    // Borrower's PositionProxy.
    address proxy;
    // Borrower wallet; receives the leftover debt asset and any route residue.
    address wallet;
    // CDP Spoke of the account.
    address spoke;
    // Market of the record being released.
    uint256 marketId;
    // The market's vault token.
    address vaultToken;
    // Position of the record.
    PositionRef position;
    // Vault-token units released from the record.
    uint128 units;
    // Debt reserve repaid.
    uint256 debtReserveId;
    // Least raw amount of each pool token the unwind must return, market token order.
    uint256[] minAmounts;
    // Smallest repayment the borrower accepts, debt-asset base units.
    uint256 minDebtRepaid;
}
