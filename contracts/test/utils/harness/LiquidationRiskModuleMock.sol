// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModule} from "../../../src/risk/interfaces/IRiskModule.sol";

/// @title LiquidationRiskModuleMock
/// @notice Storage-backed stand-in for the RiskModule reads the LiquidationModule makes, linked as its RISK_MODULE in
/// certora/conf/LiquidationModule.conf so each market and the fee settings are fixed during a liquidation.
contract LiquidationRiskModuleMock {
    mapping(uint256 marketId => IRiskModule.Market) internal _markets;
    address public feeRecipient;
    uint256 public feeShareBps;

    function getMarket(
        uint256 marketId
    ) external view returns (IRiskModule.Market memory) {
        return _markets[marketId];
    }
}
