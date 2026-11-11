// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {InitParams} from "./types/InitParams.sol";

/// @title LPOraclePokeLogic
/// @notice The LPOracle's writing call (`LPOraclePoke`), run by delegatecall from the implementation, which checks
/// `pokeMinGas` at entry before forwarding (`REQ-ORACLE-024`).
/// @custom:spec REQ-ORACLE-106, REQ-ORACLE-024, REQ-ORACLE-025, REQ-ORACLE-026
abstract contract LPOraclePokeLogic is LPOracleLogicBase {
    /// @inheritdoc ILPOracleLogic
    /// @custom:spec REQ-ORACLE-026
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
