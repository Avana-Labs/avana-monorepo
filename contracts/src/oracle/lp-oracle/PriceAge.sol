// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../types/PriceState.sol";
import {DebtPriceView} from "../debt-oracle/types/DebtPriceView.sol";

/// @title PriceAge
/// @notice The price-age rules execution applies, shared with the Lens so its freshness flags match.
/// @dev Both bounds are inclusive: age == maxAge passes.
library PriceAge {
    /// @notice `timestamp − updatedAt`, 0 for a timestamp in the future.
    function age(
        uint256 updatedAt
    ) internal view returns (uint256) {
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    /// @notice Borrow-side age rule: not in the future and `age ≤ maxAge`.
    function borrowFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge;
    }

    /// @notice Liquidation-side age rule: `age ≤ maxAge`, with a future timestamp counted as age 0.
    function liquidationFresh(
        uint256 updatedAt,
        uint256 maxAge
    ) internal view returns (bool) {
        return age(updatedAt) <= maxAge;
    }

    /// @notice The RiskModule's debt-price rule: Live, `borrowAllowed`, and the served timestamp within `maxAge`.
    function debtBorrowable(
        DebtPriceView memory v,
        uint256 maxAge
    ) internal view returns (bool) {
        return v.state == PriceState.Live && v.borrowAllowed && borrowFresh(v.servedUpdatedAt, maxAge);
    }
}
