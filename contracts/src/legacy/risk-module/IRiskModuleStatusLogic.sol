// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus} from "../../types/MarketTypes.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleStatusLogic
/// @notice The non-reverting account gate status.
interface IRiskModuleStatusLogic is IRiskModuleLogic {
    /// @notice Body of `ILegacyRiskModule.getAccountGateStatus`.
    function getAccountGateStatus(
        address proxy
    ) external view returns (AccountGateStatus memory status);
}
