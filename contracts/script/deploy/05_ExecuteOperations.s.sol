// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ITimelockOps, TimelockOperations} from "./lib/TimelockOperations.sol";
import {console2} from "forge-std/console2.sol";

/// @title ExecuteOperations
/// @notice Executes ready AvanaTimelock operations written by earlier steps; anyone may, while public execution is on.
/// @dev `AVANA_OPERATIONS` is a comma-separated list of operation names (default `guardian-roles,chain-wiring`). An
/// operation that is not ready is reported with its ready time and skipped; one already done is skipped.
contract ExecuteOperations is TimelockOperations {
    function run() external {
        string[] memory names = vm.split(vm.envOr("AVANA_OPERATIONS", string("guardian-roles,chain-wiring")), ",");
        for (uint256 i = 0; i < names.length; ++i) {
            (address timelock, Operation memory op,) = _readOperation(names[i]);
            ITimelockOps t = ITimelockOps(timelock);
            bytes32 id = t.hashOperationBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt);
            if (t.isOperationDone(id)) {
                console2.log("done already:", names[i]);
            } else if (!t.isOperationReady(id)) {
                console2.log("not ready:", names[i], "ready at", t.getTimestamp(id));
            } else {
                vm.broadcast();
                t.executeBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt);
                console2.log("executed:", names[i]);
            }
        }
    }
}
