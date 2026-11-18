// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";

/// @title IRiskModuleSpeedLogic
/// @notice The net-flow borrow-speed and pledge-speed limits: each window after a charge or credit.
interface IRiskModuleSpeedLogic is IRiskModuleLogic {
    /// @notice Borrow-speed check of a borrow: both windows with the charges added; reverts when either does not fit.
    /// @param amount Base units borrowed.
    function borrowCharge(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (uint256 marketId, bytes32 debtKey, SpeedWindow memory market, SpeedWindow memory debt);

    /// @notice Pledge-speed check of a non-rescue pledge: the window with `usdCharge` added; reverts if it won't fit.
    /// @param bookedUsd `regularUsed + sliceUsed` before the pledge, 8-decimal USD.
    function pledgeCharge(
        uint256 marketId,
        uint256 bookedUsd,
        uint256 usdCharge
    ) external view returns (SpeedWindow memory pledge);

    /// @notice The borrow windows after a repay; the market window is credited the USD value, rounded down.
    /// @param amount Base units repaid.
    function repayCredit(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (uint256 marketId, bytes32 debtKey, SpeedWindow memory market, SpeedWindow memory debt);

    /// @notice The market's pledge window after a withdrawal released `usd` of booked value.
    /// @param usd Booked value released, 8-decimal USD.
    function withdrawCredit(
        uint256 marketId,
        uint256 usd
    ) external view returns (SpeedWindow memory pledge);

    /// @notice Both borrow windows of a market and reserve as the next borrow would see them.
    /// @return market The market window, 8-decimal USD.
    /// @return debt The (funding Hub, asset) window, asset base units.
    function borrowViews(
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (SpeedView memory market, SpeedView memory debt);

    /// @notice The market's pledge window as the next non-rescue pledge would see it.
    /// @dev Reads Collateralization's counters, so it reverts while the Lock is held.
    /// @return pledge The pledge window, 8-decimal USD.
    function pledgeView(
        uint256 marketId
    ) external view returns (SpeedView memory pledge);
}
