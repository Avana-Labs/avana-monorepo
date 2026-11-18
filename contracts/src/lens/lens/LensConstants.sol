// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title LensConstants
/// @notice Fixed values of the Lens: the page limit and preview margins.
library LensConstants {
    /// @notice Largest `limit` the paged Lens views accept, records per call.
    uint256 internal constant LENS_MAX_PAGE = 200;

    /// @notice Margin, bps, `previewLiquidation` adds to a whole-debt quote and to Aave's dust threshold.
    uint256 internal constant LENS_DUST_MARGIN_BPS = 500;

    /// @notice Health factor of `previewBorrowRecommended`, WAD; display only.
    uint256 internal constant RECOMMENDED_HEALTH_FACTOR = 1.1e18;

    /// @notice Margin on the target health factor of `previewBorrowMax`, bps.
    uint256 internal constant BORROW_MAX_MARGIN_BPS = 50;

    /// @notice Margin on the debt quoted by `quoteRepayAll`, bps.
    uint256 internal constant REPAY_ALL_MARGIN_BPS = 10;
}
