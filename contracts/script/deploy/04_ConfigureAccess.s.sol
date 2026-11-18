// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {RiskTier} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {AccessOperations, IAccessManagerOps} from "./lib/AccessOperations.sol";
import {AvanaAccess} from "./lib/AvanaAccess.sol";
import {ChainInputs} from "./lib/DeployTypes.sol";
import {console2} from "forge-std/console2.sol";

/// @notice The views 04 reads to leave out what is already on chain.
interface IWiringViews {
    function isRecordedHub(
        address hub
    ) external view returns (bool);
    function flashSource() external view returns (address);
    function lpVaultOf(
        uint32 integrationId
    ) external view returns (address);
}

interface IWiring {
    function recordHub(
        address hub,
        RiskTier tier
    ) external;
    function setFlashSource(
        address source
    ) external;
}

interface IFactoryRegistration {
    function registerIntegration(
        uint32 integrationId,
        address lpVault
    ) external;
}

/// @title ConfigureAccess
/// @notice Step 13 and the chain wiring, in two files for the two actors:
/// - `access-config`, sent by the DAO (the AccessManager's admin and the Aave governance executor) at once: the
///   labels and guardians of the Avana roles, the role of every governed function (`AvanaAccess`) on the chain's
///   ParameterStore, MarketRegistry, LPVaultSwap, VaultTokenFactory, RiskModule, AaveAdapter and LPVaults, and the role
///   grants: the governance Safe holds the tighten role (12 hours) and the governance role (the config's
///   `timelockNormalDelay` when it lies between 4 and 5 days, else 4 days), and the Joint Configuration Safe, the
///   risk steward, holds the tighten role with no delay. The DAO is the guardian of every role, so it can cancel any
///   scheduled operation. Emergency stops go through Aave's own reserve freeze, so the guardians hold no Avana role.
/// - `chain-wiring`, scheduled by the governance Safe at the governance delay: the chain's Avana Hubs, the flash source
///   and each LPVault in the VaultTokenFactory, the one integration registry. Run it once `access-config` is executed.
/// Scheduling needs `AVANA_SCHEDULE=1` and a node that accepts the DAO and the Safe as unlocked senders
/// (`anvil --auto-impersonate`), run with `--unlocked`. Each file holds only what the config adds to the chain.
contract ConfigureAccess is AccessOperations {
    function run() external {
        ChainInputs memory c = _loadInputs(_network());
        string memory out = vm.readFile(_outputPath("avana"));
        address manager = vm.parseJsonAddress(out, ".accessManager");
        Operation memory access = _accessConfig(c, out, manager);
        Operation memory wiring = _wiring(c, out);
        _sendAsDao(manager, access, c.gov.aaveGovernanceExecutor);
        if (access.targets.length != 0 && !vm.envOr("AVANA_SCHEDULE", false)) {
            // The Safe holds no role before the DAO has executed `access-config`; `chain-wiring` follows on a later run.
            console2.log("chain-wiring waits: execute access-config as the DAO, then run this step again");
            return;
        }
        _scheduleAs(manager, wiring, c.gov.governanceSafe);
    }

    function _accessConfig(
        ChainInputs memory c,
        string memory out,
        address manager
    ) private view returns (Operation memory op) {
        IAccessManagerOps m = IAccessManagerOps(manager);
        address[] memory lpVaults = vm.parseJsonAddressArray(out, ".lpVaults");
        op = _newOperation("access-config", 256 + 8 * lpVaults.length);
        uint64[2] memory ids = [AvanaRoles.TIGHTEN_ROLE, AvanaRoles.GOVERNANCE_ROLE];
        for (uint256 i = 0; i < ids.length; ++i) {
            uint32 want = AvanaAccess.roleDelay(ids[i], c.timelockNormalDelay);
            (bool member, uint32 delay) = m.hasRole(ids[i], c.gov.governanceSafe);
            if (member && delay == want) continue;
            if (!member) {
                _add(
                    op,
                    manager,
                    abi.encodeCall(IAccessManagerOps.labelRole, (ids[i], AvanaAccess.roleLabel(ids[i]))),
                    "AccessManager.labelRole"
                );
                _add(
                    op,
                    manager,
                    abi.encodeCall(IAccessManagerOps.setRoleGuardian, (ids[i], AvanaRoles.ADMIN_ROLE)),
                    "AccessManager.setRoleGuardian"
                );
            }
            _add(
                op,
                manager,
                abi.encodeCall(IAccessManagerOps.grantRole, (ids[i], c.gov.governanceSafe, want)),
                "AccessManager.grantRole governanceSafe"
            );
        }
        (bool steward,) = m.hasRole(AvanaRoles.TIGHTEN_ROLE, c.gov.jointConfigSafe);
        if (!steward) {
            _add(
                op,
                manager,
                abi.encodeCall(IAccessManagerOps.grantRole, (AvanaRoles.TIGHTEN_ROLE, c.gov.jointConfigSafe, 0)),
                "AccessManager.grantRole risk steward"
            );
        }
        _bind(op, m, AvanaAccess.Kind.ParameterStore, vm.parseJsonAddress(out, ".parameterStore.proxy"));
        _bind(op, m, AvanaAccess.Kind.MarketRegistry, vm.parseJsonAddress(out, ".marketRegistry.proxy"));
        _bind(op, m, AvanaAccess.Kind.LPVaultSwap, vm.parseJsonAddress(out, ".lpVaultSwap.proxy"));
        _bind(op, m, AvanaAccess.Kind.VaultTokenFactory, vm.parseJsonAddress(out, ".vaultTokenFactory"));
        _bind(op, m, AvanaAccess.Kind.RiskModule, vm.parseJsonAddress(out, ".riskModule.proxy"));
        _bind(op, m, AvanaAccess.Kind.AaveAdapter, vm.parseJsonAddress(out, ".aaveAdapter.proxy"));
        for (uint256 i = 0; i < lpVaults.length; ++i) {
            _bind(op, m, AvanaAccess.Kind.LpVault, lpVaults[i]);
        }
    }

    function _wiring(
        ChainInputs memory c,
        string memory out
    ) private view returns (Operation memory op) {
        address registry = vm.parseJsonAddress(out, ".marketRegistry.proxy");
        address factory = vm.parseJsonAddress(out, ".vaultTokenFactory");
        address[] memory lpVaults = vm.parseJsonAddressArray(out, ".lpVaults");
        op = _newOperation("chain-wiring", c.aave.hubs.length + 1 + lpVaults.length);
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
        }
    }
}
