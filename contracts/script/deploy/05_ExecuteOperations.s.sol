// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccessOperations, IAccessManagerOps} from "./lib/AccessOperations.sol";
import {console2} from "forge-std/console2.sol";

/// @title ExecuteOperations
/// @notice Executes the ready calls of the AccessManager operations written by earlier steps, in order, as the
/// scheduler (an operation is bound to the Safe that scheduled it).
/// @dev `AVANA_OPERATIONS` is a comma-separated list of operation names (default `chain-wiring`). A call that is not
/// ready is reported with its ready time and the rest of the operation waits; a call already executed is skipped. The
/// parts of a split batch (`<name>.2`, `<name>.3`…) run after `<name>`, in order, once every call of the previous part
/// is executed. A call not executed within the manager's expiration (1 week after it is ready) is expired and has to be
/// scheduled again.
contract ExecuteOperations is AccessOperations {
    function run() external {
        string[] memory names = vm.split(vm.envOr("AVANA_OPERATIONS", string("chain-wiring")), ",");
        for (uint256 i = 0; i < names.length; ++i) {
            bool done = _executeOperation(names[i]);
            // A batch split in parts (`09_ListMarkets`): `<name>.2`, `<name>.3`… run in order, each after the previous
            // part is done.
            for (uint256 k = 2; done; ++k) {
                string memory part = string.concat(names[i], ".", vm.toString(k));
                if (!_hasOperation(part)) break;
                done = _executeOperation(part);
            }
        }
    }

    /// @return done Whether every call of the operation is executed.
    function _executeOperation(
        string memory name
    ) private returns (bool done) {
        (address manager, address scheduler, Operation memory op) = _readOperation(name);
        IAccessManagerOps m = IAccessManagerOps(manager);
        bytes32[] memory ids = _operationIds(manager, scheduler, op);
        for (uint256 i = 0; i < ids.length; ++i) {
            uint48 readyAt = m.getSchedule(ids[i]);
            if (readyAt == 0) {
                if (m.getNonce(ids[i]) != 0) continue;
                console2.log("not scheduled:", name, op.labels[i]);
                return false;
            }
            if (readyAt > block.timestamp) {
                console2.log(string.concat("not ready: ", name, " ", op.labels[i], ", ready at"), readyAt);
                return false;
            }
            vm.broadcast(scheduler);
            m.execute(op.targets[i], op.payloads[i]);
            console2.log("executed:", name, op.labels[i]);
        }
        return true;
    }
}
