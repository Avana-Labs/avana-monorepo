// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {ChainInputs} from "./lib/DeployTypes.sol";
import {ITimelockOps, TimelockOperations} from "./lib/TimelockOperations.sol";
import {console2} from "forge-std/console2.sol";

interface IAccessControlGrant {
    function grantRole(
        bytes32 role,
        address account
    ) external;
}

interface IWiring {
    function recordHub(
        address hub,
        RiskTier tier
    ) external;
    function setFlashSource(
        address source
    ) external;
    function registerIntegration(
        uint32 integrationId,
        address lpVault,
        address pricing
    ) external;
    function setSequencer(
        address feed,
        uint32 gracePeriod
    ) external;
}

interface IFactoryRegistration {
    function registerIntegration(
        uint32 integrationId,
        address lpVault
    ) external;
}

/// @title ConfigureAccess
/// @notice Step 13 and the chain wiring: the first two AvanaTimelock operations, both at the normal delay, written for
/// the governance Safe and, on anvil, scheduled as the Safe.
/// @dev `guardian-roles` is the role-change operation of `REQ-ACCESS-027`: `APPLICATION_PAUSE_GUARDIAN` and
/// `APPLICATION_FREEZE_GUARDIAN` on the MarketRegistry for the Emergency Guardian, the Aave Protocol Guardian and the
/// Joint Configuration Safe; `APPLICATION_PAUSE_GUARDIAN` on the ParameterStore for the Emergency Guardian and the Aave
/// Protocol Guardian; `APPLICATION_RISK_STEWARD` on the ParameterStore for the Joint Configuration Safe. Only the Aave
/// governance executor can cancel it. `chain-wiring` records the chain's Avana Hubs, the flash source, each LPVault in
/// the VaultTokenFactory and in the MarketRegistry with its concentrated-liquidity LPOracle implementation as pricing,
/// and the sequencer feed on an L2. It is kept apart so a cancel of one never drops the other.
/// Scheduling as the Safe needs `AVANA_SCHEDULE=1` and a node that accepts the Safe as an unlocked sender
/// (`anvil --auto-impersonate`), run with `--unlocked --sender <safe>`.
contract ConfigureAccess is TimelockOperations {
    function run() external {
        ChainInputs memory c = _loadInputs(_network());
        string memory out = vm.readFile(_outputPath("avana"));
        address timelock = vm.parseJsonAddress(out, ".timelock");
        Operation memory roles = _guardianRoles(c, out);
        Operation memory wiring = _wiring(
            c, out, vm.parseJsonAddress(out, ".marketRegistry.proxy"), vm.parseJsonAddress(out, ".parameterStore.proxy")
        );
        console2.log("guardian-roles", vm.toString(_writeOperation(timelock, roles)), _operationPath(roles.name));
        console2.log("chain-wiring", vm.toString(_writeOperation(timelock, wiring)), _operationPath(wiring.name));
        if (vm.envOr("AVANA_SCHEDULE", false)) {
            ITimelockOps t = ITimelockOps(timelock);
            vm.startBroadcast(c.gov.governanceSafe);
            t.scheduleBatch(roles.targets, roles.values, roles.payloads, bytes32(0), roles.salt, 432_000);
            t.scheduleBatch(wiring.targets, wiring.values, wiring.payloads, bytes32(0), wiring.salt, 432_000);
            vm.stopBroadcast();
            console2.log("scheduled as the governance Safe", c.gov.governanceSafe);
        }
    }

    function _guardianRoles(
        ChainInputs memory c,
        string memory out
    ) private pure returns (Operation memory roles) {
        address registry = vm.parseJsonAddress(out, ".marketRegistry.proxy");
        address store = vm.parseJsonAddress(out, ".parameterStore.proxy");
        roles = _newOperation("guardian-roles", c.release, 9);
        address[3] memory mrGuardians = [c.gov.emergencyGuardian, c.gov.aaveProtocolGuardian, c.gov.jointConfigSafe];
        for (uint256 i = 0; i < 3; ++i) {
            _grant(
                roles, registry, AvanaRoles.APPLICATION_PAUSE_GUARDIAN, mrGuardians[i], "MarketRegistry PAUSE_GUARDIAN"
            );
            _grant(
                roles,
                registry,
                AvanaRoles.APPLICATION_FREEZE_GUARDIAN,
                mrGuardians[i],
                "MarketRegistry FREEZE_GUARDIAN"
            );
        }
        _grant(
            roles,
            store,
            AvanaRoles.APPLICATION_PAUSE_GUARDIAN,
            c.gov.emergencyGuardian,
            "ParameterStore PAUSE_GUARDIAN"
        );
        _grant(
            roles,
            store,
            AvanaRoles.APPLICATION_PAUSE_GUARDIAN,
            c.gov.aaveProtocolGuardian,
            "ParameterStore PAUSE_GUARDIAN"
        );
        _grant(roles, store, AvanaRoles.APPLICATION_RISK_STEWARD, c.gov.jointConfigSafe, "ParameterStore RISK_STEWARD");
    }

    function _wiring(
        ChainInputs memory c,
        string memory out,
        address registry,
        address store
    ) private pure returns (Operation memory op) {
        address factory = vm.parseJsonAddress(out, ".vaultTokenFactory");
        address[] memory pricing = vm.parseJsonAddressArray(out, ".clOraclePricing");
        address[] memory lpVaults = vm.parseJsonAddressArray(out, ".lpVaults");
        op = _newOperation("chain-wiring", c.release, c.aave.hubs.length + 2 + 2 * lpVaults.length);
        for (uint256 i = 0; i < c.aave.hubs.length; ++i) {
            _add(
                op,
                registry,
                abi.encodeCall(IWiring.recordHub, (c.aave.hubs[i].hub, RiskTier(c.aave.hubs[i].tier))),
                "MarketRegistry.recordHub"
            );
        }
        _add(
            op,
            registry,
            abi.encodeCall(IWiring.setFlashSource, (vm.parseJsonAddress(out, ".flashSource"))),
            "MarketRegistry.setFlashSource"
        );
        for (uint256 i = 0; i < lpVaults.length; ++i) {
            uint32 id = c.integrations[i].integrationId;
            _add(
                op,
                factory,
                abi.encodeCall(IFactoryRegistration.registerIntegration, (id, lpVaults[i])),
                "VaultTokenFactory.registerIntegration"
            );
            _add(
                op,
                registry,
                abi.encodeCall(IWiring.registerIntegration, (id, lpVaults[i], pricing[i])),
                "MarketRegistry.registerIntegration"
            );
        }
        if (c.hasSequencer) {
            _add(
                op,
                store,
                abi.encodeCall(IWiring.setSequencer, (c.sequencerFeed, c.sequencerGraceSeconds)),
                "ParameterStore.setSequencer"
            );
        }
    }

    function _grant(
        Operation memory op,
        address target,
        bytes32 role,
        address account,
        string memory label
    ) private pure {
        _add(op, target, abi.encodeCall(IAccessControlGrant.grantRole, (role, account)), label);
    }
}
