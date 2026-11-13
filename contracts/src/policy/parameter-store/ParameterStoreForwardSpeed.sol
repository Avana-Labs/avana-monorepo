// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStoreSpeed} from "./IParameterStoreSpeed.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {MarketSpeedLimits} from "./types/MarketSpeedLimits.sol";
import {SpeedLimit} from "./types/SpeedLimit.sol";

/// @title ParameterStoreForwardSpeed
/// @notice The speed-limit views and setters (Q-411): the views read the store, each setter checks the caller's role
/// and delegatecalls the tighten or loosen logic contract with the unchanged calldata.
/// @custom:spec REQ-PSTORE-035, REQ-PSTORE-036, REQ-PSTORE-002, Q-411
abstract contract ParameterStoreForwardSpeed is ParameterStoreRouter, IParameterStoreSpeed {
    /// @inheritdoc IParameterStoreSpeed
    /// @custom:spec REQ-PSTORE-035
    function marketSpeedLimits(
        uint256 marketId
    ) external view override returns (MarketSpeedLimits memory limits) {
        limits = _s().marketSpeed[marketId];
    }

    /// @inheritdoc IParameterStoreSpeed
    /// @custom:spec REQ-PSTORE-035
    function debtSpeedLimit(
        address hub,
        address asset
    ) external view override returns (SpeedLimit memory limit) {
        limit = _s().debtSpeed[hub][asset];
    }

    /// @inheritdoc IParameterStoreSpeed
    /// @custom:spec REQ-PSTORE-036, REQ-PSTORE-002
    function tightenMarketSpeedLimits(
        uint256,
        MarketSpeedLimits calldata
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreSpeed
    /// @custom:spec REQ-PSTORE-036
    function loosenMarketSpeedLimits(
        uint256,
        MarketSpeedLimits calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreSpeed
    /// @custom:spec REQ-PSTORE-036, REQ-PSTORE-002
    function tightenDebtSpeedLimit(
        address,
        address,
        SpeedLimit calldata
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreSpeed
    /// @custom:spec REQ-PSTORE-036
    function loosenDebtSpeedLimit(
        address,
        address,
        SpeedLimit calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }
}
