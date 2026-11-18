// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {InitParams} from "./LPOracleTypes.sol";

/// @title LPOraclePokeLogic
/// @notice The LPOracle's writing call, run by delegatecall; the implementation checks `pokeMinGas` first.
abstract contract LPOraclePokeLogic is LPOracleLogicBase {
    /// @inheritdoc ILPOracleLogic
    function poke() external override onlyDelegated returns (PriceState state) {
        state = _poke();
    }

    /// @inheritdoc ILPOracleLogic
    function initializeMarket(
        InitParams calldata
    ) external pure override {
        revert NotDelegated();
    }

    /// @inheritdoc ILPOracleLogic
    function checkConfig(
        OracleConfig calldata
    ) external pure override returns (uint256) {
        revert NotDelegated();
    }
}
