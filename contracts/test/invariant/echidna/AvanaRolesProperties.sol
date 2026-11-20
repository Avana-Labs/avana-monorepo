// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";

/// @title AvanaRolesProperties
/// @notice Echidna and Medusa properties of the role ids in `AvanaRoles`. The three Avana roles are three distinct,
/// non-zero ids and none is the AccessManager's `ADMIN_ROLE` (0) or `PUBLIC_ROLE` (`type(uint64).max`), so a grant of one
/// role can never authorize a holder of another.
/// @dev `property_` functions run in property mode; `checkRolePair` runs in assertion mode, where the fuzzer and the
/// symbolic engines (hevm, Mythril) search every index pair for a failing `assert`.
contract AvanaRolesProperties {
    uint256 internal constant ROLE_COUNT = 3;

    /// @notice Number of role pairs checked in assertion mode; written so the call is a transaction.
    uint256 public pairsChecked;

    function property_adminRoleIsZero() external pure returns (bool) {
        return AvanaRoles.ADMIN_ROLE == 0;
    }

    function property_noRoleIsAdminOrPublic() external pure returns (bool) {
        for (uint256 i; i < ROLE_COUNT; ++i) {
            uint64 id = _role(i);
            if (id == AvanaRoles.ADMIN_ROLE || id == type(uint64).max) return false;
        }
        return true;
    }

    function property_roleIdsPairwiseDistinct() external pure returns (bool) {
        for (uint256 i; i < ROLE_COUNT; ++i) {
            for (uint256 j = i + 1; j < ROLE_COUNT; ++j) {
                if (_role(i) == _role(j)) return false;
            }
        }
        return true;
    }

    /// @notice For any two role indexes, the ids are equal exactly when the indexes are.
    function checkRolePair(
        uint8 i,
        uint8 j
    ) external {
        uint256 a = uint256(i) % ROLE_COUNT;
        uint256 b = uint256(j) % ROLE_COUNT;
        assert((_role(a) == _role(b)) == (a == b));
        ++pairsChecked;
    }

    /// @dev Branches instead of an array lookup, so a symbolic index splits into one concrete path per role.
    function _role(
        uint256 k
    ) internal pure returns (uint64) {
        if (k == 0) return AvanaRoles.TIGHTEN_ROLE;
        if (k == 1) return AvanaRoles.GOVERNANCE_ROLE;
        return AvanaRoles.RESERVE_WITHDRAW_ROLE;
    }
}
