// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "./types/DebtReserveDef.sol";

/// @title IMarketRegistryRouteViews
/// @notice Debt-reserve records, and swap-route slots of the MarketRegistry.
/// @dev Every view is `view` and never reverts; an unknown key returns zeros and `false`, so every usability and
/// approval check fails closed. Route depth thresholds live in the ParameterStore.
interface IMarketRegistryRouteViews {
    /// @notice Returns an approved debt reserve's record.
    /// @param spoke CDP Spoke.
    /// @param reserveId Debt reserve identifier.
    /// @return def Stored record (`approved == false` if unknown).
    /// @custom:spec REQ-MREG-006, REQ-MREG-009, Q-233
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory def);

    /// @notice Approved debt-reserve identifiers of a Spoke, in approval order.
    /// @param spoke CDP Spoke.
    /// @return reserveIds Identifiers; the RiskModule's drift check compares this set with the reserves the Spoke
    /// reports borrowable (the Spoke's debt reserves are exactly those the MarketRegistry enabled).
    /// @custom:spec REQ-MREG-007, Q-281
    function getDebtReserveIds(
        address spoke
    ) external view returns (uint256[] memory reserveIds);

    /// @notice Whether a reserve is an approved debt reserve of a Spoke.
    /// @param spoke CDP Spoke.
    /// @param reserveId Reserve identifier.
    /// @return approved True if approved.
    /// @custom:spec REQ-MREG-007, Q-281
    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (bool approved);

    /// @notice Returns a swap route slot of a market's pool token into a debt asset and whether LPVaultSwap may use it
    /// now.
    /// @param marketId Market identifier.
    /// @param token Pool token.
    /// @param debtAsset Debt asset.
    /// @param kind 0 primary, 1 backup.
    /// @return route Route contract (`address(0)` for an unknown key).
    /// @return usable `status == Active`.
    /// @custom:spec REQ-CONFIG-063, Q-379
    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable);
}
