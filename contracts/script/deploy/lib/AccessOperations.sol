// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "./AvanaAccess.sol";
import {DeployInputs} from "./DeployInputs.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The AccessManager calls a script needs; the full interface is OpenZeppelin's `IAccessManager`.
interface IAccessManagerOps {
    function schedule(
        address target,
        bytes calldata data,
        uint48 when
    ) external returns (bytes32 operationId, uint32 nonce);

    function execute(
        address target,
        bytes calldata data
    ) external payable returns (uint32 nonce);

    function cancel(
        address caller,
        address target,
        bytes calldata data
    ) external returns (uint32 nonce);

    function multicall(
        bytes[] calldata data
    ) external returns (bytes[] memory results);

    function hashOperation(
        address caller,
        address target,
        bytes calldata data
    ) external view returns (bytes32);

    function getSchedule(
        bytes32 id
    ) external view returns (uint48);

    function getNonce(
        bytes32 id
    ) external view returns (uint32);

    function canCall(
        address caller,
        address target,
        bytes4 selector
    ) external view returns (bool allowed, uint32 delay);

    function hasRole(
        uint64 roleId,
        address account
    ) external view returns (bool isMember, uint32 executionDelay);

    function getTargetFunctionRole(
        address target,
        bytes4 selector
    ) external view returns (uint64);

    function getRoleGuardian(
        uint64 roleId
    ) external view returns (uint64);

    function labelRole(
        uint64 roleId,
        string calldata label
    ) external;

    function grantRole(
        uint64 roleId,
        address account,
        uint32 executionDelay
    ) external;

    function setRoleGuardian(
        uint64 roleId,
        uint64 guardian
    ) external;

    function setTargetFunctionRole(
        address target,
        bytes4[] calldata selectors,
        uint64 roleId
    ) external;
}

/// @title AccessOperations
/// @notice Builds batches of governed calls, writes them as JSON for the governance Safe (each call decoded, its
/// operation id and required delay, and the exact `multicall` calldata that schedules and executes them), and reads
/// them back.
/// @dev The AccessManager schedules one call at a time: the Safe sends `schedule(target, data, 0)` for every call of an
/// operation in one `multicall` (each call is ready after its own role's execution delay) and, once ready, the
/// matching `execute` calls, in order, from the same Safe (an operation is bound to its scheduler). The file
/// `deployments-local/<network>/operation-<name>.json` is what Safe signers check against the manifest (governance
/// README, signing procedure step 1: decode from the raw calldata). On anvil the scripts also schedule as the Safe
/// (an unlocked account) and execute once the delay has passed.
abstract contract AccessOperations is DeployInputs {
    struct Operation {
        string name;
        address[] targets;
        bytes[] payloads;
        string[] labels;
        uint256 capacity;
        // The execution gas `09_ListMarkets` estimated for the batch, 0 when not estimated.
        uint256 gasEstimate;
        // keccak256 of the listing metadata file the batch's market pages come from (`09_ListMarkets`), 0 for none.
        bytes32 metadataHash;
    }

    function _newOperation(
        string memory name,
        uint256 capacity
    ) internal pure returns (Operation memory op) {
        op.name = name;
        op.capacity = capacity;
        op.targets = new address[](capacity);
        op.payloads = new bytes[](capacity);
        op.labels = new string[](capacity);
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
        bytes[] memory p = op.payloads;
        string[] memory l = op.labels;
        assembly ("memory-safe") {
            mstore(t, n)
            mstore(p, n)
            mstore(l, n)
        }
    }

    function _operationPath(
        string memory name
    ) internal view returns (string memory) {
        return _outputPath(string.concat("operation-", name));
    }

    /// @notice The delay `scheduler` needs before each call of `op`; reverts when it may not make a call at all.
    function _callDelays(
        address manager,
        address scheduler,
        Operation memory op
    ) internal view returns (uint256[] memory delays) {
        delays = new uint256[](op.targets.length);
        for (uint256 i = 0; i < op.targets.length; ++i) {
            (bool immediate, uint32 delay) =
                IAccessManagerOps(manager).canCall(scheduler, op.targets[i], bytes4(op.payloads[i]));
            require(delay != 0 || immediate, string.concat(op.name, ": no role for ", op.labels[i], " (run 04)"));
            delays[i] = delay;
        }
    }

    /// @notice The delay after which every call of `op` is ready: the longest of the calls' delays.
    function _requiredDelay(
        address manager,
        address scheduler,
        Operation memory op
    ) internal view returns (uint256 required) {
        uint256[] memory delays = _callDelays(manager, scheduler, op);
        for (uint256 i = 0; i < delays.length; ++i) {
            if (delays[i] > required) required = delays[i];
        }
    }

    /// @notice The id the AccessManager gives each call of `op` scheduled by `scheduler`.
    function _operationIds(
        address manager,
        address scheduler,
        Operation memory op
    ) internal view returns (bytes32[] memory ids) {
        ids = new bytes32[](op.targets.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            ids[i] = IAccessManagerOps(manager).hashOperation(scheduler, op.targets[i], op.payloads[i]);
        }
    }

    /// @notice The `schedule` calls of `op` for one `multicall`, each at the earliest time its delay allows.
    function _scheduleCalls(
        Operation memory op
    ) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](op.targets.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            calls[i] = abi.encodeCall(IAccessManagerOps.schedule, (op.targets[i], op.payloads[i], uint48(0)));
        }
    }

    /// @notice The `execute` calls of `op` for one `multicall`.
    function _executeCalls(
        Operation memory op
    ) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](op.targets.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            calls[i] = abi.encodeCall(IAccessManagerOps.execute, (op.targets[i], op.payloads[i]));
        }
    }

    /// @notice Whether every call of `op` is scheduled already by `scheduler` (and not yet executed).
    function _isScheduled(
        address manager,
        address scheduler,
        Operation memory op
    ) internal view returns (bool) {
        bytes32[] memory ids = _operationIds(manager, scheduler, op);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (IAccessManagerOps(manager).getSchedule(ids[i]) == 0) return false;
        }
        return ids.length != 0;
    }

    /// @notice Writes one operation for the Safe and returns the delay after which all its calls are ready.
    function _writeOperation(
        address manager,
        address scheduler,
        Operation memory op
    ) internal returns (uint256 required) {
        uint256[] memory delays = _callDelays(manager, scheduler, op);
        for (uint256 i = 0; i < delays.length; ++i) {
            if (delays[i] > required) required = delays[i];
        }
        string memory k = string.concat("op.", op.name);
        vm.serializeString(k, "name", op.name);
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "accessManager", manager);
        vm.serializeAddress(k, "scheduler", scheduler);
        vm.serializeBytes32(k, "ids", _operationIds(manager, scheduler, op));
        if (op.gasEstimate != 0) vm.serializeUint(k, "gasEstimate", op.gasEstimate);
        if (op.metadataHash != 0) vm.serializeBytes32(k, "metadataHash", op.metadataHash);
        vm.serializeUint(k, "delay", required);
        vm.serializeUint(k, "delays", delays);
        vm.serializeAddress(k, "targets", op.targets);
        vm.serializeBytes(k, "payloads", op.payloads);
        vm.serializeString(k, "labels", op.labels);
        bool direct = op.targets.length != 0;
        for (uint256 i = 0; i < op.targets.length; ++i) {
            direct = direct && op.targets[i] == manager;
        }
        // An operation of the manager's own admin functions (role labels, grants, function roles) is not scheduled: the
        // DAO, the manager's admin, sends these calls at once in one `multicall`.
        if (direct) vm.serializeBytes(k, "directCalldata", abi.encodeCall(IAccessManagerOps.multicall, (op.payloads)));
        vm.serializeBytes(k, "executeCalldata", abi.encodeCall(IAccessManagerOps.multicall, (_executeCalls(op))));
        string memory json =
            vm.serializeBytes(k, "scheduleCalldata", abi.encodeCall(IAccessManagerOps.multicall, (_scheduleCalls(op))));
        vm.writeJson(json, _operationPath(op.name));
    }

    /// @notice Whether `_writeOperation` wrote an operation of this name on this network.
    function _hasOperation(
        string memory name
    ) internal view returns (bool) {
        return vm.exists(_operationPath(name));
    }

    /// @notice Reads an operation written by `_writeOperation`.
    function _readOperation(
        string memory name
    ) internal view returns (address manager, address scheduler, Operation memory op) {
        string memory json = vm.readFile(_operationPath(name));
        manager = vm.parseJsonAddress(json, ".accessManager");
        scheduler = vm.parseJsonAddress(json, ".scheduler");
        op.name = name;
        op.targets = vm.parseJsonAddressArray(json, ".targets");
        op.payloads = vm.parseJsonBytesArray(json, ".payloads");
        op.labels = vm.parseJsonStringArray(json, ".labels");
        op.capacity = op.targets.length;
    }

    /// @notice Writes the DAO's operation and, with `AVANA_SCHEDULE`, sends it as the DAO in one `multicall`.
    function _sendAsDao(
        address manager,
        Operation memory op,
        address dao
    ) internal {
        if (op.targets.length == 0) {
            console2.log(op.name, "nothing to send: everything in the config is already on chain");
            return;
        }
        _writeOperation(manager, dao, op);
        console2.log(op.name, _operationPath(op.name));
        if (vm.envOr("AVANA_SCHEDULE", false)) {
            vm.broadcast(dao);
            IAccessManagerOps(manager).multicall(op.payloads);
            console2.log("sent as the DAO", dao);
        }
    }

    /// @notice Writes the operation and, with `AVANA_SCHEDULE`, schedules it as the Safe, each call ready after the
    /// execution delay of its role.
    function _scheduleAs(
        address manager,
        Operation memory op,
        address safe
    ) internal {
        if (op.targets.length == 0) {
            console2.log(op.name, "nothing to schedule: everything in the config is already on chain");
            return;
        }
        uint256 delay = _writeOperation(manager, safe, op);
        console2.log(op.name, _operationPath(op.name), "ready after", delay);
        if (vm.envOr("AVANA_SCHEDULE", false) && !_isScheduled(manager, safe, op)) {
            vm.broadcast(safe);
            IAccessManagerOps(manager).multicall(_scheduleCalls(op));
            console2.log("scheduled as the governance Safe", safe);
        }
    }

    /// @notice The `setTargetFunctionRole` calls that map `target`'s governed functions of `kind` to their roles, for
    /// the functions not mapped yet.
    function _bind(
        Operation memory op,
        IAccessManagerOps m,
        AvanaAccess.Kind kind,
        address target
    ) internal view {
        uint64[] memory roles = AvanaAccess.roles();
        for (uint256 r = 0; r < roles.length; ++r) {
            bytes4[] memory all = AvanaAccess.selectorsOf(kind, roles[r]);
            bytes4[] memory missing = new bytes4[](all.length);
            uint256 n;
            for (uint256 i = 0; i < all.length; ++i) {
                if (m.getTargetFunctionRole(target, all[i]) != roles[r]) missing[n++] = all[i];
            }
            if (n == 0) continue;
            assembly ("memory-safe") {
                mstore(missing, n)
            }
            _add(
                op,
                address(m),
                abi.encodeCall(IAccessManagerOps.setTargetFunctionRole, (target, missing, roles[r])),
                string.concat("AccessManager.setTargetFunctionRole ", vm.getLabel(target))
            );
        }
    }
}
