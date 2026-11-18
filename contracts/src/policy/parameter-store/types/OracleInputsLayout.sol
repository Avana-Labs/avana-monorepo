// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title OracleInputsLayout
/// @notice Word layout of `IParameterStore.getOracleInputs`, the configuration read of one LPOracle evaluation.
/// @dev `HEAD_WORDS` head words, then per token `TOKEN_WORDS`, plus `SECOND_WORDS` when second sources are requested.
library OracleInputsLayout {
    uint256 internal constant HEAD_WORDS = 10;
    uint256 internal constant LEG_WORDS = 8;
    /// @dev Tolerance, version, replaced slot, two leg counts, then four legs.
    uint256 internal constant TOKEN_WORDS = 5 + 4 * LEG_WORDS;
    uint256 internal constant SECOND_WORDS = 9;
}
