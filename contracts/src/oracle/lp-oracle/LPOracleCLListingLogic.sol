// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleListingLogic} from "./LPOracleListingLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {InitParams} from "./types/InitParams.sol";

/// @title LPOracleCLListingLogic
/// @notice `checkConfig` of the concentrated-liquidity LPOracle, run by delegatecall from `LPOracleCL` (2.10 Listing and
/// configuration requirements).
/// @dev `initialize`'s market part runs in `LPOracleCLInitLogic`, so this contract carries only the checks.
/// @custom:spec REQ-ORACLE-046, REQ-ORACLE-080, REQ-ORACLE-105
contract LPOracleCLListingLogic is LPOracleListingLogic, LPOracleCLModuleCaller {
    /// @notice Fixes the chain constants, the `slot0` layout and the module contract; they must equal the
    /// implementation's.
    /// @custom:spec REQ-ORACLE-080
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

    /// @inheritdoc LPOracleListingLogic
    /// @dev Runs in `LPOracleCLInitLogic`.
    function initializeMarket(
        InitParams calldata
    ) external pure override {
        revert NotDelegated();
    }
}
