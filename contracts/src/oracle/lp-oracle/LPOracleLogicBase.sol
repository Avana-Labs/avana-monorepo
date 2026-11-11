// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {ILPOracleLogic} from "./ILPOracleLogic.sol";
import {LPOracleListing} from "./LPOracleListing.sol";
import {LPOracleStorage} from "./LPOracleStorage.sol";
import {InitParams} from "./types/InitParams.sol";

/// @title LPOracleLogicBase
/// @notice Shared part of the two LPOracle logic contracts: the chain constants, the delegatecall guard and
/// `logicConfig()`.
/// @dev A logic contract runs only in a feed proxy's storage by delegatecall from the LPOracle implementation; its own
/// storage is never used. Each AMM protocol's implementation deploys its two logic contracts with its pricing module.
/// @custom:spec REQ-ORACLE-106, REQ-ORACLE-078, REQ-ORACLE-080, Q-240
abstract contract LPOracleLogicBase is LPOracleListing, ILPOracleLogic {
    /// @dev This contract's own address: a call executing here, not in a proxy, is not delegated.
    address private immutable _SELF;

    /// @notice Fixes the chain constants; they must equal the implementation's (`logicConfig`).
    /// @custom:spec REQ-ORACLE-080
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
    /// @custom:spec REQ-ORACLE-080
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
