// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title AvanaRoles
/// @notice Role ids Avana adds to its OpenZeppelin `AccessManager`, each with the label the manager records.
/// @dev Each chain has its own AccessManager; no role reaches across chains. `ADMIN_ROLE` (0) is the manager's own
/// admin role, held by the DAO. The execution delay of each role is set per holder with `grantRole` (see
/// `script/deploy/lib/AvanaAccess.sol`, which also maps every governed function to its role).
library AvanaRoles {
    /// @notice The AccessManager's admin role (`AccessManager.ADMIN_ROLE`), held by the DAO.
    uint64 internal constant ADMIN_ROLE = 0;

    /// @notice Setters that only make a value safer, and the fast removals and cancellations; executes 12 hours
    /// after scheduling. The risk steward holds it with no delay.
    uint64 internal constant TIGHTEN_ROLE = 1;

    /// @notice Every other governed setter, listing, registration and upgrade; executes after the governance delay
    /// (4 to 5 days).
    uint64 internal constant GOVERNANCE_ROLE = 2;

    /// @notice First-Loss Reserve `withdraw`; executes 14 days after scheduling.
    uint64 internal constant RESERVE_WITHDRAW_ROLE = 3;

    /// @notice Label of `TIGHTEN_ROLE`.
    string internal constant TIGHTEN_LABEL = "AVANA_TIGHTEN_ROLE";

    /// @notice Label of `GOVERNANCE_ROLE`.
    string internal constant GOVERNANCE_LABEL = "AVANA_GOVERNANCE_ROLE";

    /// @notice Label of `RESERVE_WITHDRAW_ROLE`.
    string internal constant RESERVE_WITHDRAW_LABEL = "AVANA_RESERVE_WITHDRAW_ROLE";
}
