// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig, PriceState} from "../../types/OracleTypes.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleListing} from "./LPOracleListing.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {InitParams} from "./LPOracleTypes.sol";

/// @title LPOracleLogicBase
/// @notice Shared part of the LPOracle logic contracts: chain constants, delegatecall guard and `logicConfig()`.
abstract contract LPOracleLogicBase is LPOracleListing, ILPOracleLogic {
    /// @dev This contract's own address, to detect a non-delegated call.
    address private immutable _SELF;

    /// @notice Sets the chain constants; they must equal the implementation's.
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer
    ) LPOracleStorage(timelock, chainBlockTime, pokeMinGasFloor, pokeMinGasCeiling, hasSequencer) {
        _SELF = address(this);
    }

    /// @dev Reverts `NotDelegated` when the call runs in this contract's own context.
    modifier onlyDelegated() {
        if (address(this) == _SELF) revert NotDelegated();
        _;
    }

    /// @inheritdoc ILPOracleLogic
    function logicConfig() external view override returns (bytes32 config) {
        config = keccak256(
            abi.encode(_TIMELOCK, _CHAIN_BLOCK_TIME, _POKE_MIN_GAS_FLOOR, _POKE_MIN_GAS_CEILING, _HAS_SEQUENCER)
        );
    }

    /// @inheritdoc ILPOracleLogic
    /// @dev Unused in the listing logic; the poke logic overrides it.
    function poke() external virtual override returns (PriceState state);

    /// @inheritdoc ILPOracleLogic
    /// @dev Unused in the poke logic; the listing logic overrides it.
    function initializeMarket(
        InitParams calldata params
    ) external virtual override;

    /// @inheritdoc ILPOracleLogic
    /// @dev Unused in the poke logic; the listing logic overrides it.
    function checkConfig(
        OracleConfig calldata config
    ) external view virtual override returns (uint256 failedChecks);
}
