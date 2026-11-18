// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgeCounters, PledgePreview} from "../../types/PositionTypes.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {PledgeCharge} from "./types/RiskModuleTypes.sol";

/// @title IRiskModulePledgeLogic
/// @notice The pledge check, its preview, the restore amount and the remaining-record minimum.
interface IRiskModulePledgeLogic is IRiskModuleLogic {
    /// @notice Body of `IRiskModule.checkPledge`.
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

    /// @notice Body of `IRiskModule.previewPledge`.
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PledgePreview memory preview);

    /// @notice Body of `IRiskModule.usdToRestore`.
    function usdToRestore(
        address proxy
    ) external view returns (uint256 usd);

    /// @notice Body of `IRiskModule.checkRemainingRecord`.
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view;
}
