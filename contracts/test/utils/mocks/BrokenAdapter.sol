// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title BrokenAdapter
/// @notice An AaveAdapter implementation that reverts on every Adapter call (REQ-ADAPTER-060): only the upgrade path
/// and the authority of the real implementation survive, so the governance role can install a fix.
/// @dev Declares no state: the Adapter's ERC-7201 namespace and the AccessManaged slot stay as they were.
contract BrokenAdapter is UUPSUpgradeable, AccessManagedUpgradeable {
    error Broken();

    // The test drives every Adapter selector into this fallback.
    // solhint-disable-next-line no-complex-fallback
    fallback() external {
        revert Broken();
    }

    function _authorizeUpgrade(
        address
    ) internal override restricted {}
}
