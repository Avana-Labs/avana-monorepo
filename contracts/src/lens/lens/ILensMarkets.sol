// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveView, MarketView} from "./types/LensTypes.sol";

/// @title ILensMarkets
/// @notice Market list and debt-reserve views of the Lens: identity, prices, supply, limits, rates and the rate curve.
interface ILensMarkets {
    /// @notice Returns one page of markets by ID (position p is market p + 1).
    /// @dev Page rules of `getRecords`; Cancelled and Closed markets included.
    function getMarkets(
        uint256 offset,
        uint256 limit
    ) external view returns (MarketView[] memory markets);

    /// @notice Returns one market; `UnknownMarket` for an unlisted ID.
    function getMarket(
        uint256 marketId
    ) external view returns (MarketView memory market);

    /// @notice Returns one enabled debt reserve; `UnknownDebtReserve` otherwise.
    function getDebtReserve(
        address spoke,
        uint256 debtReserveId
    ) external view returns (DebtReserveView memory reserve);

    /// @notice Returns every enabled debt reserve of a Spoke in `getDebtReserveIds` order.
    function getDebtReserves(
        address spoke
    ) external view returns (DebtReserveView[] memory reserves);
}
