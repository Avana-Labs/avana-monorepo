// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AvanaRoles} from "../../src/AvanaRoles.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";

/// @title AvanaRolesUnitTest
/// @notice The role ids Avana adds to its AccessManager: three distinct non-zero ids, none the admin or public role,
/// each with a label, and the delay `AvanaAccess` gives each role (12 hours, 4 to 5 days, 14 days).
/// @dev Role ids part of TEST-062 (role map). Which function takes which role, and who holds it, is tested in
/// `AccessManagerRoles.unit.t.sol` and with each contract that uses the role.
contract AvanaRolesUnitTest is AvanaTest {
    uint64 internal constant PUBLIC_ROLE = type(uint64).max;

    // TEST-062 verifies: REQ-ACCESS-003, REQ-ACCESS-006, REQ-ACCESS-008, REQ-ACCESS-009
    function test_TEST_062_roleIdsAreDistinctAndNotAdminOrPublic() public pure {
        uint64[3] memory ids = [AvanaRoles.TIGHTEN_ROLE, AvanaRoles.GOVERNANCE_ROLE, AvanaRoles.RESERVE_WITHDRAW_ROLE];
        for (uint256 i; i < ids.length; ++i) {
            assertNotEq(ids[i], AvanaRoles.ADMIN_ROLE, "Avana role equals ADMIN_ROLE");
            assertNotEq(ids[i], PUBLIC_ROLE, "Avana role equals PUBLIC_ROLE");
            for (uint256 j = i + 1; j < ids.length; ++j) {
                assertNotEq(ids[i], ids[j], "two roles share an id");
            }
        }
    }

    // TEST-062 verifies: REQ-ACCESS-003
    function test_TEST_062_adminRoleIsTheManagersAdminRole() public view {
        assertEq(AvanaRoles.ADMIN_ROLE, accessManager.ADMIN_ROLE());
    }

    // TEST-062 verifies: REQ-ACCESS-003
    function test_TEST_062_everyRoleHasALabel() public pure {
        uint64[] memory ids = AvanaAccess.roles();
        assertEq(ids.length, 3);
        for (uint256 i; i < ids.length; ++i) {
            assertGt(bytes(AvanaAccess.roleLabel(ids[i])).length, 0, "empty label");
        }
        assertEq(AvanaAccess.roleLabel(AvanaRoles.TIGHTEN_ROLE), "AVANA_TIGHTEN_ROLE");
        assertEq(AvanaAccess.roleLabel(AvanaRoles.GOVERNANCE_ROLE), "AVANA_GOVERNANCE_ROLE");
        assertEq(AvanaAccess.roleLabel(AvanaRoles.RESERVE_WITHDRAW_ROLE), "AVANA_RESERVE_WITHDRAW_ROLE");
    }

    // TEST-062 verifies: REQ-ACCESS-155
    /// @notice The tighten delay is 12 hours and the withdraw delay 14 days; the governance delay is the configured
    /// normal delay when it lies between 4 and 5 days, else 4 days.
    function test_TEST_062_roleDelays() public pure {
        assertEq(AvanaAccess.roleDelay(AvanaRoles.TIGHTEN_ROLE, 0), 12 hours);
        assertEq(AvanaAccess.roleDelay(AvanaRoles.RESERVE_WITHDRAW_ROLE, 0), 14 days);
        assertEq(AvanaAccess.governanceDelay(4 days), 4 days);
        assertEq(AvanaAccess.governanceDelay(5 days), 5 days);
        assertEq(AvanaAccess.governanceDelay(432_000), 432_000);
        assertEq(AvanaAccess.governanceDelay(4 days + 1), 4 days + 1);
        assertEq(AvanaAccess.governanceDelay(4 days - 1), 4 days);
        assertEq(AvanaAccess.governanceDelay(5 days + 1), 4 days);
        assertEq(AvanaAccess.governanceDelay(60), 4 days);
        assertEq(AvanaAccess.governanceDelay(0), 4 days);
    }

    // TEST-062 verifies: REQ-ACCESS-155
    function testFuzz_TEST_062_governanceDelayStaysInRange(
        uint256 normal
    ) public pure {
        uint32 d = AvanaAccess.governanceDelay(normal);
        assertGe(d, 4 days);
        assertLe(d, 5 days);
    }
}
