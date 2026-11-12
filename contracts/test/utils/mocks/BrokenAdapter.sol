// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title BrokenAdapter
/// @notice An AaveAdapter implementation that reverts on every Adapter call (REQ-ADAPTER-060): only the upgrade path
/// and the roles of the real implementation survive, so the timelock can install a fix.
/// @dev Declares no state: the Adapter's ERC-7201 namespace and the AccessControl slots stay as they were.
contract BrokenAdapter is UUPSUpgradeable, AccessControlUpgradeable {
    error Broken();

    // The test drives every Adapter selector into this fallback.
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        revert Broken();
    }

    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
