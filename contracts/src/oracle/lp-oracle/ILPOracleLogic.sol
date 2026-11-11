// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {InitParams} from "./types/InitParams.sol";

/// @title ILPOracleLogic
/// @notice Entry points of the immutable logic contracts an LPOracle implementation runs by delegatecall: the poke
/// logic (`poke`), the listing logic (`initializeMarket`, `checkConfig`) and the view logic (the evaluation views of
/// `ILPOracle` under their own selectors).
/// @dev The whole LPOracle (evaluation, writing call and listing checks with a pricing module) does not fit the
/// 24,576-byte code limit in one contract, so each AMM protocol's implementation is a proxy target holding the roles,
/// the upgrade and the stored getters, plus three logic contracts compiled with the same pricing module; their addresses are implementation
/// immutables, so a new logic contract is part of a new implementation and waits the normal delay of
/// `upgradeToAndCall`. `poke` and `initializeMarket` revert `NotDelegated` unless they run in the feed proxy's context.
/// `logicConfig()` is the hash of the chain constants the implementation constructor compares with its own.
/// @custom:spec REQ-ORACLE-106, REQ-ORACLE-078, REQ-ORACLE-080, REQ-ORACLE-082, Q-240
interface ILPOracleLogic {
    /// @notice The writing call of `ILPOracle.poke`, run in the proxy's storage.
    /// @return state The state evaluated in this call.
    /// @custom:spec REQ-ORACLE-026
    function poke() external returns (PriceState state);

    /// @notice The market part of `ILPOracle.initialize`, run in the proxy's storage after the roles are granted.
    /// @param params Initialization arguments.
    /// @custom:spec REQ-ORACLE-058, REQ-ORACLE-059
    function initializeMarket(
        InitParams calldata params
    ) external;

    /// @notice `ILPOracle.checkConfig`, run in the proxy's storage.
    /// @param config Configuration to check.
    /// @return failedChecks Bitmap of failed checks.
    /// @custom:spec REQ-ORACLE-046
    function checkConfig(
        OracleConfig calldata config
    ) external view returns (uint256 failedChecks);

    /// @notice `keccak256(abi.encode(TIMELOCK, CHAIN_BLOCK_TIME, POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING,
    /// hasSequencer))` of this logic contract.
    /// @return config The hash.
    /// @custom:spec REQ-ORACLE-080
    function logicConfig() external view returns (bytes32 config);
}
