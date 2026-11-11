// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";

/// @title ParameterStoreForwardRisk
/// @notice The tighten and loosen setters of the market, Hub, cap, feed, tolerance and route parameters.
/// @dev Each function checks the caller's role and delegatecalls the logic contract that holds its body with the
/// unchanged calldata (`ParameterStoreRouter._forward`).
/// @custom:spec REQ-PSTORE-002, REQ-CONFIG-051, REQ-CONFIG-053
abstract contract ParameterStoreForwardRisk is ParameterStoreRouter, IParameterStoreTighten, IParameterStoreLoosen {
    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-050, REQ-CONFIG-051, REQ-PSTORE-031, Q-398
    function tightenHardHealthFloor(
        uint256,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-052
    function tightenSlippageAllowanceBps(
        uint256,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-051, Q-198, Q-380
    function tightenFloorRoundingAllowance(
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-009, Q-182
    function tightenBorrowPriceMaxAge(
        address,
        uint32
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-052, REQ-PSTORE-009
    function tightenConsistencyToleranceBps(
        uint256,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-049, REQ-CONFIG-052, REQ-PSTORE-009
    function tightenFeedAgreementToleranceBps(
        address,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-015, REQ-CONFIG-049
    function tightenPoolRiskFactor(
        uint256,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-CONFIG-070, Q-379
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
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenMarketUsdCap(
        uint256,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenTopUpSliceUsd(
        uint256,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenTokenUsdCap(
        address,
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenDepositorUsdCap(
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044
    function tightenPoolShareMaxBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-PSTORE-005, Q-230
    function tightenMinPledgeUsd(
        uint256,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreTighten
    /// @custom:spec REQ-RISK-042, REQ-RISK-044, SPEC-CAP-005, Q-383, Q-399
    function tightenPoolShareMaxBpsOf(
        uint256,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-053, REQ-PSTORE-017, REQ-PSTORE-031, Q-398
    function loosenHardHealthFloor(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-CONFIG-049, REQ-CONFIG-053, REQ-CONFIG-071, REQ-PSTORE-017
    function loosenSlippageAllowanceBps(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-CONFIG-050, REQ-CONFIG-053, Q-198, Q-267, Q-380
    function loosenFloorRoundingAllowance(
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-CONFIG-070, Q-379
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
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, SPEC-CAP-006, REQ-PSTORE-017
    function loosenMarketUsdCap(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, SPEC-CAP-006, REQ-PSTORE-017
    function loosenTopUpSliceUsd(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, REQ-PSTORE-017
    function loosenTokenUsdCap(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, REQ-PSTORE-017
    function loosenDepositorUsdCap(
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, REQ-PSTORE-016
    function loosenPoolShareMaxBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-PSTORE-005, Q-230
    function loosenMinPledgeUsd(
        uint256,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStoreLoosen
    /// @custom:spec REQ-RISK-043, REQ-RISK-044, SPEC-CAP-005, Q-383, Q-399
    function loosenPoolShareMaxBpsOf(
        uint256,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }
}
