// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeleverageRequest} from "./types/DeleverageRequest.sol";

/// @title ILPVaultSwapDeleverage
/// @notice LPVaultSwap's repay-with-collateral path, with no liquidation bonus or Avana fee.
/// @dev The only LPVaultSwap path that takes a flash loan.
interface ILPVaultSwapDeleverage {
    /// @notice Repays part of a borrower's debt from the liquidity of one of its pledged records.
    /// @dev Only the AaveAdapter, while it holds the lock.
    function deleverage(
        DeleverageRequest calldata r
    ) external returns (uint256 debtRepaid, uint256 debtAssetOut);
}
