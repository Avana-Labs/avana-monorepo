// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ITimelockOps, TimelockOperations} from "./lib/TimelockOperations.sol";
import {console2} from "forge-std/console2.sol";

/// @title ExecuteOperations
/// @notice Executes ready AvanaTimelock operations written by earlier steps; anyone may, while public execution is on.
/// @dev `AVANA_OPERATIONS` is a comma-separated list of operation names (default `guardian-roles,chain-wiring`). An
/// operation that is not ready is reported with its ready time and skipped; one already done is skipped. The parts of a
/// split batch (`<name>.2`, `<name>.3`…) run after `<name>`, in order.
contract ExecuteOperations is TimelockOperations {
    function run() external {
        string[] memory names = vm.split(vm.envOr("AVANA_OPERATIONS", string("guardian-roles,chain-wiring")), ",");
        for (uint256 i = 0; i < names.length; ++i) {
            (address timelock, Operation memory op,) = _readOperation(names[i]);
            bytes32 id = _execute(timelock, names[i], op);
            // A batch split in parts (`09_ListMarkets`): `<name>.2`, `<name>.3`… each name the previous part as its
            // predecessor. A part file left by an earlier, longer batch names another predecessor and ends the chain.
            for (uint256 k = 2;; ++k) {
                string memory part = string.concat(names[i], ".", vm.toString(k));
                if (!_hasOperation(part)) break;
                (address t, Operation memory next,) = _readOperation(part);
                if (t != timelock || next.predecessor != id) break;
                id = _execute(timelock, part, next);
            }
        }
    }

    /// @return id The operation's id.
    function _execute(
        address timelock,
        string memory name,
        Operation memory op
    ) private returns (bytes32 id) {
        ITimelockOps t = ITimelockOps(timelock);
        id = _operationId(timelock, op);
        if (t.isOperationDone(id)) {
            console2.log("done already:", name);
        } else if (!t.isOperationReady(id)) {
            console2.log("not ready:", name, "ready at", t.getTimestamp(id));
        } else {
            vm.broadcast();
            t.executeBatch(op.targets, op.values, op.payloads, op.predecessor, op.salt);
            console2.log("executed:", name);
        }
    }
}
