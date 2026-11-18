// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus, PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleStatusLogic
/// @notice The non-reverting account gate status.
interface IRiskModuleStatusLogic is IRiskModuleLogic {
    /// @notice Body of `IRiskModule.getAccountGateStatus`, without the pause fields.
    function getAccountGateStatus(
        address proxy
    ) external view returns (AccountGateStatus memory status);

    /// @notice The pause state and reason of the account's market Hub, the only pause read of the status view.
    function pauseOf(
        address proxy
    ) external view returns (PauseState state, PauseReason reason);
}
