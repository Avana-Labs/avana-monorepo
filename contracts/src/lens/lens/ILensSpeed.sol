// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "../../policy/risk-module/types/RiskModuleTypes.sol";
import {BorrowSpeedView} from "./types/LensTypes.sol";

/// @title ILensSpeed
/// @notice Speed-limit views: how much can be borrowed or pledged now and when more frees up.
interface ILensSpeed {
    /// @notice The borrow-speed windows of a market and debt reserve and the amount borrowable now under both.
    function getBorrowSpeed(
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (BorrowSpeedView memory speed);

    /// @notice The pledge-speed window of a market, 8-decimal USD.
    function getPledgeSpeed(
        uint256 marketId
    ) external view returns (SpeedView memory pledge);
}
