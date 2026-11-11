// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title LensConstants
/// @notice Fixed values of the Lens: the page limit and the margins that keep previews valid until inclusion.
/// @custom:spec REQ-LENS-020, REQ-LENS-023, REQ-LENS-028, REQ-LENS-035, REQ-LENS-036, REQ-LENS-044, Q-210, Q-268, Q-269, Q-398
library LensConstants {
    /// @notice Largest `limit` the paged Lens views accept, records per call.
    uint256 internal constant LENS_MAX_PAGE = 200;

    /// @notice Margin, bps: `previewLiquidation` quotes a whole debt as `ceil(total * (1e4 + margin) / 1e4)`, and a
    /// remainder below $1,050 counts as near Aave's `DUST_LIQUIDATION_THRESHOLD`.
    uint256 internal constant LENS_DUST_MARGIN_BPS = 500;

    /// @notice Health factor of the recommended borrow of `previewBorrowRecommended`, 1.10 in WAD. A display value with
    /// no on-chain effect (Q-398).
    uint256 internal constant RECOMMENDED_HEALTH_FACTOR = 1.1e18;

    /// @notice Margin on the target health factor of `previewBorrowMax`, bps (the 1.005 factor).
    uint256 internal constant BORROW_MAX_MARGIN_BPS = 50;

    /// @notice Margin on the debt quoted by `quoteRepayAll`, bps (the 1.001 factor).
    uint256 internal constant REPAY_ALL_MARGIN_BPS = 10;
}
