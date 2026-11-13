// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployInputs} from "./DeployInputs.sol";

/// @notice The AvanaTimelock calls a script needs; the full interface is `src/governance/timelock/IAvanaTimelock.sol`.
interface ITimelockOps {
    function scheduleBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay
    ) external;

    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external payable;

    function hashOperationBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata payloads,
        bytes32 predecessor,
        bytes32 salt
    ) external pure returns (bytes32);

    function requiredDelay(
        address[] calldata targets,
        bytes[] calldata payloads
    ) external view returns (uint256);

    function isOperation(
        bytes32 id
    ) external view returns (bool);

    function isOperationReady(
        bytes32 id
    ) external view returns (bool);

    function isOperationDone(
        bytes32 id
    ) external view returns (bool);

    function getTimestamp(
        bytes32 id
    ) external view returns (uint256);
}

/// @title TimelockOperations
/// @notice Builds AvanaTimelock batches, writes them as JSON for the governance Safe (each call decoded, the
/// operation id, the required delay and the exact `scheduleBatch` and `executeBatch` calldata), and reads them back.
/// @dev The file `deployments-local/<network>/operations-<name>.json` is what Safe signers check against the manifest
/// (governance README, signing procedure step 1: decode from the raw calldata). On anvil the
/// scripts also schedule as the Safe (an unlocked account) and execute once the delay has passed.
abstract contract TimelockOperations is DeployInputs {
    struct Operation {
        string name;
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        string[] labels;
        bytes32 salt;
        uint256 capacity;
    }

    function _newOperation(
        string memory name,
        string memory releaseTag,
        uint256 capacity
    ) internal pure returns (Operation memory op) {
        op.name = name;
        op.capacity = capacity;
        op.targets = new address[](capacity);
        op.values = new uint256[](capacity);
        op.payloads = new bytes[](capacity);
        op.labels = new string[](capacity);
        op.salt = keccak256(bytes(string.concat("avana.", releaseTag, ".operation.", name)));
        // Lengths are set back to 0 and grow with each `_add`.
        _setLength(op, 0);
    }

    function _add(
        Operation memory op,
        address target,
        bytes memory payload,
        string memory label
    ) internal pure {
        uint256 n = op.targets.length;
        require(n < op.capacity, string.concat("operation ", op.name, " is full"));
        _setLength(op, n + 1);
        op.targets[n] = target;
        op.payloads[n] = payload;
        op.labels[n] = label;
    }

    function _setLength(
        Operation memory op,
        uint256 n
    ) private pure {
        address[] memory t = op.targets;
        uint256[] memory v = op.values;
        bytes[] memory p = op.payloads;
        string[] memory l = op.labels;
        assembly ("memory-safe") {
            mstore(t, n)
            mstore(v, n)
            mstore(p, n)
            mstore(l, n)
        }
    }

    function _operationPath(
        string memory name
    ) internal view returns (string memory) {
        return _outputPath(string.concat("operation-", name));
    }

    /// @notice Writes one operation for the Safe and returns its id.
    function _writeOperation(
        address timelock,
        Operation memory op
    ) internal returns (bytes32 id) {
        ITimelockOps t = ITimelockOps(timelock);
        id = t.hashOperationBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt);
        uint256 delay = t.requiredDelay(op.targets, op.payloads);
        string memory k = string.concat("op.", op.name);
        vm.serializeString(k, "name", op.name);
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "timelock", timelock);
        vm.serializeBytes32(k, "id", id);
        vm.serializeBytes32(k, "salt", op.salt);
        vm.serializeBytes32(k, "predecessor", bytes32(0));
        vm.serializeUint(k, "delay", delay);
        vm.serializeAddress(k, "targets", op.targets);
        vm.serializeUint(k, "values", op.values);
        vm.serializeBytes(k, "payloads", op.payloads);
        vm.serializeString(k, "labels", op.labels);
        vm.serializeBytes(
            k,
            "executeBatchCalldata",
            abi.encodeCall(ITimelockOps.executeBatch, (op.targets, op.values, op.payloads, bytes32(0), op.salt))
        );
        string memory json = vm.serializeBytes(
            k,
            "scheduleBatchCalldata",
            abi.encodeCall(ITimelockOps.scheduleBatch, (op.targets, op.values, op.payloads, bytes32(0), op.salt, delay))
        );
        vm.writeJson(json, _operationPath(op.name));
    }

    /// @notice Reads an operation written by `_writeOperation`.
    function _readOperation(
        string memory name
    ) internal view returns (address timelock, Operation memory op, uint256 delay) {
        string memory json = vm.readFile(_operationPath(name));
        timelock = vm.parseJsonAddress(json, ".timelock");
        op.name = name;
        op.targets = vm.parseJsonAddressArray(json, ".targets");
        op.values = vm.parseJsonUintArray(json, ".values");
        op.payloads = vm.parseJsonBytesArray(json, ".payloads");
        op.labels = vm.parseJsonStringArray(json, ".labels");
        op.salt = vm.parseJsonBytes32(json, ".salt");
        delay = vm.parseJsonUint(json, ".delay");
    }
}
