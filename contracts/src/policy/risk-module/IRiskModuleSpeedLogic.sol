// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../parameter-store/types/MarketSpeedLimits.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {BorrowSpeedInputs} from "./types/BorrowSpeedInputs.sol";

/// @title IRiskModuleSpeedLogic
/// @notice The reads of the borrow-speed and pledge-speed limits (Q-411): bases, charges and parameters. The windows
/// themselves sit in the RiskModule proxy, which alone writes them (REQ-RISK-095).
/// @custom:spec REQ-RISK-092, REQ-RISK-093, REQ-RISK-097, Q-411
interface IRiskModuleSpeedLogic is IRiskModuleLogic {
    /// @notice Inputs of the borrow-speed check of a borrow of `amount` of reserve `debtReserveId` by `proxy`.
    /// @param proxy The account.
    /// @param debtReserveId The borrowed reserve.
    /// @param amount Base units borrowed.
    /// @return inputs The keys, the charge in USD, both bases and both parameter sets.
    /// @custom:spec REQ-RISK-092, SPEC-CAP-013
    function borrowInputs(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (BorrowSpeedInputs memory inputs);

    /// @notice Inputs of the borrow-speed views of a market and reserve, with no charge.
    /// @param marketId The market.
    /// @param debtReserveId The reserve.
    /// @return inputs As `borrowInputs` with `amountUsd = 0`.
    /// @custom:spec REQ-RISK-097
    function borrowInputsOf(
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (BorrowSpeedInputs memory inputs);

    /// @notice Inputs of the pledge-speed view of a market: its parameters and its booked value.
    /// @dev Reads Collateralization's counters, so it reverts while the Lock is held.
    /// @param marketId The market.
    /// @return limits The market's speed limits.
    /// @return bookedUsd `regularUsed + sliceUsed`, 8-decimal USD.
    /// @custom:spec REQ-RISK-093, REQ-RISK-097
    function pledgeInputsOf(
        uint256 marketId
    ) external view returns (MarketSpeedLimits memory limits, uint256 bookedUsd);
}
