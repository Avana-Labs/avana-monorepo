// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketDef} from "../../types/MarketDef.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";

/// @title IMarketRegistryListing
/// @notice Governance listing of CDP Spokes, debt reserves, tokens, price routes and the market lifecycle.
/// @dev Every function except `initialize` requires `APPLICATION_ADMIN`.
interface IMarketRegistryListing {
    /// @notice Initializes the proxy storage.
    /// @dev Runs once, with the proxy deployment. Reverts `AdminRoleOnlyTimelock` unless `timelock == TIMELOCK`.
    function initialize(
        address timelock
    ) external;

    /// @notice Records a standard Aave V4 CDP Spoke, or re-approves a recorded one after an Aave upgrade.
    /// @dev The Spoke's implementation code hash must be approved, and the RiskModule's Aave config check must pass.
    function deployCdpSpoke(
        SpokeDef calldata def
    ) external returns (address spoke);

    /// @notice Enables a debt reserve on a CDP Spoke, with its funding Hub, price source and First-Loss Reserve.
    /// @dev Reverts `TransferFeeActive` if the asset charges a transfer fee, `LivenessBound` if a market loses routes.
    function enableDebtReserve(
        address spoke,
        DebtReserveDef calldata def
    ) external;

    /// @notice Removes a debt reserve that has nothing owed.
    /// @dev Reverts `DebtReserveInUse` while debt or deficit remains, or a live market settles in it.
    function removeDebtReserve(
        address spoke,
        uint256 reserveId
    ) external;

    /// @notice Lists a pool token or debt asset with its Chainlink routes and issuer probe.
    /// @dev Empty alternate and standby routes make a monitoring-only listing. ERC-777 tokens are refused.
    function listToken(
        address token,
        TokenDef calldata def
    ) external;

    /// @notice Replaces a token's three Chainlink routes and clears any standby switch.
    /// @dev Re-runs the route checks for every market using the token.
    function setPriceSource(
        address token,
        address[] calldata primaryRoute,
        address[] calldata alternateRoute,
        address[] calldata standbyRoute
    ) external;

    /// @notice Registers a collateral market on a CDP Spoke in `Registered` status, or re-registers a cancelled one.
    /// @dev The vault token must come from the factory and match the market; runs the registration checks.
    /// @return marketId Sequential identifier from 1, or the reserved identifier on a relisting.
    function listCollateralMarket(
        MarketDef calldata def
    ) external returns (uint256 marketId);

    /// @notice Runs the activation checks and sets the market `Active`.
    /// @dev Reverts `ActivationCheckFailed` or `LivenessBound` on the first failed check.
    function activateMarket(
        uint256 marketId
    ) external;

    /// @notice Cancels a `Registered` market, freeing its keys and reserving its identifier for its pool.
    function cancelRegistration(
        uint256 marketId
    ) external;

    /// @notice Moves an `Active` market to `Offboarding`, for good.
    /// @dev Blocks new pledges and borrowing against the market; repay, withdrawals and liquidation continue.
    function setMarketOffboarding(
        uint256 marketId
    ) external;
}
