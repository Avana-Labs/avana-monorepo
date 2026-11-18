// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCL} from "./LPOracleCL.sol";
import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {LPOracleV4Module} from "./LPOracleV4Module.sol";
import {LPOracleV4ModuleLogic} from "./LPOracleV4ModuleLogic.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";
import {LPOracleLogicSet} from "./types/LPOracleLogicSet.sol";

/// @title LPOracleV4
/// @notice LPOracle implementation for the Uniswap v4 markets on one chain.
/// @dev Reverts `MarketMismatch(0)` unless the module logic is an `LPOracleV4ModuleLogic` with the same wrapped native.
contract LPOracleV4 is LPOracleCL, LPOracleV4Module {
    /// @notice Sets the chain constants, the module logic, the logic contracts and the wrapped native token.
    /// @param logics The poke, initialization, listing and view logic contracts.
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        address moduleLogic,
        LPOracleLogicSet memory logics,
        address wrappedNative
    )
        LPOracleCL(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer, 7, moduleLogic, logics)
        LPOracleV4Module(wrappedNative)
    {
        if (
            LPOracleV4ModuleLogic(moduleLogic).MODULE_ID() != keccak256("avana.LPOracleV4ModuleLogic.v1")
                || LPOracleV4ModuleLogic(moduleLogic).WRAPPED_NATIVE() != wrappedNative
        ) revert MarketMismatch(0);
    }

    // ─── The v4 module's hooks over the concentrated-liquidity ones ───

    function _initMarket(
        bytes calldata marketData,
        address[] memory tokenList
    ) internal override(LPOracleStorage, LPOracleCLModule, LPOracleV4Module) returns (bool) {
        return LPOracleV4Module._initMarket(marketData, tokenList);
    }

    function _poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) internal view override(LPOracleStorage, LPOracleCLModule, LPOracleV4Module) returns (PoolCheck memory) {
        return LPOracleV4Module._poolCheck(quotes, prices, window, toleranceBps);
    }

    function _isOwnPool(
        bytes32 poolRef
    ) internal view override(LPOracleStorage, LPOracleCLModule, LPOracleV4Module) returns (bool) {
        return LPOracleV4Module._isOwnPool(poolRef);
    }

    function _rangeFails() internal view override(LPOracleCLModule, LPOracleV4Module) returns (bool) {
        return LPOracleV4Module._rangeFails();
    }

    function _clListingChecks(
        ClListingInputs memory x,
        uint256[] memory quotes
    ) internal view override(LPOracleCLModule, LPOracleV4Module) returns (uint256) {
        return LPOracleV4Module._clListingChecks(x, quotes);
    }

    function _clReport(
        bool priced,
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceTicks
    ) internal view override(LPOracleCLModule, LPOracleV4Module) returns (ClPriceStateView memory) {
        return LPOracleV4Module._clReport(priced, quotes, prices, window, toleranceTicks);
    }
}
