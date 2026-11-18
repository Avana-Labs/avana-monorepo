// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracleCL} from "./ILPOracleCL.sol";
import {LPOracle} from "./LPOracle.sol";
import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {ClPriceStateView, LPOracleLogicSet} from "./LPOracleTypes.sol";

/// @title LPOracleCL
/// @notice LPOracle implementation for the concentrated-liquidity markets of one AMM protocol on one chain.
/// @dev Reverts `MarketMismatch(0)` unless every logic contract shares its chain constants, `slot0` layout and module.
contract LPOracleCL is LPOracle, LPOracleCLModule, ILPOracleCL {
    address internal immutable _MODULE_LOGIC;

    /// @param slot0Words 7 for Uniswap v3, 6 for Aerodrome Slipstream.
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        uint8 slot0Words,
        address moduleLogic,
        LPOracleLogicSet memory logics
    )
        LPOracle(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer, logics)
        LPOracleCLPool(slot0Words)
    {
        if (
            moduleLogic == address(0) || !_sameModule(logics.pokeLogic, slot0Words, moduleLogic)
                || !_sameModule(logics.initLogic, slot0Words, moduleLogic)
                || !_sameModule(logics.listingLogic, slot0Words, moduleLogic)
                || !_sameModule(logics.viewLogic, slot0Words, moduleLogic)
        ) revert MarketMismatch(0);
        _MODULE_LOGIC = moduleLogic;
    }

    /// @inheritdoc ILPOracleCL
    function MODULE_LOGIC() external view override returns (address moduleLogic) {
        moduleLogic = _MODULE_LOGIC;
    }

    /// @dev `logic` decodes the same `slot0` layout and delegates to the same module contract.
    function _sameModule(
        address logic,
        uint8 slot0Words,
        address moduleLogic
    ) private view returns (bool) {
        return LPOracleCLPool(logic).SLOT0_WORDS() == slot0Words
            && LPOracleCLModuleCaller(logic).MODULE_LOGIC() == moduleLogic;
    }

    /// @inheritdoc ILPOracleCL
    function getClPriceState() external view override returns (ClPriceStateView memory report) {
        _forward(_VIEW_LOGIC);
        return report;
    }
}
