// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice The six immutable logic contracts the RiskModule calls for its check bodies.
/// @dev The RiskModule constructor checks every `logicConfig()`.
struct RiskModuleLogics {
    address drift;
    address breaker;
    address pledge;
    address borrow;
    address status;
    address speed;
}
