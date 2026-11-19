// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {DynamicCap} from "./types/RiskModuleTypes.sol";

/// @title IRiskModuleDynamicCapLogic
/// @notice The per-market dynamic borrow cap of the Aave ARFC "Dynamic Caps Oracle: Rate Limiter".
interface IRiskModuleDynamicCapLogic is IRiskModuleLogic {
    /// @notice Dynamic cap check of a borrow: the market's interval after the borrow; reverts above the cap.
    /// @dev The first borrow of an interval fixes its cap `C = D_start + L(D_start)` on the market's current debt.
    /// @param amount Base units borrowed.
    /// @return marketId The account's market.
    /// @return next The interval to store: the stored one, or a new one opened by this borrow.
    function borrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (uint256 marketId, DynamicCap memory next);

    /// @notice The market's cap as the next borrow would see it, with the market's current debt.
    /// @return cap The running interval's cap, or the cap a new interval would fix on the current debt.
    /// @return debt The market's debt now, 8-decimal USD.
    /// @return intervalStart The running interval's start, or the current time when the next borrow opens one.
    function capView(
        uint256 marketId
    ) external view returns (uint256 cap, uint256 debt, uint64 intervalStart);
}
