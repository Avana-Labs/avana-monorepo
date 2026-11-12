// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title LPVaultSwapViewsUnitTest
/// @notice LPVaultSwap's views (2.11 "Interface", REQ-SWAP-032 to REQ-SWAP-038, REQ-SWAP-076, REQ-SWAP-122): the
/// construction bindings, the constants of the spec, the committed-operator list in registration order with
/// swap-and-pop removal, and `activeKeeperCount` as the unfrozen part of the list, read through the proxy.
/// forge-config: default.isolate = false
contract LPVaultSwapViewsUnitTest is LPVaultSwapUnitBase {
    /// @notice The bindings are the construction immutables; the timelock is the initialised one.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-069
    function test_bindings() public view {
        assertEq(lvs.LOCK(), address(lock), "LOCK");
        assertEq(lvs.AAVE_ADAPTER(), address(adapter), "AAVE_ADAPTER");
        assertEq(lvs.COLLATERALIZATION(), address(coll), "COLLATERALIZATION");
        assertEq(lvs.MARKET_REGISTRY(), address(registry), "MARKET_REGISTRY");
        assertEq(lvs.PARAMETER_STORE(), address(store), "PARAMETER_STORE");
        assertEq(lvs.PAYOUT_ESCROW(), address(escrow), "PAYOUT_ESCROW");
        assertEq(lvs.TIMELOCK(), timelock, "TIMELOCK");
    }

    /// @notice The spec's constants: `keeperFloor` 1, `MAX_KEEPERS` 32, `MAX_REPAY_TRANSFERS` 4, the payout transfer's
    /// 100,000 gas, and `APPLICATION_ADMIN` the shared role identifier.
    // TEST-098 verifies: REQ-SWAP-034, REQ-SWAP-076, REQ-SWAP-122
    function test_constants() public view {
        assertEq(lvs.KEEPER_FLOOR(), 1, "keeperFloor");
        assertEq(lvs.MAX_KEEPERS(), 32, "MAX_KEEPERS");
        assertEq(lvs.MAX_REPAY_TRANSFERS(), 4, "MAX_REPAY_TRANSFERS");
        assertEq(lvs.PAYOUT_TRANSFER_GAS(), 100_000, "payout transfer gas");
        assertEq(lvs.APPLICATION_ADMIN(), AvanaRoles.APPLICATION_ADMIN, "APPLICATION_ADMIN");
    }

    /// @notice The list keeps registration order; a removal moves the last entry into the removed slot.
    // TEST-098 verifies: REQ-SWAP-032, REQ-SWAP-035
    function test_listOrderAndSwapAndPop() public {
        address[4] memory k = [makeAddr("k1"), makeAddr("k2"), makeAddr("k3"), makeAddr("k4")];
        for (uint256 i = 0; i < 4; ++i) {
            vm.prank(timelock);
            lvs.addKeeper(k[i]);
        }
        address[] memory list = lvs.getKeepers();
        assertEq(list.length, 5, "the launch keeper plus four");
        assertEq(list[0], keeper, "the launch keeper first");
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(list[i + 1], k[i], "registration order");
        }
        vm.prank(timelock);
        lvs.removeKeeper(k[1]);
        list = lvs.getKeepers();
        assertEq(list.length, 4, "one fewer");
        assertEq(list[2], k[3], "the last entry moved into the removed slot");
        assertEq(list[3], k[2], "the rest unchanged");
        assertFalse(lvs.isApprovedKeeper(k[1]), "removed");
    }

    /// @notice `activeKeeperCount` counts the registered keepers the MarketRegistry has not frozen; `isApprovedKeeper`
    /// and `approvedKeeperCount` ignore the freeze.
    // TEST-098 verifies: REQ-SWAP-034, REQ-SWAP-036, REQ-ACCESS-100
    function testFuzz_activeCountIgnoresFrozen(
        uint8 n,
        uint256 frozenMask
    ) public {
        n = uint8(bound(n, 1, 20));
        uint256 frozen = 0;
        for (uint256 i = 0; i < n; ++i) {
            address k = address(uint160(0xF000 + i));
            vm.prank(timelock);
            lvs.addKeeper(k);
            if ((frozenMask >> i) & 1 == 1) {
                registry.setFrozen(k, true);
                ++frozen;
            }
        }
        assertEq(lvs.approvedKeeperCount(), uint256(n) + 1, "registered count ignores freezes");
        assertEq(lvs.activeKeeperCount(), uint256(n) + 1 - frozen, "active count excludes the frozen");
        for (uint256 i = 0; i < n; ++i) {
            assertTrue(lvs.isApprovedKeeper(address(uint160(0xF000 + i))), "a frozen keeper stays registered");
        }
    }

    /// @notice Removing a frozen keeper leaves the active count unchanged, so it is allowed even at the floor.
    // TEST-098 verifies: REQ-SWAP-035, REQ-ACCESS-121, SPEC-GOV-008
    function test_removeFrozenAtTheFloor() public {
        address k = makeAddr("frozenKeeper");
        vm.prank(timelock);
        lvs.addKeeper(k);
        registry.setFrozen(k, true);
        assertEq(lvs.activeKeeperCount(), 1, "only the launch keeper is active");
        vm.prank(timelock);
        lvs.removeKeeper(k);
        assertEq(lvs.activeKeeperCount(), 1, "unchanged");
        assertEq(lvs.approvedKeeperCount(), 1, "one left");
    }

    /// @notice The cap is exactly 32: the 32nd registration succeeds, the 33rd reverts `TooManyKeepers(32)`; a removal
    /// makes room again.
    // TEST-098 verifies: REQ-SWAP-033, REQ-ACCESS-053
    function test_capIsExactly32() public {
        for (uint256 i = 0; i < 31; ++i) {
            vm.prank(timelock);
            lvs.addKeeper(address(uint160(0xA100 + i)));
        }
        assertEq(lvs.approvedKeeperCount(), 32, "32 registered");
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.TooManyKeepers.selector, 32));
        lvs.addKeeper(makeAddr("thirtyThird"));
        vm.prank(timelock);
        lvs.removeKeeper(address(uint160(0xA100)));
        vm.prank(timelock);
        lvs.addKeeper(makeAddr("thirtyThird"));
        assertEq(lvs.approvedKeeperCount(), 32, "room again after a removal");
    }

    /// @notice `addKeeper(0)`, a second `addKeeper` of the same address and `removeKeeper` of an unregistered address
    /// revert `InvalidKeeper`; each success emits its event.
    // TEST-098 verifies: REQ-SWAP-033, REQ-SWAP-035, REQ-ACCESS-053, REQ-ACCESS-054
    function test_invalidKeeperAndEvents() public {
        address k = makeAddr("newKeeper");
        vm.prank(timelock);
        vm.expectRevert(ILPVaultSwapErrors.InvalidKeeper.selector);
        lvs.addKeeper(address(0));
        vm.expectEmit(address(lvs));
        emit KeeperAdded(k);
        vm.prank(timelock);
        lvs.addKeeper(k);
        vm.prank(timelock);
        vm.expectRevert(ILPVaultSwapErrors.InvalidKeeper.selector);
        lvs.addKeeper(k);
        vm.prank(timelock);
        vm.expectRevert(ILPVaultSwapErrors.InvalidKeeper.selector);
        lvs.removeKeeper(makeAddr("stranger"));
        vm.expectEmit(address(lvs));
        emit KeeperRemoved(k);
        vm.prank(timelock);
        lvs.removeKeeper(k);
    }

    /// @notice Any account without `APPLICATION_ADMIN` is refused both registry calls with the missing role.
    // TEST-062 verifies: REQ-SWAP-033, REQ-SWAP-035, REQ-ACCESS-053, REQ-ACCESS-054
    function testFuzz_registryNeedsApplicationAdmin(
        address caller
    ) public {
        vm.assume(caller != timelock);
        bytes memory err = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, caller, AvanaRoles.APPLICATION_ADMIN
        );
        vm.prank(caller);
        vm.expectRevert(err);
        lvs.addKeeper(makeAddr("k"));
        vm.prank(caller);
        vm.expectRevert(err);
        lvs.removeKeeper(keeper);
    }

    /// @notice Registration is the only way onto the list: any other address reads as not approved, and a frozen
    /// stranger changes no count.
    // TEST-098 verifies: REQ-SWAP-032, REQ-SWAP-036
    function testFuzz_strangersNeverApproved(
        address stranger,
        bool frozen
    ) public {
        vm.assume(stranger != keeper);
        registry.setFrozen(stranger, frozen);
        assertFalse(lvs.isApprovedKeeper(stranger), "not approved");
        assertEq(lvs.approvedKeeperCount(), 1, "count unchanged");
        assertEq(lvs.activeKeeperCount(), 1, "active count unchanged");
        address[] memory list = lvs.getKeepers();
        assertEq(list.length, 1, "list unchanged");
        assertEq(list[0], keeper, "only the launch keeper");
    }
}

