// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title MockAuthority
/// @notice Minimal AccessManager stand-in for the symbolic harnesses: `canCall` is true, with no delay, exactly for the
/// (caller, selector) pairs the harness allowed. Unit tests and the fuzzing harness use a real AccessManager.
contract MockAuthority {
    mapping(address caller => mapping(bytes4 selector => bool allowed)) public allowed;

    function allow(
        address caller,
        bytes4 selector
    ) external {
        allowed[caller][selector] = true;
    }

    function canCall(
        address caller,
        address,
        bytes4 selector
    ) external view returns (bool immediate, uint32 delay) {
        return (allowed[caller][selector], 0);
    }
}
