// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStoreSpeed} from "./IParameterStoreSpeed.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {MarketSpeedLimits} from "./types/MarketSpeedLimits.sol";
import {SpeedLimit} from "./types/SpeedLimit.sol";

/// @title ParameterStoreForwardSpeed
/// @notice Speed-limit views and setters; each setter checks the caller's role and delegatecalls the logic contract.
abstract contract ParameterStoreForwardSpeed is ParameterStoreRouter, IParameterStoreSpeed {
    /// @inheritdoc IParameterStoreSpeed
    function marketSpeedLimits(
        uint256 marketId
    ) external view override returns (MarketSpeedLimits memory limits) {
        limits = _s().marketSpeed[marketId];
    }

    /// @inheritdoc IParameterStoreSpeed
    function debtSpeedLimit(
        address hub,
        address asset
    ) external view override returns (SpeedLimit memory limit) {
        limit = _s().debtSpeed[hub][asset];
    }

    /// @inheritdoc IParameterStoreSpeed
    function tightenMarketSpeedLimits(
        uint256,
        MarketSpeedLimits calldata
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreSpeed
    function loosenMarketSpeedLimits(
        uint256,
        MarketSpeedLimits calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreSpeed
    function tightenDebtSpeedLimit(
        address,
        address,
        SpeedLimit calldata
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreSpeed
    function loosenDebtSpeedLimit(
        address,
        address,
        SpeedLimit calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }
}
