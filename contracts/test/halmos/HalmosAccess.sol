// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/// @title HalmosAccess
/// @notice The AccessManager of a symbolic suite: the caller of `deploy` is its admin, one `governor` account holds the
/// tighten and governance roles with no execution delay, and `bind` maps a target's governed functions (`AvanaAccess`).
library HalmosAccess {
    function deploy(
        address governor
    ) internal returns (AccessManager manager) {
        manager = new AccessManager(address(this));
        manager.grantRole(AvanaRoles.TIGHTEN_ROLE, governor, 0);
        manager.grantRole(AvanaRoles.GOVERNANCE_ROLE, governor, 0);
    }

    function bind(
        AccessManager manager,
        AvanaAccess.Kind kind,
        address target
    ) internal {
        uint64[] memory ids = AvanaAccess.roles();
        for (uint256 i = 0; i < ids.length; ++i) {
            bytes4[] memory selectors = AvanaAccess.selectorsOf(kind, ids[i]);
            if (selectors.length != 0) manager.setTargetFunctionRole(target, selectors, ids[i]);
        }
    }
}
