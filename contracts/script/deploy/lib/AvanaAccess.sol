// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";

/// @title AvanaAccess
/// @notice Avana's AccessManager roles, their labels and the execution delay of each role.
/// @dev Shared by the deploy scripts and the tests. The tighten role carries 12 hours, the governance role 4 to 5 days
/// and First-Loss Reserve `withdraw` 14 days. The DAO, the manager's admin, is the guardian of every role and can
/// cancel any scheduled operation. The map of governed functions to roles is rebuilt with the deploy scripts.
library AvanaAccess {
    /// @notice Execution delay of the tighten role for the governance Safe: 12 hours.
    uint32 internal constant TIGHTEN_DELAY = 12 hours;

    /// @notice Lowest governance delay: 4 days.
    uint32 internal constant GOVERNANCE_DELAY_MIN = 4 days;

    /// @notice Highest governance delay: 5 days.
    uint32 internal constant GOVERNANCE_DELAY_MAX = 5 days;

    /// @notice Execution delay of the First-Loss Reserve withdraw role: 14 days.
    uint32 internal constant RESERVE_WITHDRAW_DELAY = 14 days;

    /// @notice The governance delay: `normalDelay` (the config's `timelockNormalDelay`) when it lies between 4 and 5
    /// days, else 4 days.
    function governanceDelay(
        uint256 normalDelay
    ) internal pure returns (uint32) {
        if (normalDelay < GOVERNANCE_DELAY_MIN || normalDelay > GOVERNANCE_DELAY_MAX) return GOVERNANCE_DELAY_MIN;
        // Bounded by `GOVERNANCE_DELAY_MAX`.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(normalDelay);
    }

    /// @notice The execution delay a role carries for the governance Safe.
    function roleDelay(
        uint64 role,
        uint256 normalDelay
    ) internal pure returns (uint32) {
        if (role == AvanaRoles.TIGHTEN_ROLE) return TIGHTEN_DELAY;
        if (role == AvanaRoles.GOVERNANCE_ROLE) return governanceDelay(normalDelay);
        if (role == AvanaRoles.RESERVE_WITHDRAW_ROLE) return RESERVE_WITHDRAW_DELAY;
        revert("AvanaAccess: unknown role");
    }

    /// @notice The label of a role.
    function roleLabel(
        uint64 role
    ) internal pure returns (string memory) {
        if (role == AvanaRoles.TIGHTEN_ROLE) return AvanaRoles.TIGHTEN_LABEL;
        if (role == AvanaRoles.GOVERNANCE_ROLE) return AvanaRoles.GOVERNANCE_LABEL;
        if (role == AvanaRoles.RESERVE_WITHDRAW_ROLE) return AvanaRoles.RESERVE_WITHDRAW_LABEL;
        revert("AvanaAccess: unknown role");
    }

    /// @notice The roles Avana adds to the manager, in id order.
    function roles() internal pure returns (uint64[] memory ids) {
        ids = new uint64[](3);
        ids[0] = AvanaRoles.TIGHTEN_ROLE;
        ids[1] = AvanaRoles.GOVERNANCE_ROLE;
        ids[2] = AvanaRoles.RESERVE_WITHDRAW_ROLE;
    }
}
