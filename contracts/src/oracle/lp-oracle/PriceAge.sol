// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";
import {DebtPriceView} from "../debt-oracle/types/DebtPriceView.sol";

/// @title PriceAge
/// @notice The price-age rules execution applies, shared with the Lens so its freshness flags are the same test.
/// @dev Borrow side (the RiskModule's steps (5) and (6)): a source timestamp in the future fails, otherwise
/// `timestamp − updatedAt ≤ maxAge` passes. Liquidation side (LPVaultSwap's price rules): a timestamp in the future
/// counts age 0, otherwise the same inclusive bound. Both bounds are inclusive: age == maxAge passes, maxAge + 1 fails.
/// @custom:spec REQ-RISK-061, REQ-SWAP-008, REQ-SWAP-091, REQ-LENS-015, REQ-LENS-030
library PriceAge {
    /// @notice `timestamp − updatedAt`, 0 for a timestamp in the future.
    function age(
        uint256 updatedAt
    ) internal view returns (uint256) {
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    /// @notice The borrow-side age rule: not in the future and `age ≤ maxAge`.
    function borrowFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge;
    }

    /// @notice The liquidation-side age rule: `age ≤ maxAge`, with a timestamp in the future counted as age 0.
    function liquidationFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return age(updatedAt) <= maxAge;
    }

    /// @notice The RiskModule's debt-price rule for one DebtOracle-priced reserve (step (6), REQ-RISK-061): Live, the
    /// oracle's own `borrowAllowed`, and its served route's timestamp within `maxAge`, the DebtOracle's
    /// `borrowPriceMaxAge()`.
    function debtBorrowable(
        DebtPriceView memory v,
        uint256 maxAge
    ) internal view returns (bool) {
        return v.state == PriceState.Live && v.borrowAllowed && borrowFresh(v.servedUpdatedAt, maxAge);
    }
}
