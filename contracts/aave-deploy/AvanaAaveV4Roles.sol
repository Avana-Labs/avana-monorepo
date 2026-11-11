// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {
    AaveV4AccessManagerRolesProcedure
} from "aave-v4/deployments/procedures/roles/AaveV4AccessManagerRolesProcedure.sol";
import {
    AaveV4HubConfiguratorRolesProcedure
} from "aave-v4/deployments/procedures/roles/AaveV4HubConfiguratorRolesProcedure.sol";
import {AaveV4HubRolesProcedure} from "aave-v4/deployments/procedures/roles/AaveV4HubRolesProcedure.sol";
import {
    AaveV4SpokeConfiguratorRolesProcedure
} from "aave-v4/deployments/procedures/roles/AaveV4SpokeConfiguratorRolesProcedure.sol";
import {AaveV4SpokeRolesProcedure} from "aave-v4/deployments/procedures/roles/AaveV4SpokeRolesProcedure.sol";
import {Roles} from "aave-v4/deployments/utils/libraries/Roles.sol";

/// @title AvanaAaveV4Roles
/// @notice Runs the pinned Aave V4 role procedures, unchanged, for the local Aave V4 deployment of the test fixture.
/// @dev Compiled only by the `aave` profile, next to the Aave sources, so Avana's own build never imports Aave code.
/// The fixture calls each function with `delegatecall` while it holds the AccessManager admin role, so every
/// AccessManager call comes from the fixture, exactly as in Aave's deploy orchestration where the deployer runs them.
/// The function order the fixture follows is the orchestration's: configurators, then each Hub and Spoke as it is
/// deployed, then the admin grants, then the admin handover.
contract AvanaAaveV4Roles {
    /// @notice Labels every Aave V4 role on the AccessManager.
    function labelAllRoles(
        address accessManager
    ) external {
        AaveV4AccessManagerRolesProcedure.labelAllRoles(accessManager);
    }

    /// @notice Assigns the HubConfigurator and SpokeConfigurator selectors to their domain admin roles.
    function setupConfigurators(
        address accessManager,
        address hubConfigurator,
        address spokeConfigurator
    ) external {
        AaveV4HubConfiguratorRolesProcedure.setupHubConfiguratorAllRoles(accessManager, hubConfigurator);
        AaveV4SpokeConfiguratorRolesProcedure.setupSpokeConfiguratorAllRoles(accessManager, spokeConfigurator);
    }

    /// @notice Assigns a Hub's selectors to the Hub roles.
    function setupHub(
        address accessManager,
        address hub
    ) external {
        AaveV4HubRolesProcedure.setupHubAllRoles(accessManager, hub);
    }

    /// @notice Assigns a Spoke's selectors to the Spoke roles.
    function setupSpoke(
        address accessManager,
        address spoke
    ) external {
        AaveV4SpokeRolesProcedure.setupSpokeAllRoles(accessManager, spoke);
    }

    /// @notice The orchestration's Hub grants: every Hub role to `hubAdmin`, the Hub configurator role to the
    /// HubConfigurator, and the HubConfigurator roles to `hubConfiguratorAdmin`.
    function grantHubRoles(
        address accessManager,
        address hubConfigurator,
        address hubAdmin,
        address hubConfiguratorAdmin
    ) external {
        AaveV4HubRolesProcedure.grantHubAllRoles(accessManager, hubAdmin);
        AaveV4HubRolesProcedure.grantHubRole(accessManager, Roles.HUB_CONFIGURATOR_ROLE, hubConfigurator);
        AaveV4HubConfiguratorRolesProcedure.grantHubConfiguratorAllRoles(accessManager, hubConfiguratorAdmin);
    }

    /// @notice The orchestration's Spoke grants: every Spoke role to `spokeAdmin`, the Spoke configurator role to the
    /// SpokeConfigurator, and the SpokeConfigurator roles to `spokeConfiguratorAdmin`.
    function grantSpokeRoles(
        address accessManager,
        address spokeConfigurator,
        address spokeAdmin,
        address spokeConfiguratorAdmin
    ) external {
        AaveV4SpokeRolesProcedure.grantSpokeAllRoles(accessManager, spokeAdmin);
        AaveV4SpokeRolesProcedure.grantSpokeRole(accessManager, Roles.SPOKE_CONFIGURATOR_ROLE, spokeConfigurator);
        AaveV4SpokeConfiguratorRolesProcedure.grantSpokeConfiguratorAllRoles(accessManager, spokeConfiguratorAdmin);
    }

    /// @notice Grants one Hub role, for example `HUB_DEFICIT_ELIMINATOR_ROLE` (103) to a Coverage Spoke.
    function grantHubRole(
        address accessManager,
        uint64 role,
        address account
    ) external {
        AaveV4HubRolesProcedure.grantHubRole(accessManager, role, account);
    }

    /// @notice Hands the AccessManager admin role from the fixture to `adminToAdd`.
    function replaceDefaultAdminRole(
        address accessManager,
        address adminToAdd,
        address adminToRemove
    ) external {
        AaveV4AccessManagerRolesProcedure.replaceDefaultAdminRole(accessManager, adminToAdd, adminToRemove);
    }
}
