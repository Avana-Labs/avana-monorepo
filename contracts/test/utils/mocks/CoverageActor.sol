// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title CoverageActor
/// @notice An address that forwards one call, so a sequence has a Spoke and an outsider that are contracts.
contract CoverageActor {
    function exec(
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }
}
