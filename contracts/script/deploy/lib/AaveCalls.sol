// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveExecutor} from "./AavePayloads.sol";
import {CoreRecord} from "./CoreRecord.sol";
import {console2} from "forge-std/console2.sol";

/// @title AaveCalls
/// @notice An Aave-side AIP as a list of direct calls by the Aave governance executor (the account that holds the Aave
/// V4 roles): configurator listings, AccessManager grants and First-Loss Reserve settings, in order.
/// @dev On Ethereum and Base the calls are only written to `deployments-local/<network>/aip-<name>.json` for the AIP
/// author. On a test network the PayloadsController stand-in (`aaveLocal.payloadsController`) runs each through the
/// executor stand-in's `executeTransaction(target, 0, "", data, false)`, in order, and the file is written as well.
/// The calls are planned from the chain before any runs, so a call that needs an id an earlier call creates computes
/// it (a Hub gives assets consecutive ids).
abstract contract AaveCalls is CoreRecord {
    uint256 internal constant MAX_CALLS = 256;

    struct Calls {
        string name;
        address[] targets;
        bytes[] data;
        string[] labels;
        uint256 n;
    }

    function _newCalls(
        string memory name
    ) internal pure returns (Calls memory k) {
        k.name = name;
        k.targets = new address[](MAX_CALLS);
        k.data = new bytes[](MAX_CALLS);
        k.labels = new string[](MAX_CALLS);
    }

    function _call(
        Calls memory k,
        address target,
        bytes memory data,
        string memory label
    ) internal pure {
        require(k.n < MAX_CALLS, string.concat("AIP ", k.name, " is full"));
        (k.targets[k.n], k.data[k.n], k.labels[k.n]) = (target, data, label);
        ++k.n;
    }

    /// @notice Whether this chain runs the AIP itself: every chain but Ethereum and Base.
    function _runsAip() internal view returns (bool) {
        return block.chainid != 1 && block.chainid != 8453;
    }

    /// @notice Writes the AIP's calls and, on a test network, runs them through `executor` as `controller`.
    function _ship(
        Calls memory k,
        address executor,
        address controller
    ) internal {
        if (k.n == 0) {
            console2.log(string.concat("AIP ", k.name, ": nothing to propose, everything in the config is on chain"));
            return;
        }
        address[] memory targets = k.targets;
        bytes[] memory data = k.data;
        string[] memory labels = k.labels;
        uint256 n = k.n;
        assembly ("memory-safe") {
            mstore(targets, n)
            mstore(data, n)
            mstore(labels, n)
        }
        string memory o = string.concat("aip.", k.name);
        vm.serializeString(o, "name", k.name);
        vm.serializeAddress(o, "executor", executor);
        vm.serializeAddress(o, "targets", targets);
        vm.serializeString(o, "labels", labels);
        vm.writeJson(vm.serializeBytes(o, "calldatas", data), _outputPath(string.concat("aip-", k.name)));
        if (!_runsAip()) {
            console2.log(string.concat("AIP ", k.name, ": calls written for the AIP author"), n);
            return;
        }
        vm.startBroadcast(controller);
        for (uint256 i = 0; i < n; ++i) {
            IAaveExecutor(executor).executeTransaction(targets[i], 0, "", data[i], false);
        }
        vm.stopBroadcast();
        console2.log(string.concat("AIP ", k.name, ": executed by the governance executor"), executor, n);
    }

    /// @notice The executor (`aave.governanceExecutor`) and, on a test network, its owner stand-in.
    function _executorOf(
        string memory cfg
    ) internal view returns (address executor, address controller) {
        executor = _addr(cfg, ".aave.governanceExecutor");
        controller = _runsAip() ? _addr(cfg, ".aaveLocal.payloadsController") : address(0);
    }
}
