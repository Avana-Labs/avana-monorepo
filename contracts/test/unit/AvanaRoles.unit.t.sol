// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title AvanaRolesUnitTest
/// @notice The role identifiers Avana adds to OpenZeppelin `AccessControl` and `TimelockController`: each is the
/// keccak256 of its own name, none is `DEFAULT_ADMIN_ROLE`, and together with the three `TimelockController` roles
/// they are seven distinct identifiers, so a grant of one role never authorizes a holder of another.
/// @dev Role identifiers part of TEST-062 (role map). Which contract checks which role, and who holds it, is tested
/// with each contract that uses the role.
contract AvanaRolesUnitTest is AvanaTest {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // TEST-062 verifies: REQ-ACCESS-003, REQ-ACCESS-006, REQ-ACCESS-008, REQ-ACCESS-009
    // Sources: 5.1 TEST-062 (role identifiers only), 1.4 role table rows of the four Avana roles
    function test_TEST_062_roleIdsAreNameHashes() public pure {
        assertEq(AvanaRoles.APPLICATION_ADMIN, keccak256("APPLICATION_ADMIN"));
        assertEq(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, keccak256("APPLICATION_PAUSE_GUARDIAN"));
        assertEq(AvanaRoles.APPLICATION_FREEZE_GUARDIAN, keccak256("APPLICATION_FREEZE_GUARDIAN"));
        assertEq(AvanaRoles.DAO_CANCELLER_ROLE, keccak256("DAO_CANCELLER_ROLE"));
    }

    // TEST-062 verifies: REQ-ACCESS-003, REQ-ACCESS-006, REQ-ACCESS-008, REQ-ACCESS-009
    function test_TEST_062_noAvanaRoleIsDefaultAdmin() public pure {
        bytes32[7] memory ids = _roles();
        for (uint256 i; i < 4; ++i) {
            assertNotEq(ids[i], DEFAULT_ADMIN_ROLE, "Avana role equals DEFAULT_ADMIN_ROLE");
        }
    }

    // TEST-062 verifies: REQ-ACCESS-003, REQ-ACCESS-006, REQ-ACCESS-008, REQ-ACCESS-009
    function test_TEST_062_avanaAndTimelockRolesAreDistinct() public pure {
        bytes32[7] memory ids = _roles();
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j = i + 1; j < ids.length; ++j) {
                assertNotEq(ids[i], ids[j], "two roles share an identifier");
            }
        }
    }

    // TEST-062 verifies: REQ-ACCESS-003, REQ-ACCESS-006, REQ-ACCESS-008, REQ-ACCESS-009
    /// @notice The `TimelockController` roles Avana uses are OpenZeppelin 5.1.0's, unchanged.
    function test_TEST_062_timelockRolesAreOpenZeppelins() public pure {
        assertEq(_proposer(), keccak256("PROPOSER_ROLE"));
        assertEq(_executor(), keccak256("EXECUTOR_ROLE"));
        assertEq(_canceller(), keccak256("CANCELLER_ROLE"));
    }

    // TEST-062 verifies: REQ-ACCESS-003, REQ-ACCESS-006, REQ-ACCESS-008, REQ-ACCESS-009
    function testFuzz_TEST_062_rolePairEqualExactlyWhenSameIndex(
        uint8 i,
        uint8 j
    ) public pure {
        bytes32[7] memory ids = _roles();
        uint256 a = uint256(i) % ids.length;
        uint256 b = uint256(j) % ids.length;
        assertEq(ids[a] == ids[b], a == b);
    }

    function _roles() internal pure returns (bytes32[7] memory ids) {
        ids[0] = AvanaRoles.APPLICATION_ADMIN;
        ids[1] = AvanaRoles.APPLICATION_PAUSE_GUARDIAN;
        ids[2] = AvanaRoles.APPLICATION_FREEZE_GUARDIAN;
        ids[3] = AvanaRoles.DAO_CANCELLER_ROLE;
        ids[4] = _proposer();
        ids[5] = _executor();
        ids[6] = _canceller();
    }

    // TimelockController exposes its role identifiers only as constants of a deployed contract; these are their values,
    // checked against a deployed OpenZeppelin 5.1.0 TimelockController in test_TEST_062_timelockRolesMatchDeployed.
    function _proposer() internal pure returns (bytes32) {
        return keccak256("PROPOSER_ROLE");
    }

    function _executor() internal pure returns (bytes32) {
        return keccak256("EXECUTOR_ROLE");
    }

    function _canceller() internal pure returns (bytes32) {
        return keccak256("CANCELLER_ROLE");
    }

    // TEST-062 verifies: REQ-ACCESS-003, REQ-ACCESS-006, REQ-ACCESS-008, REQ-ACCESS-009
    function test_TEST_062_timelockRolesMatchDeployed() public {
        address[] memory none = new address[](0);
        TimelockController timelock = new TimelockController(SHORT_DELAY, none, none, address(0));
        assertEq(timelock.PROPOSER_ROLE(), _proposer());
        assertEq(timelock.EXECUTOR_ROLE(), _executor());
        assertEq(timelock.CANCELLER_ROLE(), _canceller());
        assertEq(timelock.DEFAULT_ADMIN_ROLE(), DEFAULT_ADMIN_ROLE);
    }
}
