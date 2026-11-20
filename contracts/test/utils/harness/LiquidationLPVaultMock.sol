// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../../src/vault/interfaces/ILPVault.sol";

/// @title LiquidationLPVaultMock
/// @notice Storage-backed stand-in for the LPVault's `getMarket`, linked as the LiquidationModule's LP_VAULT in
/// certora/conf/LiquidationModule.conf so a market's pool tokens are fixed during a liquidation. The LPVault's other
/// functions are summarised in certora/specs/LiquidationModule.spec.
contract LiquidationLPVaultMock {
    mapping(uint256 marketId => ILPVault.Market) internal _markets;

    function getMarket(
        uint256 marketId
    ) external view returns (ILPVault.Market memory) {
        return _markets[marketId];
    }
}
