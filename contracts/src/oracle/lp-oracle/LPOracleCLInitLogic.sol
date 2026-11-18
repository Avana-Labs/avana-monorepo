// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {ILPOracle} from "./ILPOracle.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleListingLogic} from "./LPOracleListingLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @title LPOracleCLInitLogic
/// @notice `initialize`'s market part of the concentrated-liquidity LPOracle, run by delegatecall.
/// @dev Runs `checkConfig` in the implementation's listing logic, since the proxy has no code yet.
contract LPOracleCLInitLogic is LPOracleListingLogic, LPOracleCLModuleCaller {
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

    /// @inheritdoc ILPOracleLogic
    function checkConfig(
        OracleConfig calldata
    ) external pure override returns (uint256) {
        revert NotDelegated();
    }

    /// @dev `checkConfig` of the implementation's listing logic; a failed or malformed answer fails every check.
    function _initCheck(
        OracleConfig calldata config
    ) internal override returns (uint256 failed) {
        address listing = ILPOracle(ERC1967Utils.getImplementation()).LISTING_LOGIC();
        // The implementation's own listing logic, changed only by a timelock upgrade; it makes only static calls.
        // forge-lint: disable-start(controlled-delegatecall)
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = listing.delegatecall(abi.encodeCall(ILPOracleLogic.checkConfig, (config)));
        // forge-lint: disable-end(controlled-delegatecall)
        failed = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max;
    }
}
