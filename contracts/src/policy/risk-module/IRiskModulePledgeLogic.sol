// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {PledgePreview} from "../../types/PledgePreview.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {PledgeCharge} from "./types/PledgeCharge.sol";

/// @title IRiskModulePledgeLogic
/// @notice The pledge check, its preview, the restore amount and the remaining-record minimum.
interface IRiskModulePledgeLogic is IRiskModuleLogic {
    /// @notice Body of `IRiskModuleChecks.checkPledge`.
    /// @custom:spec REQ-RISK-009, REQ-RISK-066
    function checkPledge(
        address depositor,
        address proxy,
        uint256 marketId,
        uint32 integrationId,
        bytes32 positionKey,
        uint128 units,
        PledgeCounters calldata counters,
        bool requireRescue
    ) external view returns (PledgeCharge memory charge);

    /// @notice Body of `IRiskModuleViews.previewPledge`.
    /// @custom:spec REQ-RISK-031
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PledgePreview memory preview);

    /// @notice Body of `IRiskModuleViews.usdToRestore`.
    /// @custom:spec SPEC-CAP-003
    function usdToRestore(
        address proxy
    ) external view returns (uint256 usd);

    /// @notice Body of `IRiskModuleChecks.checkRemainingRecord`.
    /// @custom:spec REQ-RISK-070
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view;
}
