// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleStatusLogic
/// @notice The non-reverting account gate status (REQ-ADAPTER-038).
interface IRiskModuleStatusLogic is IRiskModuleLogic {
    /// @notice Body of `IRiskModuleViews.getAccountGateStatus`.
    /// @custom:spec REQ-ADAPTER-038, REQ-RISK-060
    function getAccountGateStatus(
        address proxy
    ) external view returns (AccountGateStatus memory status);
}
