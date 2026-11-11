// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeleverageRequest} from "./types/DeleverageRequest.sol";

/// @title ILPVaultSwapDeleverage
/// @notice Settlement piece of LPVaultSwap for the AaveAdapter's repay with collateral: converts units of a pledged
/// record into a repayment of the borrower's debt, with no liquidation bonus or Avana fee.
/// @dev The only LPVaultSwap path that takes a flash loan, through the chain's IFlashSource (Q-404).
/// Preserves backing (burn equals record debit; Collateralization's gap check), solvency (debt repaid before any
/// collateral leaves; the flash loan and fee covered or the call reverts), the health-factor floor (the AaveAdapter
/// requires Aave's HF after the call to be at least its value before and `minHealthFactor` while debt remains) and
/// conservation (no balance change in LPVaultSwap).
interface ILPVaultSwapDeleverage {
    /// @notice Repays part of a borrower's debt from the liquidity of one of its pledged records.
    /// @dev Reverts `NotAdapter` unless `msg.sender == AAVE_ADAPTER` and the lock is held by the AaveAdapter. Reads no
    /// pause state, breaker or freeze. Gates: market and debt reserve known (`UnknownMarket`, `UnknownDebtReserve`),
    /// the market's price fresh and agreeing (`StalePrice`), the repaid reserve's DebtOracle Live
    /// (`DebtPriceStale`), Hub shares == assets (`SharesNotEqualAssets`). Sizes the repayment per SPEC-LIQ-020
    /// (`DeleverageTooSmall`), sets the transient deleverage flag and flash-borrows `F` of the debt asset through the
    /// IFlashSource; inside `onFlashLoan` calls `AAVE_ADAPTER.deleverageRepay` then `AAVE_ADAPTER.deleverageRelease`
    /// (which reaches `Collateralization.releaseForDeleverage`, unwinding exactly `units` into n tokens at
    /// `r.minAmounts`), swaps each token other than the debt asset at its SPEC-LIQ-018 minimum with
    /// `sLeg = slippageAllowanceBps`, requires `R >= F + phi` (`DeleverageShortfall`), repays `F + phi` and sends the
    /// leftover debt asset and any residue to `r.wallet`. Emits `Deleveraged`. No breaker report.
    /// @param r The request built by the AaveAdapter.
    /// @return debtRepaid Debt reduction, debt-asset base units.
    /// @return debtAssetOut Debt asset sent to the borrower's wallet.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-013, REQ-SWAP-100, REQ-SWAP-116, SPEC-LIQ-018, SPEC-LIQ-020, Q-255, Q-250, Q-379
    function deleverage(
        DeleverageRequest calldata r
    ) external returns (uint256 debtRepaid, uint256 debtAssetOut);
}
