// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {MarketSpeedLimits, SpeedLimit} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreForwardRisk
/// @notice The tighten and loosen setters of the market, Hub, cap, feed and route parameters.
abstract contract ParameterStoreForwardRisk is ParameterStoreRouter, IParameterStore {
    /// @inheritdoc IParameterStore
    function marketSpeedLimits(
        uint256 marketId
    ) external view override returns (MarketSpeedLimits memory limits) {
        limits = _s().marketSpeed[marketId];
    }

    /// @inheritdoc IParameterStore
    function debtSpeedLimit(
        address hub,
        address asset
    ) external view override returns (SpeedLimit memory limit) {
        limit = _s().debtSpeed[hub][asset];
    }

    /// @inheritdoc IParameterStore
    function tightenMarketSpeedLimits(
        uint256,
        MarketSpeedLimits calldata
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenMarketSpeedLimits(
        uint256,
        MarketSpeedLimits calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function tightenDebtSpeedLimit(
        address,
        address,
        SpeedLimit calldata
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenDebtSpeedLimit(
        address,
        address,
        SpeedLimit calldata
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenSlippageAllowanceBps(
        uint256,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenFloorRoundingAllowance(
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenBorrowPriceMaxAge(
        address,
        uint32
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenPoolRiskFactor(
        uint256,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenRouteDepthThreshold(
        uint256,
        address,
        address,
        uint8,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenMarketUsdCap(
        uint256,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenTopUpSliceUsd(
        uint256,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenTokenUsdCap(
        address,
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    function tightenMinPledgeUsd(
        uint256,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenSlippageAllowanceBps(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenFloorRoundingAllowance(
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenRouteDepthThreshold(
        uint256,
        address,
        address,
        uint8,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenMarketUsdCap(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenTopUpSliceUsd(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenTokenUsdCap(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    function loosenMinPledgeUsd(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }
}
