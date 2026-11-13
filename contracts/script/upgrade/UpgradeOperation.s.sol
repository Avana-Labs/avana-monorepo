// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Script, console2} from "forge-std/Script.sol";

/// @title UpgradeOperation
/// @notice Builds the AvanaTimelock operation that upgrades one UUPS proxy: the call
/// `proxy.upgradeToAndCall(implementation, initData)`, its operation id, and the exact `schedule` and `execute`
/// calldata the governance Safe signs. An upgrade is never on the short-delay list (`TimelockSelectors.isNeverShort`),
/// so the delay is the normal delay, within `[MIN_NORMAL_DELAY, MAX_DELAY]` = 345,600 to 432,000 s.
/// @dev Run only through `script/upgrade-operation.py`, which first requires a successful `security-slow.yml` run on
/// the implementation's source commit (`TEST-263`) and passes that run's id here; without it the script refuses.
/// Inputs (environment): `AVANA_UPGRADE_PROXY_NAME`, `AVANA_UPGRADE_PROXY`, `AVANA_UPGRADE_IMPLEMENTATION_NAME`,
/// `AVANA_UPGRADE_IMPLEMENTATION`, `AVANA_UPGRADE_COMMIT` (40 hex characters), `AVANA_UPGRADE_SLOW_RUN` (the run id),
/// optional `AVANA_UPGRADE_INIT_DATA` (default empty), `AVANA_UPGRADE_DELAY` (default 432,000) and
/// `AVANA_UPGRADE_PREDECESSOR` (default zero). Writes `deployments-local/upgrades/upgrade-<proxy name>-<commit>.json`.
contract UpgradeOperation is Script {
    uint256 internal constant MIN_NORMAL_DELAY = 345_600;
    uint256 internal constant MAX_DELAY = 432_000;

    struct Upgrade {
        string proxyName;
        address proxy;
        string implementationName;
        address implementation;
        string commit;
        string slowRun;
        bytes initData;
        uint256 delay;
        bytes32 predecessor;
    }

    function run() external returns (bytes memory scheduleCalldata) {
        Upgrade memory u = _inputs();
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (u.implementation, u.initData));
        bytes32 salt =
            keccak256(bytes(string.concat("avana.upgrade.", u.proxyName, ".", u.implementationName, ".", u.commit)));
        bytes32 id = keccak256(abi.encode(u.proxy, uint256(0), payload, u.predecessor, salt));
        scheduleCalldata =
            abi.encodeCall(TimelockController.schedule, (u.proxy, 0, payload, u.predecessor, salt, u.delay));
        bytes memory executeCalldata =
            abi.encodeCall(TimelockController.execute, (u.proxy, 0, payload, u.predecessor, salt));

        string memory k = "upgrade";
        vm.serializeString(k, "proxyName", u.proxyName);
        vm.serializeAddress(k, "proxy", u.proxy);
        vm.serializeString(k, "implementationName", u.implementationName);
        vm.serializeAddress(k, "implementation", u.implementation);
        vm.serializeString(k, "implementationCommit", u.commit);
        vm.serializeString(k, "securitySlowRun", u.slowRun);
        vm.serializeBytes(k, "initData", u.initData);
        vm.serializeBytes32(k, "id", id);
        vm.serializeBytes32(k, "salt", salt);
        vm.serializeBytes32(k, "predecessor", u.predecessor);
        vm.serializeUint(k, "delay", u.delay);
        vm.serializeBytes(k, "payload", payload);
        vm.serializeBytes(k, "executeCalldata", executeCalldata);
        string memory json = vm.serializeBytes(k, "scheduleCalldata", scheduleCalldata);
        string memory dir = string.concat(vm.projectRoot(), "/deployments-local/upgrades");
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/upgrade-", u.proxyName, "-", u.commit, ".json");
        vm.writeJson(json, path);

        console2.log("upgrade", u.proxyName, "->", u.implementationName);
        console2.log("implementation commit", u.commit);
        console2.log("security-slow run", u.slowRun);
        console2.log("operation id");
        console2.logBytes32(id);
        console2.log("schedule calldata (target: the AvanaTimelock)");
        console2.logBytes(scheduleCalldata);
        console2.log("written to", path);
    }

    function _inputs() internal view returns (Upgrade memory u) {
        u.slowRun = vm.envOr("AVANA_UPGRADE_SLOW_RUN", string(""));
        require(bytes(u.slowRun).length != 0, "no security-slow run given: use script/upgrade-operation.py");
        u.proxyName = vm.envString("AVANA_UPGRADE_PROXY_NAME");
        u.implementationName = vm.envString("AVANA_UPGRADE_IMPLEMENTATION_NAME");
        require(bytes(u.proxyName).length != 0 && bytes(u.implementationName).length != 0, "empty name");
        u.proxy = vm.envAddress("AVANA_UPGRADE_PROXY");
        u.implementation = vm.envAddress("AVANA_UPGRADE_IMPLEMENTATION");
        require(u.proxy != address(0) && u.implementation != address(0), "zero address");
        require(u.proxy != u.implementation, "proxy equals implementation");
        u.commit = vm.envString("AVANA_UPGRADE_COMMIT");
        require(bytes(u.commit).length == 40, "commit must be 40 hex characters");
        u.initData = vm.envOr("AVANA_UPGRADE_INIT_DATA", bytes(""));
        u.delay = vm.envOr("AVANA_UPGRADE_DELAY", MAX_DELAY);
        require(u.delay >= MIN_NORMAL_DELAY && u.delay <= MAX_DELAY, "delay outside the normal-delay bounds");
        u.predecessor = vm.envOr("AVANA_UPGRADE_PREDECESSOR", bytes32(0));
    }
}
