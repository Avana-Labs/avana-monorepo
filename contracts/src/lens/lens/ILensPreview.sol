// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensPreview
/// @notice Borrower previews of the Lens, each built to stay valid until inclusion: the largest borrow, the repay-all
/// spend cap, a re-credit and a repay with collateral.
interface ILensPreview {
    /// @notice Returns the protocol maximum borrow: the largest borrow that keeps the rescue-excluded health factor at or
    /// above `H0 * (1 + rate * (deadline - now)) * 1.005` once the debt has grown until `deadline`, with
    /// `H0 = max(1e18, hardHealthFloor(marketId))`: Aave's HF 1.00 unless the market's optional hard floor is set.
    /// @dev Rounds down; capped by the reserve's `drawCap` headroom; 0 when the account's borrow gate fails (price, breaker,
    /// pause, freeze, drift).
    /// @param wallet The borrower wallet.
    /// @param marketId The account's market (one PositionProxy per wallet and market).
    /// @param debtReserveId The debt reserve to borrow.
    /// @param deadline The transaction deadline.
    /// @return amount Debt-asset base units.
    /// @custom:spec REQ-LENS-035, REQ-LENS-041, SPEC-CF-005, Q-268, Q-381
    function previewBorrowMax(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (uint256 amount);

    /// @notice Returns the recommended borrow at `RECOMMENDED_HEALTH_FACTOR` (1.10) next to the protocol maximum of
    /// `previewBorrowMax` for the same arguments.
    /// @dev `recommended = min(maximum, floor(max(0, (sum_m CF_m * collateralValue_m - E) * WAD /
    /// RECOMMENDED_HEALTH_FACTOR - totalDebtValue) * 10^dd / Pdebt))`, with the Aave values, rescue-unit exclusion `E`,
    /// served debt price `Pdebt` and debt decimals `dd` of `previewBorrowMax`. A display value: no contract enforces
    /// it (Q-398). Example: $100,000 of collateral at a 70% collateral factor and no debt gives a borrowing capacity of
    /// $70,000 (the maximum at HF 1.00) and a recommended $70,000 / 1.10 = $63,636.
    /// @param wallet The borrower wallet.
    /// @param marketId The account's market.
    /// @param debtReserveId The debt reserve to borrow.
    /// @param deadline The transaction deadline.
    /// @return recommended Debt-asset base units at HF 1.10, rounded down.
    /// @return maximum `previewBorrowMax` for the same arguments.
    /// @custom:spec REQ-LENS-044, REQ-LENS-035, Q-398
    function previewBorrowRecommended(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (uint256 recommended, uint256 maximum);

    /// @notice Returns the spend cap and approval for a repay-all included by `deadline`.
    /// @dev `ceil(debt * (1 + rate * (deadline - now)) * 1.001)`; the AaveAdapter refunds the unused part in the same call.
    /// @param borrower The borrower wallet.
    /// @param marketId The account's market.
    /// @param debtReserveId The debt reserve.
    /// @param deadline The transaction deadline.
    /// @return maxRepaySpend Debt-asset base units, rounded up.
    /// @custom:spec REQ-LENS-036, Q-269
    function quoteRepayAll(
        address borrower,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (uint256 maxRepaySpend);

    /// @notice Returns the units a re-credit of a pledged position would add, their cap charge and whether only a
    /// rescue top-up can book them.
    /// @param marketId The record's market.
    /// @param positionKey The pledged position.
    /// @return added Live units above the record's credited units after reconciliation.
    /// @return usdCharge `SPEC-CAP-001` charge at the last accepted price (USD, 8 decimals, rounded up).
    /// @return rescueOnly True under `Paused(General)`, for a frozen depositor, or when pool share, a breaker or
    /// `minPledgeUsd` would refuse a regular top-up.
    /// @custom:spec REQ-LENS-038, SPEC-CAP-001, Q-254
    function previewRecredit(
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (uint128 added, uint256 usdCharge, bool rescueOnly);

    /// @notice Returns the outcome of a repay with collateral at the block's prices.
    /// @dev Sized by SPEC-LIQ-020; `debtAssetToWallet` assumes every leg swaps at the oracle value. Returns
    /// `(0, 0, current health factor)` when the call would revert (price gates, shares != assets,
    /// `Paused(MintPathSuspect)`, units above the record's credited units, no debt); `Paused(General)` and a frozen
    /// wallet leave it open, as at the AaveAdapter.
    /// @param wallet The borrower wallet.
    /// @param marketId The account's market.
    /// @param positionKey The record's position.
    /// @param units Vault-token units to release.
    /// @param debtReserveId The debt reserve to repay.
    /// @return debtRepaid Debt-asset base units.
    /// @return debtAssetToWallet Debt asset returned to the wallet, base units.
    /// @return healthFactorAfter Aave health factor after the call, WAD, rounded down.
    /// @custom:spec REQ-LENS-038, SPEC-LIQ-020, Q-255
    function previewRepayWithCollateral(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint128 units,
        uint256 debtReserveId
    ) external view returns (uint256 debtRepaid, uint256 debtAssetToWallet, uint256 healthFactorAfter);
}
