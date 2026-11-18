// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashReceiver} from "../../src/flash/IFlashReceiver.sol";
import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapBase} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapBase.sol";
import {LPVaultSwap} from "../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {LPVaultSwapImmutables, LPVaultSwapLogics} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title LPVaultSwapAdminFuzzTest
/// @notice Construction, initialisation, roles, upgrades and the delegation guard fuzzed (2.11 REQ-SWAP-032,
/// REQ-SWAP-034, REQ-SWAP-040, REQ-SWAP-069; 2.15 REQ-ACCESS-153): any keeper floor, any initial keeper list size, any
/// account and role, any calldata sent straight to a logic contract, and upgrades after any registry history.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapAdminFuzzTest is LPVaultSwapUnitBase {
    function _logics() internal view returns (LPVaultSwapLogics memory) {
        return LPVaultSwapLogics(liquidationLogic, pendingLogic, deleverageLogic);
    }

    function deployImplementation(
        LPVaultSwapImmutables memory im,
        LPVaultSwapLogics memory logics
    ) external returns (LPVaultSwap) {
        return new LPVaultSwap(im, logics);
    }

    function deployProxy(
        address implementation,
        address authority_,
        address[] memory keepers
    ) external returns (address) {
        return address(new ERC1967Proxy(implementation, abi.encodeCall(LPVaultSwap.initialize, (authority_, keepers))));
    }

    /// @notice A keeper floor in [1, 32] constructs; 0 or above 32 reverts `KeeperFloor(floor, 32)`. The logic
    /// contracts must carry the same immutables, so a floor other than the fixture's is refused `InvalidLogic`.
    // TEST-242 verifies: REQ-SWAP-034, REQ-SWAP-040
    function testFuzz_TEST_242_keeperFloorBounds(
        uint256 floor
    ) public {
        floor = bound(floor, 0, 100);
        LPVaultSwapImmutables memory im = immutables();
        im.keeperFloor = floor;
        if (floor == 0 || floor > 32) {
            vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapBase.KeeperFloor.selector, floor, 32));
        } else if (floor != immutables().keeperFloor) {
            vm.expectRevert(ILPVaultSwapBase.InvalidLogic.selector);
        }
        this.deployImplementation(im, _logics());
    }

    /// @notice An initial list of `n` distinct keepers initialises exactly when `keeperFloor ≤ n ≤ 32`, else
    /// `KeeperFloor(n, floor)` or `TooManyKeepers(32)`; the AccessManager is the authority.
    // TEST-242 verifies: REQ-SWAP-032, REQ-SWAP-034, REQ-SWAP-040, REQ-ACCESS-153
    function testFuzz_TEST_242_initialKeeperList(
        uint256 n,
        address authority_
    ) public {
        n = bound(n, 0, 40);
        vm.assume(authority_ != address(0));
        address[] memory keepers = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            keepers[i] = address(uint160(0xD000 + i));
        }
        address implementation = address(implementation);
        if (n > 32) {
            vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapBase.TooManyKeepers.selector, 32));
            this.deployProxy(implementation, authority_, keepers);
        } else if (n < 1) {
            vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapBase.KeeperFloor.selector, n, 1));
            this.deployProxy(implementation, authority_, keepers);
        } else {
            ILPVaultSwap p = ILPVaultSwap(this.deployProxy(implementation, authority_, keepers));
            assertEq(p.approvedKeeperCount(), n, "all registered");
            assertEq(IAccessManaged(address(p)).authority(), authority_, "authority");
        }
    }

    /// @notice A duplicate or zero entry in the initial list reverts `InvalidKeeper`.
    // TEST-242 verifies: REQ-SWAP-032, REQ-SWAP-033
    function testFuzz_TEST_242_initialListDuplicates(
        uint8 dup
    ) public {
        address[] memory keepers = new address[](3);
        (keepers[0], keepers[1], keepers[2]) = (address(0xD001), address(0xD002), address(0xD003));
        if (dup % 2 == 0) keepers[2] = keepers[dup % 2];
        else keepers[1] = address(0);
        vm.expectRevert(ILPVaultSwapBase.InvalidKeeper.selector);
        this.deployProxy(address(implementation), address(accessManager), keepers);
    }

    /// @notice An account with no role on the AccessManager is refused `addKeeper`, `removeKeeper` and an upgrade.
    // TEST-062 verifies: REQ-SWAP-040, REQ-ACCESS-153, INV-084
    function testFuzz_TEST_062_registryAndUpgradeNeedARole(
        address account
    ) public {
        vm.assume(account != governor && account != governanceMultisig);
        bytes memory err = abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, account);
        vm.startPrank(account);
        vm.expectRevert(err);
        lvs.addKeeper(account);
        vm.expectRevert(err);
        lvs.removeKeeper(keeper);
        vm.expectRevert(err);
        UUPSUpgradeable(address(lvs)).upgradeToAndCall(address(implementation), "");
        vm.stopPrank();
    }

    /// @notice Any calldata sent straight to a logic contract (not through the proxy) reverts `NotDelegated` for
    /// the four delegated entry points.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-069
    function testFuzz_TEST_242_logicBodiesNeedTheProxy(
        uint8 which,
        bytes memory tail
    ) public {
        bytes4[4] memory selectors = [
            ILPVaultSwap.liquidate.selector,
            ILPVaultSwap.settlePending.selector,
            ILPVaultSwap.deleverage.selector,
            IFlashReceiver.onFlashLoan.selector
        ];
        address[4] memory targets = [liquidationLogic, pendingLogic, deleverageLogic, deleverageLogic];
        uint256 i = which % 4;
        (bool ok, bytes memory ret) = targets[i].call(abi.encodePacked(selectors[i], tail));
        assertFalse(ok, "a logic contract never runs on its own address");
        if (ret.length >= 4) assertEq(bytes4(ret), ILPVaultSwapBase.NotDelegated.selector, "NotDelegated");
    }

    /// @notice After any number of keeper additions, an upgrade by the governance role keeps the proxy address, the
    /// registry and the authority; an upgrade by anyone else reverts `AccessManagedUnauthorized`.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-069, REQ-ACCESS-153
    function testFuzz_TEST_242_upgradeKeepsRegistry(
        uint8 adds,
        address outsider
    ) public {
        vm.assume(outsider != governor && outsider != governanceMultisig);
        uint256 n = bound(adds, 0, 10);
        for (uint256 i = 0; i < n; ++i) {
            vm.prank(governor);
            lvs.addKeeper(address(uint160(0xE000 + i)));
        }
        address[] memory before = lvs.getKeepers();
        LPVaultSwap next = new LPVaultSwap(immutables(), _logics());
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider));
        UUPSUpgradeable(address(lvs)).upgradeToAndCall(address(next), "");
        vm.prank(governor);
        UUPSUpgradeable(address(lvs)).upgradeToAndCall(address(next), "");
        address[] memory afterList = lvs.getKeepers();
        assertEq(afterList.length, before.length, "same registry size");
        for (uint256 i = 0; i < before.length; ++i) {
            assertEq(afterList[i], before[i], "same registry order");
        }
        assertEq(lvs.authority(), address(accessManager), "authority kept");
    }
}
