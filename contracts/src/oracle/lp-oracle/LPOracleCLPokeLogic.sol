// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {LPOraclePokeLogic} from "./LPOraclePokeLogic.sol";

/// @title LPOracleCLPokeLogic
/// @notice `poke()` of the concentrated-liquidity LPOracle, run by delegatecall.
contract LPOracleCLPokeLogic is LPOraclePokeLogic, LPOracleCLModuleCaller {
    /// @notice Sets the chain constants, `slot0` layout and module contract; they must match the implementation.
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        uint8 slot0Words,
        address moduleLogic
    )
        LPOracleLogicBase(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer)
        LPOracleCLPool(slot0Words)
        LPOracleCLModuleCaller(moduleLogic)
    {}
}
