// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LPVaultSwap} from "../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title LPVaultSwapKeepersUnitTest
/// @notice The committed-operator registry (2.11 REQ-SWAP-032 to REQ-SWAP-038, REQ-SWAP-065, REQ-SWAP-069,
/// REQ-SWAP-107, REQ-SWAP-117; 2.15 REQ-ACCESS-011, REQ-ACCESS-053, REQ-ACCESS-054, REQ-ACCESS-100, REQ-ACCESS-121,
/// SPEC-GOV-008): `initialize` registers the launch operators; `addKeeper` and `removeKeeper` need `APPLICATION_ADMIN`
/// (the timelock), refuse zero, duplicate, unregistered and frozen addresses, cap the list at `MAX_KEEPERS = 32` and
/// keep at least `KEEPER_FLOOR = 1` active (unfrozen) operator; `activeKeeperCount` excludes frozen operators; the
/// registry gates no liquidation.
/// forge-config: default.isolate = false
contract LPVaultSwapKeepersUnitTest is LPVaultSwapUnitBase {
    function _add(
        address k
    ) internal {
        vm.prank(timelock);
        lvs.addKeeper(k);
    }

    function _remove(
        address k
    ) internal {
        vm.prank(timelock);
        lvs.removeKeeper(k);
    }

    function _keeperN(
        uint256 i
    ) internal pure returns (address) {
        return address(uint160(0x10000 + i));
    }

    /// @notice The launch registry holds Avana's keeper; the constants are 1 and 32.
    // TEST-098 verifies: REQ-SWAP-032, REQ-SWAP-034, REQ-ACCESS-011, INV-048
    function test_TEST_098_launchRegistry() public view {
        assertEq(lvs.KEEPER_FLOOR(), 1, "keeperFloor");
        assertEq(lvs.MAX_KEEPERS(), 32, "MAX_KEEPERS");
        assertEq(lvs.approvedKeeperCount(), 1, "one operator");
        assertEq(lvs.activeKeeperCount(), 1, "active");
        assertTrue(lvs.isApprovedKeeper(keeper), "Avana's keeper");
        address[] memory list = lvs.getKeepers();
        assertEq(list.length, 1, "list");
        assertEq(list[0], keeper, "list[0]");
    }

    /// @notice `addKeeper` by the timelock registers and emits; every other caller reverts
    /// `AccessControlUnauthorizedAccount`, the registered operator included.
    // TEST-045 verifies: REQ-SWAP-033, REQ-SWAP-069, REQ-ACCESS-053, REQ-ACCESS-011
    // TEST-062 verifies: REQ-SWAP-033, REQ-SWAP-069, REQ-ACCESS-053
    function test_TEST_045_addKeeperRoleGuard() public {
        bytes32 role = AvanaRoles.APPLICATION_ADMIN;
        address[3] memory others = [keeper, attacker, aaveDao];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, others[i], role)
            );
            lvs.addKeeper(carol);
        }
        vm.expectEmit(true, false, false, false, address(lvs));
        emit KeeperAdded(carol);
        _add(carol);
        assertTrue(lvs.isApprovedKeeper(carol), "registered");
        assertEq(lvs.approvedKeeperCount(), 2, "two");
        assertEq(lvs.activeKeeperCount(), 2, "two active");
    }

    /// @notice `InvalidKeeper` for zero and for a registered operator; `AddressIsFrozen(operator)` for a frozen one,
    /// checked in that order.
    // TEST-045 verifies: REQ-SWAP-033, REQ-SWAP-107, REQ-SWAP-117, REQ-ACCESS-053
    function test_TEST_045_addKeeperRefusals() public {
        vm.startPrank(timelock);
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidKeeper.selector));
        lvs.addKeeper(address(0));
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidKeeper.selector));
        lvs.addKeeper(keeper);
        vm.stopPrank();
        registry.setFrozen(carol, true);
        registry.setFrozen(keeper, true);
        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.AddressIsFrozen.selector, carol));
        lvs.addKeeper(carol);
        // A registered operator that is frozen still reports InvalidKeeper first.
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidKeeper.selector));
        lvs.addKeeper(keeper);
        vm.stopPrank();
    }

    /// @notice `TooManyKeepers(32)` once 32 operators are registered; at 31 the 32nd is accepted.
    // TEST-098 verifies: REQ-SWAP-033, Q-400
    // TEST-045 verifies: REQ-SWAP-033, REQ-ACCESS-053
    function test_TEST_098_maxKeepers() public {
        for (uint256 i = 0; i < 31; ++i) {
            _add(_keeperN(i));
        }
        assertEq(lvs.approvedKeeperCount(), 32, "32 registered");
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.TooManyKeepers.selector, 32));
        lvs.addKeeper(carol);
        _remove(_keeperN(0));
        _add(carol);
        assertEq(lvs.approvedKeeperCount(), 32, "room after a removal");
    }

    /// @notice `removeKeeper`: role guard, `InvalidKeeper` for an unregistered address, and the floor: with two active
    /// operators one may go and the last may not (`KeeperFloor(0, 1)`).
    // TEST-098 verifies: REQ-SWAP-035, REQ-SWAP-065, REQ-SWAP-107, REQ-ACCESS-100, REQ-ACCESS-121, SPEC-GOV-008, INV-048
    // TEST-045 verifies: REQ-SWAP-035, REQ-ACCESS-054
    // TEST-062 verifies: REQ-SWAP-035, REQ-SWAP-069, REQ-ACCESS-054
    function test_TEST_098_removeKeeperFloor() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, AvanaRoles.APPLICATION_ADMIN
            )
        );
        lvs.removeKeeper(keeper);
        vm.prank(timelock);
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidKeeper.selector));
        lvs.removeKeeper(carol);
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 0, 1));
        lvs.removeKeeper(keeper);
        _add(carol);
        vm.expectEmit(true, false, false, false, address(lvs));
        emit KeeperRemoved(keeper);
        _remove(keeper);
        assertFalse(lvs.isApprovedKeeper(keeper), "removed");
        assertEq(lvs.activeKeeperCount(), 1, "one active");
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 0, 1));
        lvs.removeKeeper(carol);
    }

    /// @notice REQ-SWAP-107: `activeKeeperCount` excludes frozen operators; the floor counts active ones: with one
    /// active and one frozen operator, removing the frozen one keeps the active count (allowed), removing the active one
    /// would leave 0 (refused); a guardian can freeze the last active operator (no floor in the freeze), leaving 0.
    // TEST-098 verifies: REQ-SWAP-034, REQ-SWAP-107, REQ-SWAP-039, REQ-ACCESS-100, SPEC-GOV-008, INV-048, Q-400
    function test_TEST_098_frozenOperatorsAreNotActive() public {
        _add(carol);
        registry.setFrozen(carol, true);
        assertEq(lvs.approvedKeeperCount(), 2, "registered count includes frozen");
        assertEq(lvs.activeKeeperCount(), 1, "active excludes frozen");
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 0, 1));
        lvs.removeKeeper(keeper);
        _remove(carol);
        assertEq(lvs.activeKeeperCount(), 1, "the frozen one removed");
        registry.setFrozen(keeper, true);
        assertEq(lvs.activeKeeperCount(), 0, "0 active: new borrowing halts on the chain");
        // With zero active the last frozen operator cannot be removed either (activeAfter 0 < 1).
        vm.prank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 0, 1));
        lvs.removeKeeper(keeper);
    }

    /// @notice Liquidation never halts on the registry: with zero active operators every caller still liquidates.
    // TEST-098 verifies: REQ-SWAP-034, REQ-SWAP-039, REQ-ACCESS-092, Q-404
    // TEST-045 verifies: REQ-SWAP-001, REQ-SWAP-036, REQ-SWAP-037, REQ-ACCESS-092
    function test_TEST_045_zeroActiveOperatorsLiquidationOpen() public {
        registry.setFrozen(keeper, true);
        assertEq(lvs.activeKeeperCount(), 0, "no active operator");
        (address proxy,) = _bobAccount();
        _liquidateAs(carol, _params(proxy, 1950e6));
        assertLt(_debtOf(proxy, usdcReserveId), 18_000e6, "liquidated");
    }

    /// @notice The enumeration stays consistent through removals from the middle (swap with the last entry).
    // TEST-098 verifies: REQ-SWAP-032, REQ-SWAP-035
    function test_TEST_098_enumerationAfterRemovals() public {
        _add(_keeperN(1));
        _add(_keeperN(2));
        _add(_keeperN(3));
        _remove(_keeperN(1));
        address[] memory list = lvs.getKeepers();
        assertEq(list.length, 3, "three left");
        assertEq(list[0], keeper, "first kept");
        assertEq(list[1], _keeperN(3), "last moved into the gap");
        assertEq(list[2], _keeperN(2), "order");
        _add(_keeperN(1));
        assertTrue(lvs.isApprovedKeeper(_keeperN(1)), "re-added through addKeeper");
    }

    /// @notice `initialize` refuses fewer than `KEEPER_FLOOR` and more than `MAX_KEEPERS` launch operators, zero and
    /// duplicate operators, and a zero timelock; it runs once.
    // TEST-098 verifies: REQ-SWAP-032, REQ-SWAP-034, REQ-SWAP-040
    // TEST-242 verifies: REQ-SWAP-040
    function test_TEST_098_initializeChecks() public {
        address[] memory none = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 0, 1));
        _deployProxy(timelock, none);
        address[] memory many = new address[](33);
        for (uint256 i = 0; i < 33; ++i) {
            many[i] = _keeperN(i);
        }
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.TooManyKeepers.selector, 32));
        _deployProxy(timelock, many);
        address[] memory dup = new address[](2);
        (dup[0], dup[1]) = (carol, carol);
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidKeeper.selector));
        _deployProxy(timelock, dup);
        address[] memory zero = new address[](1);
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidKeeper.selector));
        _deployProxy(timelock, zero);
        address[] memory one = new address[](1);
        one[0] = carol;
        vm.expectRevert(_err(ILPVaultSwapErrors.ZeroAddress.selector));
        _deployProxy(address(0), one);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        LPVaultSwap(address(lvs)).initialize(timelock, one);
    }

    /// @notice Deploys a second proxy over the fixture's implementation (an external call, so `expectRevert` applies).
    function deployProxyExternal(
        address tl,
        address[] memory keepers
    ) external returns (address) {
        return address(new ERC1967Proxy(address(implementation), abi.encodeCall(LPVaultSwap.initialize, (tl, keepers))));
    }

    function _deployProxy(
        address tl,
        address[] memory keepers
    ) internal returns (ILPVaultSwap) {
        return ILPVaultSwap(this.deployProxyExternal(tl, keepers));
    }

    /// @notice Registry changes are invisible to settlement: the same account liquidated before and after a change of
    /// the registry settles identically (REQ-SWAP-001).
    // TEST-045 verifies: REQ-SWAP-001, REQ-SWAP-085, PROP-035
    function test_TEST_045_registryChangesNoSettlement() public {
        (address proxy,) = _bobAccount();
        uint256 snapshot = vm.snapshotState();
        uint256 before = _liquidateAs(carol, _params(proxy, 1950e6)).keeperOut;
        vm.revertToState(snapshot);
        _add(carol);
        _add(attacker);
        uint256 afterChange = _liquidateAs(carol, _params(proxy, 1950e6)).keeperOut;
        assertEq(afterChange, before, "identical settlement");
    }

    /// @notice Fuzzed sequences of add, remove, freeze and unfreeze never leave fewer than `KEEPER_FLOOR` active
    /// operators through `removeKeeper`, never exceed 32, and keep the list and the mapping in step.
    // TEST-098 verifies: REQ-SWAP-033, REQ-SWAP-035, REQ-SWAP-107, REQ-ACCESS-100, SPEC-GOV-008, INV-048
    function testFuzz_TEST_098_floorAndCapUnderSequences(
        uint8[24] memory ops
    ) public {
        for (uint256 i = 0; i < ops.length; ++i) {
            address k = _keeperN(ops[i] % 6);
            uint256 kind = (ops[i] / 6) % 4;
            uint256 activeBefore = lvs.activeKeeperCount();
            vm.prank(timelock);
            if (kind == 0) {
                try lvs.addKeeper(k) {} catch {}
            } else if (kind == 1) {
                try lvs.removeKeeper(k) {
                    assertGe(lvs.activeKeeperCount(), activeBefore >= 1 ? 1 : 0, "floor broken by a removal");
                } catch {}
            } else {
                registry.setFrozen(k, kind == 2);
            }
            address[] memory list = lvs.getKeepers();
            assertLe(list.length, 32, "cap");
            assertEq(list.length, lvs.approvedKeeperCount(), "count");
            for (uint256 j = 0; j < list.length; ++j) {
                assertTrue(lvs.isApprovedKeeper(list[j]), "list entry not registered");
            }
        }
    }
}
