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

/// @notice The views 04 reads to leave out what is already on chain.
interface IWiringViews {
    function isRecordedHub(
        address hub
    ) external view returns (bool);
    function flashSource() external view returns (address);
    function lpVaultOf(
        uint32 integrationId
    ) external view returns (address);
    function sequencer() external view returns (address feed, uint32 gracePeriod);
    function hasRole(
        bytes32 role,
        address account
    ) external view returns (bool);
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
        _propose(timelock, roles, c.gov.governanceSafe);
        _propose(timelock, wiring, c.gov.governanceSafe);
    }

    /// @notice Writes the operation and, with `AVANA_SCHEDULE`, schedules it as the Safe. Each operation holds only
    /// what the config adds to the chain (a Hub, an integration, a guardian); with nothing new it is not written, and
    /// the previous file (already executed) stays.
    function _propose(
        address timelock,
        Operation memory op,
        address safe
    ) private {
        if (op.targets.length == 0) {
            console2.log(op.name, "nothing to schedule: everything in the config is already on chain");
            return;
        }
        _freshSalt(timelock, op);
        console2.log(op.name, vm.toString(_writeOperation(timelock, op)), _operationPath(op.name));
        if (vm.envOr("AVANA_SCHEDULE", false)) {
            vm.broadcast(safe);
            ITimelockOps(timelock).scheduleBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt, 432_000);
            console2.log("scheduled as the governance Safe", safe);
        }
    }

    function _guardianRoles(
        ChainInputs memory c,
        string memory out
    ) private view returns (Operation memory roles) {
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
    ) private view returns (Operation memory op) {
        address factory = vm.parseJsonAddress(out, ".vaultTokenFactory");
        address[] memory pricing = vm.parseJsonAddressArray(out, ".clOraclePricing");
        address[] memory lpVaults = vm.parseJsonAddressArray(out, ".lpVaults");
        op = _newOperation("chain-wiring", c.release, c.aave.hubs.length + 2 + 2 * lpVaults.length);
        for (uint256 i = 0; i < c.aave.hubs.length; ++i) {
            if (IWiringViews(registry).isRecordedHub(c.aave.hubs[i].hub)) continue;
            _add(
                op,
                registry,
                abi.encodeCall(IWiring.recordHub, (c.aave.hubs[i].hub, RiskTier(c.aave.hubs[i].tier))),
                "MarketRegistry.recordHub"
            );
        }
        if (IWiringViews(registry).flashSource() != vm.parseJsonAddress(out, ".flashSource")) {
            _add(
                op,
                registry,
                abi.encodeCall(IWiring.setFlashSource, (vm.parseJsonAddress(out, ".flashSource"))),
                "MarketRegistry.setFlashSource"
            );
        }
        for (uint256 i = 0; i < lpVaults.length; ++i) {
            uint32 id = c.integrations[i].integrationId;
            if (IWiringViews(factory).lpVaultOf(id) == lpVaults[i]) continue;
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
        (address feed, uint32 grace) = c.hasSequencer ? IWiringViews(store).sequencer() : (address(0), uint32(0));
        if (c.hasSequencer && (feed != c.sequencerFeed || grace != c.sequencerGraceSeconds)) {
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
    ) private view {
        if (IWiringViews(target).hasRole(role, account)) return;
        _add(op, target, abi.encodeCall(IAccessControlGrant.grantRole, (role, account)), label);
    }
}
