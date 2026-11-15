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
/// @notice The LPOracle implementation of every Uniswap v4 market on one chain: the concentrated-liquidity
/// implementation with the v4 pricing module (`LPOracleV4Module`) compiled in for `initialize`, and the
/// concentrated-liquidity poke, initialization, listing and view logic contracts delegating their pricing hooks to an
/// `LPOracleV4ModuleLogic`. Every v4 market is an ERC-1967 proxy of it.
/// @dev `slot0Words` is 7, the reference Uniswap v3 pool's layout. The constructor also requires the module logic to be
/// an `LPOracleV4ModuleLogic` with the same wrapped native token (`MarketMismatch(0)` otherwise).
/// @custom:spec REQ-ORACLE-080, REQ-ORACLE-103, REQ-AMM-V4-005, SPEC-AMM-V4-001
contract LPOracleV4 is LPOracleCL, LPOracleV4Module {
    /// @notice Fixes the chain constants, the module logic, the four logic contracts and the wrapped native token.
    /// @param timelock The chain's AvanaTimelock.
    /// @param chainBlockTime Seconds per block (12 on Ethereum).
    /// @param pokeMinGasFloor `POKE_MIN_GAS_FLOOR`.
    /// @param pokeMinGasCeiling `POKE_MIN_GAS_CEILING`.
    /// @param hasSequencer True on an L2 with a sequencer-uptime feed.
    /// @param moduleLogic The implementation's `LPOracleV4ModuleLogic`.
    /// @param logics The concentrated-liquidity poke, initialization, listing and view logic contracts built with it.
    /// @param wrappedNative The chain's wrapped native token.
    /// @custom:spec REQ-ORACLE-080
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
        bytes calldata market,
        address[] memory tokens
    ) internal override(LPOracleStorage, LPOracleCLModule, LPOracleV4Module) returns (bool) {
        return LPOracleV4Module._initMarket(market, tokens);
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
