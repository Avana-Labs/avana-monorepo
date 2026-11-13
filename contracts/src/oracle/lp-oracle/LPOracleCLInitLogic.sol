// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {ILPOracleRouter} from "./ILPOracleRouter.sol";
import {LPOracleCLModuleCaller} from "./LPOracleCLModuleCaller.sol";
import {LPOracleCLPool} from "./LPOracleCLPool.sol";
import {LPOracleListingLogic} from "./LPOracleListingLogic.sol";
import {LPOracleLogicBase} from "./LPOracleLogicBase.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

/// @title LPOracleCLInitLogic
/// @notice `initialize`'s market part of the concentrated-liquidity LPOracle, run by delegatecall from `LPOracleCL`
/// (2.10 `initialize`).
/// @dev Runs `checkConfig` of the implementation's listing logic (`LPOracleCLListingLogic`, read from the
/// implementation the proxy points to) by delegatecall on the configuration it seeds, so the listing checks are
/// deployed once. `checkConfig` writes nothing and makes only static calls, so it cannot change the state `initialize`
/// is writing; the proxy's own `checkConfig` cannot be called here, because `initialize` runs inside the proxy's
/// constructor, before the proxy has code.
/// @custom:spec REQ-ORACLE-058, REQ-ORACLE-059, REQ-ORACLE-080
contract LPOracleCLInitLogic is LPOracleListingLogic, LPOracleCLModuleCaller {
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

    /// @inheritdoc ILPOracleLogic
    /// @dev Runs in `LPOracleCLListingLogic`.
    function checkConfig(
        OracleConfig calldata
    ) external pure override returns (uint256) {
        revert NotDelegated();
    }

    /// @dev `checkConfig` of the implementation's listing logic, run in this proxy's storage; a failed or malformed
    /// answer counts as every check failing.
    /// @custom:spec REQ-ORACLE-058, REQ-ORACLE-046
    function _initCheck(
        OracleConfig calldata config
    ) internal override returns (uint256 failed) {
        address listing = ILPOracleRouter(ERC1967Utils.getImplementation()).LISTING_LOGIC();
        // The implementation's own listing logic, fixed in its immutables; it runs only static calls. The
        // implementation is the proxy's ERC-1967 slot, which only an upgrade (the timelock) sets.
        // forge-lint: disable-start(controlled-delegatecall)
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = listing.delegatecall(abi.encodeCall(ILPOracleLogic.checkConfig, (config)));
        // forge-lint: disable-end(controlled-delegatecall)
        failed = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max;
    }
}
