// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCLModule} from "./LPOracleCLModule.sol";
import {LPOracleCLModuleLogic} from "./LPOracleCLModuleLogic.sol";
import {LPOracleV4Module} from "./LPOracleV4Module.sol";
import {ClPriceStateView} from "./types/ClPriceStateView.sol";

/// @title LPOracleV4ModuleLogic
/// @notice The Uniswap v4 pricing module as one immutable logic contract: the entry points of `LPOracleCLModuleLogic`
/// over `LPOracleV4Module`, so the concentrated-liquidity poke, initialization, listing and view logic contracts run it
/// by delegatecall unchanged (2.10 Upgrade rules).
/// @dev `slot0Words` is 7: the module's `slot0` reads go to the reference Uniswap v3 pool. Reports its own
/// `MODULE_ID()`, which the logic contracts accept alongside the concentrated-liquidity one.
/// @custom:spec REQ-ORACLE-080, REQ-ORACLE-103, REQ-AMM-V4-005
// Its entry points are the concentrated-liquidity module's, declared by no Avana interface.
// solhint-disable comprehensive-interface
// forge-lint: disable-next-line(missing-inheritance)
contract LPOracleV4ModuleLogic is LPOracleCLModuleLogic, LPOracleV4Module {
    /// @dev `MODULE_ID()` of the Uniswap v4 module.
    bytes32 internal constant V4_MODULE_ID = keccak256("avana.LPOracleV4ModuleLogic.v1");

    /// @notice Fixes the chain constants, the reference pool's `slot0` layout and the wrapped native token; they must
    /// equal the implementation's.
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

    /// @notice `keccak256("avana.LPOracleV4ModuleLogic.v1")`.
    function MODULE_ID() external pure override returns (bytes32 id) {
        id = V4_MODULE_ID;
    }

    // ─── The v4 module's hooks over the concentrated-liquidity ones ───

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
