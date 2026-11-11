// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";

/// @title IRiskModuleStatusLogic
/// @notice The non-reverting account gate status (REQ-ADAPTER-038).
interface IRiskModuleStatusLogic is IRiskModuleLogic {
    /// @notice Body of `IRiskModuleViews.getAccountGateStatus`, without the pause fields: it reads no pause state and no
    /// address freeze, so no field it returns depends on them (PROP-066).
    /// @param proxy The account.
    /// @return status Every gate outcome; `pauseState` and `pauseReason` are left at None.
    /// @custom:spec REQ-ADAPTER-038, REQ-RISK-060
    function getAccountGateStatus(
        address proxy
    ) external view returns (AccountGateStatus memory status);

    /// @notice The pause state and reason of the account's market Hub, the only pause read of the status view.
    /// @param proxy The account.
    /// @return state `MarketRegistry.pauseState(hub)` of the market's home Hub.
    /// @return reason `MarketRegistry.pauseReason(hub)`.
    /// @custom:spec REQ-ADAPTER-038
    function pauseOf(
        address proxy
    ) external view returns (PauseState state, PauseReason reason);
}
