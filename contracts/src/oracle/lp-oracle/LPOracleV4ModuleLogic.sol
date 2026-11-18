// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleCLModuleLogic} from "./LPOracleCLModuleLogic.sol";
import {ClPriceStateView} from "./LPOracleTypes.sol";
import {LPOracleV4Module} from "./LPOracleV4Module.sol";

/// @title LPOracleV4ModuleLogic
/// @notice The Uniswap v4 pricing module as one immutable logic contract, with the concentrated-liquidity entry points.
// Its entry points are the concentrated-liquidity module's, declared by no Avana interface.
// solhint-disable comprehensive-interface
// forge-lint: disable-next-line(missing-inheritance)
contract LPOracleV4ModuleLogic is LPOracleCLModuleLogic, LPOracleV4Module {
    bytes32 internal constant V4_MODULE_ID = keccak256("avana.LPOracleV4ModuleLogic.v1");

    /// @notice Sets the chain constants, the reference pool's `slot0` layout and the wrapped native token.
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer,
        address wrappedNative
    )
        LPOracleCLModuleLogic(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer, 7)
        LPOracleV4Module(wrappedNative)
    {}

    function MODULE_ID() external pure override returns (bytes32 id) {
        id = V4_MODULE_ID;
    }

    function _initMarket(
        bytes calldata market,
        address[] memory tokens
    ) internal override(LPOracleCLModule, LPOracleV4Module) returns (bool) {
        return LPOracleV4Module._initMarket(market, tokens);
    }

    function _poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) internal view override(LPOracleCLModule, LPOracleV4Module) returns (PoolCheck memory) {
        return LPOracleV4Module._poolCheck(quotes, prices, window, toleranceBps);
    }

    function _isOwnPool(
        bytes32 poolRef
    ) internal view override(LPOracleCLModule, LPOracleV4Module) returns (bool) {
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
