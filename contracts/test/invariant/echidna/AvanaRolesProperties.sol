// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";

/// @title AvanaRolesProperties
/// @notice Echidna and Medusa properties of the role identifiers in `AvanaRoles`. Each Avana role is the keccak256 of
/// its own name, none equals `DEFAULT_ADMIN_ROLE` (`0x00`), and the four Avana roles and the three OpenZeppelin
/// `TimelockController` roles held on the AvanaTimelock (`PROPOSER_ROLE`, `EXECUTOR_ROLE`, `CANCELLER_ROLE`) are seven
/// distinct identifiers, so a grant of one role can never authorize a holder of another.
/// @dev `property_` functions run in property mode; `checkRolePair` runs in assertion mode, where the fuzzer and the
/// symbolic engines (hevm, Mythril) search every index pair for a failing `assert`.
contract AvanaRolesProperties {
    uint256 internal constant AVANA_ROLE_COUNT = 4;
    uint256 internal constant ROLE_COUNT = 7;

    /// @notice Number of role pairs checked in assertion mode; written so the call is a transaction.
    uint256 public pairsChecked;

    function property_roleIdsAreNameHashes() external pure returns (bool) {
        return AvanaRoles.APPLICATION_ADMIN == keccak256("APPLICATION_ADMIN")
            && AvanaRoles.APPLICATION_PAUSE_GUARDIAN == keccak256("APPLICATION_PAUSE_GUARDIAN")
            && AvanaRoles.APPLICATION_FREEZE_GUARDIAN == keccak256("APPLICATION_FREEZE_GUARDIAN")
            && AvanaRoles.DAO_CANCELLER_ROLE == keccak256("DAO_CANCELLER_ROLE");
    }

    function property_noRoleIsDefaultAdmin() external pure returns (bool) {
        bytes32[ROLE_COUNT] memory ids = _roles();
        for (uint256 i; i < AVANA_ROLE_COUNT; ++i) {
            if (ids[i] == bytes32(0)) return false;
        }
        return true;
    }

    function property_roleIdsPairwiseDistinct() external pure returns (bool) {
        bytes32[ROLE_COUNT] memory ids = _roles();
        for (uint256 i; i < ROLE_COUNT; ++i) {
            for (uint256 j = i + 1; j < ROLE_COUNT; ++j) {
                if (ids[i] == ids[j]) return false;
            }
        }
        return true;
    }

    /// @notice For any two role indexes, the identifiers are equal exactly when the indexes are, and an Avana role is
    /// never the zero identifier.
    function checkRolePair(
        uint8 i,
        uint8 j
    ) external {
        uint256 a = uint256(i) % ROLE_COUNT;
        uint256 b = uint256(j) % ROLE_COUNT;
        bytes32 roleA = _role(a);
        assert((roleA == _role(b)) == (a == b));
        if (a < AVANA_ROLE_COUNT) assert(roleA != bytes32(0));
        ++pairsChecked;
    }

    function _roles() internal pure returns (bytes32[ROLE_COUNT] memory ids) {
        for (uint256 k; k < ROLE_COUNT; ++k) {
            ids[k] = _role(k);
        }
    }

    /// @dev Branches instead of an array lookup, so a symbolic index splits into one concrete path per role.
    function _role(
        uint256 k
    ) internal pure returns (bytes32) {
        if (k == 0) return AvanaRoles.APPLICATION_ADMIN;
        if (k == 1) return AvanaRoles.APPLICATION_PAUSE_GUARDIAN;
        if (k == 2) return AvanaRoles.APPLICATION_FREEZE_GUARDIAN;
        if (k == 3) return AvanaRoles.DAO_CANCELLER_ROLE;
        // OpenZeppelin 5.1 `TimelockController` defines each of its roles as the keccak256 of the role's name.
        if (k == 4) return keccak256("PROPOSER_ROLE");
        if (k == 5) return keccak256("EXECUTOR_ROLE");
        return keccak256("CANCELLER_ROLE");
    }
}
