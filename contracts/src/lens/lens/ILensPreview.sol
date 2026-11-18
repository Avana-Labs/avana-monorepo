// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILensPreview
/// @notice Borrower previews of the Lens, sized to stay valid until the transaction deadline.
interface ILensPreview {
    /// @notice Returns the largest borrow that keeps the health factor above the floor once debt grows to `deadline`.
    /// @dev Rounds down; 0 when a Hub is paused, the wallet is frozen or the borrow gate reverts.
    /// @return amount Debt-asset base units.
    function previewBorrowMax(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (uint256 amount);

    /// @notice Returns the borrow at `RECOMMENDED_HEALTH_FACTOR` next to the maximum of `previewBorrowMax`.
    /// @dev A display value; no contract enforces it.
    /// @return recommended Debt-asset base units at the recommended health factor, rounded down.
    function previewBorrowRecommended(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (uint256 recommended, uint256 maximum);

    /// @notice Returns the spend cap and approval for a repay-all included by `deadline`.
    /// @dev Debt grown to `deadline` plus a margin, rounded up; the AaveAdapter refunds the unused part.
    /// @return maxRepaySpend Debt-asset base units, rounded up.
    function quoteRepayAll(
        address borrower,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view returns (uint256 maxRepaySpend);

    /// @notice Returns the units a re-credit would add, their cap charge and whether only a rescue top-up books them.
    /// @return added Live units above the record's credited units.
    /// @return usdCharge Cap charge at the last accepted price (USD, 8 decimals, rounded up).
    function previewRecredit(
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (uint128 added, uint256 usdCharge, bool rescueOnly);

    /// @notice Returns the outcome of a repay with collateral at the block's prices.
    /// @dev Returns `(0, 0, current health factor)` when the call would revert.
    /// @param units Vault-token units to release.
    /// @return debtRepaid Debt-asset base units.
    /// @return debtAssetToWallet Debt asset returned to the wallet, base units.
    /// @return healthFactorAfter Aave health factor after the call, WAD, rounded down.
    function previewRepayWithCollateral(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint128 units,
        uint256 debtReserveId
    ) external view returns (uint256 debtRepaid, uint256 debtAssetToWallet, uint256 healthFactorAfter);
}
