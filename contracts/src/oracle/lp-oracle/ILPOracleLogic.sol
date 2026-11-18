// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {InitParams} from "./types/InitParams.sol";

/// @title ILPOracleLogic
/// @notice Entry points of the immutable logic contracts an LPOracle implementation runs by delegatecall.
/// @dev `poke` and `initializeMarket` revert `NotDelegated` unless run in the feed proxy's context.
interface ILPOracleLogic {
    /// @notice The writing call of `ILPOracle.poke`, run in the proxy's storage.
    function poke() external returns (PriceState state);

    /// @notice The market part of `ILPOracle.initialize`, run in the proxy's storage after the roles are granted.
    function initializeMarket(
        InitParams calldata params
    ) external;

    /// @notice `ILPOracle.checkConfig`, run in the proxy's storage.
    function checkConfig(
        OracleConfig calldata config
    ) external view returns (uint256 failedChecks);

    /// @notice Hash of the chain constants, which the implementation constructor compares with its own.
    function logicConfig() external view returns (bytes32 config);
}
