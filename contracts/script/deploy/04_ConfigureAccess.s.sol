// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {RiskTier} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
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
/// @dev `guardian-roles` is the role-change operation of `REQ-ACCESS-027`: `APPLICATION_RISK_STEWARD` on the
/// ParameterStore for the Joint Configuration Safe. Only the Aave governance executor can cancel it. Emergency stops
/// go through Aave's own reserve freeze, so the guardians hold no Avana contract role. `chain-wiring` records the
/// chain's Avana Hubs, the flash source, each LPVault in the VaultTokenFactory and in the MarketRegistry with its
/// concentrated-liquidity LPOracle implementation as pricing. It is kept apart so a cancel of one never drops the
/// other.
/// Scheduling as the Safe needs `AVANA_SCHEDULE=1` and a node that accepts the Safe as an unlocked sender
/// (`anvil --auto-impersonate`), run with `--unlocked --sender <safe>`.
contract ConfigureAccess is TimelockOperations {
    function run() external {
        ChainInputs memory c = _loadInputs(_network());
        string memory out = vm.readFile(_outputPath("avana"));
        address timelock = vm.parseJsonAddress(out, ".timelock");
        Operation memory roles = _guardianRoles(c, out);
        Operation memory wiring = _wiring(c, out, vm.parseJsonAddress(out, ".marketRegistry.proxy"));
        _propose(timelock, roles, c.gov.governanceSafe);
        _propose(timelock, wiring, c.gov.governanceSafe);
    }

    /// @notice Writes the operation and, with `AVANA_SCHEDULE`, schedules it as the Safe. Each operation holds only
    /// what the config adds to the chain (a Hub, an integration, a role grant); with nothing new it is not written, and
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
            // The delay the timelock requires of it: the normal delay set at deployment (`timelockNormalDelay`).
            uint256 delay = ITimelockOps(timelock).requiredDelay(op.targets, op.payloads);
            vm.broadcast(safe);
            ITimelockOps(timelock).scheduleBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt, delay);
            console2.log("scheduled as the governance Safe", safe);
        }
    }

    function _guardianRoles(
        ChainInputs memory c,
        string memory out
    ) private view returns (Operation memory roles) {
        address store = vm.parseJsonAddress(out, ".parameterStore.proxy");
        roles = _newOperation("guardian-roles", c.release, 1);
        _grant(roles, store, AvanaRoles.APPLICATION_RISK_STEWARD, c.gov.jointConfigSafe, "ParameterStore RISK_STEWARD");
    }

    function _wiring(
        ChainInputs memory c,
        string memory out,
        address registry
    ) private view returns (Operation memory op) {
        address factory = vm.parseJsonAddress(out, ".vaultTokenFactory");
        address[] memory lpVaults = vm.parseJsonAddressArray(out, ".lpVaults");
        // Each market's LPOracle is a stateless contract deployed at listing; the integration's pricing is its LPVault,
        // which returns the composition the oracle values.
        address[] memory pricing = lpVaults;
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
