// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveView} from "./types/DebtReserveView.sol";
import {MarketView} from "./types/MarketView.sol";

/// @title ILensMarkets
/// @notice Market list and debt-reserve views of the Lens: identity, prices, supply, limits, rates and the rate curve.
interface ILensMarkets {
    /// @notice Returns one page of markets by ID (position p is market p + 1).
    /// @dev Page rules of `getRecords`; Cancelled and Closed markets included.
    /// @param offset First position.
    /// @param limit Largest number of markets.
    /// @return markets The page.
    /// @custom:spec REQ-LENS-045, REQ-LENS-023, REQ-LENS-024
    function getMarkets(
        uint256 offset,
        uint256 limit
    ) external view returns (MarketView[] memory markets);

    /// @notice Returns one market; `UnknownMarket` for an unlisted ID.
    /// @param marketId The market.
    /// @return market The view.
    /// @custom:spec REQ-LENS-045, REQ-LENS-022
    function getMarket(
        uint256 marketId
    ) external view returns (MarketView memory market);

    /// @notice Returns one enabled debt reserve; `UnknownDebtReserve` otherwise.
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The reserve.
    /// @return reserve The view.
    /// @custom:spec REQ-LENS-046, REQ-LENS-032
    function getDebtReserve(
        address spoke,
        uint256 debtReserveId
    ) external view returns (DebtReserveView memory reserve);

    /// @notice Returns every enabled debt reserve of a Spoke in `getDebtReserveIds` order.
    /// @param spoke The CDP Spoke.
    /// @return reserves The views.
    /// @custom:spec REQ-LENS-046
    function getDebtReserves(
        address spoke
    ) external view returns (DebtReserveView[] memory reserves);
}
