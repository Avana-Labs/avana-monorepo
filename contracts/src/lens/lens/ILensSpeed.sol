// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SpeedView} from "../../policy/risk-module/types/SpeedView.sol";
import {BorrowSpeedView} from "./types/BorrowSpeedView.sol";

/// @title ILensSpeed
/// @notice The speed-limit reads of the app (REQ-LENS-061): how much can be borrowed or pledged now and when more
/// frees up.
/// @dev Served by `LensSpeedModule`; every view reverts `Locked()` while the Lock is held and never otherwise.
/// @custom:spec REQ-LENS-061, REQ-RISK-097, BOR-024, Q-411
interface ILensSpeed {
    /// @notice The borrow-speed windows of a market and debt reserve and the amount borrowable now under both.
    /// @dev Example: market room $250,000 and USDC at $0.9999 give `availableNow = 250,025,002,500` when the (Hub, USDC)
    /// window has more room.
    /// @param marketId The market.
    /// @param debtReserveId The debt reserve.
    /// @return speed Both windows, `availableNow` in base units of the asset and the earlier `moreAt`.
    /// @custom:spec REQ-LENS-061
    function getBorrowSpeed(
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (BorrowSpeedView memory speed);

    /// @notice The pledge-speed window of a market, 8-decimal USD.
    /// @param marketId The market.
    /// @return pledge The window as the RiskModule reports it.
    /// @custom:spec REQ-LENS-061
    function getPledgeSpeed(
        uint256 marketId
    ) external view returns (SpeedView memory pledge);
}
