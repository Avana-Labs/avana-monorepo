// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";

/// @title IRiskModuleSpeedLogic
/// @notice The net-flow borrow-speed and pledge-speed limits (Q-411): bases, charges, credits, parameters and the new
/// window after each. The windows themselves sit in the RiskModule proxy, which alone writes them (REQ-RISK-095); the
/// functions that take a window read it from the caller's `getSpeedWindow`, so only the RiskModule's own calls see its
/// windows.
/// @custom:spec REQ-RISK-092, REQ-RISK-093, REQ-RISK-095, REQ-RISK-097, SPEC-CAP-011, SPEC-CAP-012, Q-411
interface IRiskModuleSpeedLogic is IRiskModuleLogic {
    /// @notice The borrow-speed check of a borrow (REQ-RISK-092): the market window first, then the (funding Hub,
    /// asset) window, each rolled to now and tested against its limit on the window-start base; reverts
    /// `BorrowSpeedExceeded` or `DebtSpeedExceeded`, else returns both windows with the charges added.
    /// @param proxy The account.
    /// @param debtReserveId The borrowed reserve.
    /// @param amount Base units borrowed.
    /// @return marketId The account's market, key of the market window.
    /// @return debtKey keccak256(abi.encode(fundingHub, asset)), key of the debt window.
    /// @return market The market window to store.
    /// @return debt The debt window to store.
    /// @custom:spec REQ-RISK-092, SPEC-CAP-011, SPEC-CAP-012, SPEC-CAP-013
    function borrowCharge(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (uint256 marketId, bytes32 debtKey, SpeedWindow memory market, SpeedWindow memory debt);

    /// @notice The pledge-speed check of a non-rescue pledge (REQ-RISK-093): the market's pledge window on the base
    /// `bookedUsd`; reverts `PledgeSpeedExceeded`, else returns the window with `usdCharge` added.
    /// @param marketId The market.
    /// @param bookedUsd `regularUsed + sliceUsed` before the pledge, 8-decimal USD.
    /// @param usdCharge The pledge's charge, 8-decimal USD.
    /// @return pledge The window to store.
    /// @custom:spec REQ-RISK-093, SPEC-CAP-011, SPEC-CAP-012
    function pledgeCharge(
        uint256 marketId,
        uint256 bookedUsd,
        uint256 usdCharge
    ) external view returns (SpeedWindow memory pledge);

    /// @notice The borrow windows after a repay of `amount` of `debtReserveId` on `proxy` (REQ-RISK-092): the market
    /// window credited `⌊amount × price8 / 10^dec⌋` USD at the reserve's AaveOracle price and the (funding Hub, asset)
    /// window credited `amount`, each from the current bucket first, then the bucket before while it counts, never
    /// below zero.
    /// @param proxy The account repaid.
    /// @param debtReserveId The reserve repaid.
    /// @param amount Base units repaid.
    /// @return marketId The account's market.
    /// @return debtKey keccak256(abi.encode(fundingHub, asset)).
    /// @return market The market window to store.
    /// @return debt The debt window to store.
    /// @custom:spec REQ-RISK-092, SPEC-CAP-011
    function repayCredit(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view returns (uint256 marketId, bytes32 debtKey, SpeedWindow memory market, SpeedWindow memory debt);

    /// @notice The market's pledge window after a withdrawal released `usd` of booked value (REQ-RISK-093), credited as
    /// `repayCredit` credits.
    /// @param marketId The market.
    /// @param usd Booked value released, 8-decimal USD.
    /// @return pledge The window to store.
    /// @custom:spec REQ-RISK-093, SPEC-CAP-011
    function withdrawCredit(
        uint256 marketId,
        uint256 usd
    ) external view returns (SpeedWindow memory pledge);

    /// @notice Both borrow windows of a market and reserve as the next borrow would see them (REQ-RISK-097).
    /// @param marketId The market.
    /// @param debtReserveId The reserve.
    /// @return market The market window, 8-decimal USD.
    /// @return debt The (funding Hub, asset) window, asset base units.
    /// @custom:spec REQ-RISK-097
    function borrowViews(
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (SpeedView memory market, SpeedView memory debt);

    /// @notice The market's pledge window as the next non-rescue pledge would see it (REQ-RISK-097).
    /// @dev Reads Collateralization's counters, so it reverts while the Lock is held.
    /// @param marketId The market.
    /// @return pledge The pledge window, 8-decimal USD.
    /// @custom:spec REQ-RISK-097
    function pledgeView(
        uint256 marketId
    ) external view returns (SpeedView memory pledge);
}
