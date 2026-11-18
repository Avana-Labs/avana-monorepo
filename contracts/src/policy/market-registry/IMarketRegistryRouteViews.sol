// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "./types/DebtReserveDef.sol";

/// @title IMarketRegistryRouteViews
/// @notice Debt-reserve records, and swap-route slots of the MarketRegistry.
/// @dev Views never revert; an unknown key returns zeros and `false`.
interface IMarketRegistryRouteViews {
    /// @notice Returns an approved debt reserve's record.
    /// @return def Stored record (`approved == false` if unknown).
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory def);

    /// @notice Approved debt-reserve identifiers of a Spoke, in approval order.
    function getDebtReserveIds(
        address spoke
    ) external view returns (uint256[] memory reserveIds);

    /// @notice Whether a reserve is an approved debt reserve of a Spoke.
    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (bool approved);

    /// @notice A swap route slot of a market's pool token into a debt asset, and whether it is usable now.
    /// @param kind 0 primary, 1 backup.
    /// @return route Route contract (`address(0)` for an unknown key).
    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable);
}
