// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLogic} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLogic.sol";
import {LPVaultSwap} from "../../src/liquidation/lp-vault-swap/LPVaultSwap.sol";
import {DeleverageRequest} from "../../src/liquidation/lp-vault-swap/types/DeleverageRequest.sol";
import {LPVaultSwapImmutables} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapLogics.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @notice A logic stand-in that reports a chosen kind and immutables hash.
contract LVSFakeLogic is ILPVaultSwapLogic {
    bytes32 internal immutable _KIND;
    bytes32 internal immutable _HASH;

    constructor(
        bytes32 kind,
        bytes32 hash
    ) {
        (_KIND, _HASH) = (kind, hash);
    }

    function logicConfig() external view returns (bytes32, bytes32) {
        return (_KIND, _HASH);
    }
}

/// @title LPVaultSwapAdminUnitTest
/// @notice Construction, roles and upgrades of LPVaultSwap (2.11 REQ-SWAP-040, REQ-SWAP-069; 2.15 REQ-ACCESS-153): the
/// implementation refuses zero addresses, an out-of-range keeper floor and any logic contract of another kind or other
/// immutables; it disables its own initializers; every body reached other than through the proxy reverts
/// `NotDelegated`; `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` can be held only by the timelock; upgrades need
/// `APPLICATION_ADMIN` and keep the registry and the carry; the selector inventory has no rescue, sweep, arbitrary call
/// or second liquidation entry point; the views return the construction values.
/// forge-config: default.isolate = false
contract LPVaultSwapAdminUnitTest is LPVaultSwapUnitBase {
    function _logics() internal view returns (LPVaultSwapLogics memory) {
        return LPVaultSwapLogics(liquidationLogic, pendingLogic, deleverageLogic);
    }

    /// @notice Deploys an implementation through an external call, so `expectRevert` applies to it.
    function deployImplementation(
        LPVaultSwapImmutables memory im,
        LPVaultSwapLogics memory logics
    ) external returns (LPVaultSwap) {
        return new LPVaultSwap(im, logics);
    }

    /// @notice The implementation's constructor refuses a zero address in any immutable and a keeper floor of 0 or
    /// above 32.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-034
    function test_TEST_242_constructorRefusesZeroAndFloor() public {
        for (uint256 i = 0; i < 6; ++i) {
            LPVaultSwapImmutables memory im = immutables();
            if (i == 0) im.lock = address(0);
            if (i == 1) im.aaveAdapter = address(0);
            if (i == 2) im.collateralization = address(0);
            if (i == 3) im.marketRegistry = address(0);
            if (i == 4) im.parameterStore = address(0);
            if (i == 5) im.payoutEscrow = address(0);
            vm.expectRevert(_err(ILPVaultSwapErrors.ZeroAddress.selector));
            this.deployImplementation(im, _logics());
        }
        LPVaultSwapImmutables memory bad = immutables();
        bad.keeperFloor = 0;
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 0, 32));
        this.deployImplementation(bad, _logics());
        bad.keeperFloor = 33;
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.KeeperFloor.selector, 33, 32));
        this.deployImplementation(bad, _logics());
    }

    /// @notice A logic contract of another kind, built with other immutables, swapped between slots or zero is refused.
    // TEST-242 verifies: REQ-SWAP-040
    function test_TEST_242_constructorChecksLogics() public {
        bytes32 hash = keccak256(abi.encode(immutables()));
        LPVaultSwapLogics memory l = _logics();
        l.liquidation = pendingLogic;
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidLogic.selector));
        this.deployImplementation(immutables(), l);
        l = _logics();
        l.pending = address(new LVSFakeLogic(keccak256("LPVaultSwapPendingLogic"), keccak256("other")));
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidLogic.selector));
        this.deployImplementation(immutables(), l);
        l = _logics();
        l.deleverage = address(new LVSFakeLogic(keccak256("LPVaultSwapLiquidationLogic"), hash));
        vm.expectRevert(_err(ILPVaultSwapErrors.InvalidLogic.selector));
        this.deployImplementation(immutables(), l);
        l = _logics();
        l.deleverage = address(0);
        vm.expectRevert(_err(ILPVaultSwapErrors.ZeroAddress.selector));
        this.deployImplementation(immutables(), l);
        l.deleverage = address(new LVSFakeLogic(keccak256("LPVaultSwapDeleverageLogic"), hash));
        this.deployImplementation(immutables(), l);
        (bytes32 kind, bytes32 h) = ILPVaultSwapLogic(liquidationLogic).logicConfig();
        assertEq(kind, keccak256("LPVaultSwapLiquidationLogic"), "kind");
        assertEq(h, hash, "immutables hash");
    }

    /// @notice The implementation's initializers are disabled and every entry point on the implementation or a logic
    /// contract reverts `NotDelegated`.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-043
    function test_TEST_242_bodiesRunOnlyThroughTheProxy() public {
        address[] memory one = new address[](1);
        one[0] = keeper;
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        implementation.initialize(timelock, one);
        bytes memory notDelegated = _err(ILPVaultSwapErrors.NotDelegated.selector);
        address[4] memory targets = [address(implementation), liquidationLogic, pendingLogic, deleverageLogic];
        DeleverageRequest memory r;
        for (uint256 i = 0; i < targets.length; ++i) {
            if (i != 2 && i != 3) {
                vm.expectRevert(notDelegated);
                LPVaultSwap(targets[i]).liquidate(_params(address(1), 1));
            }
            if (i == 0 || i == 2) {
                vm.expectRevert(notDelegated);
                LPVaultSwap(targets[i]).settlePending(MARKET_ID, usdcReserveId);
            }
            if (i == 0 || i == 3) {
                vm.prank(address(adapter));
                vm.expectRevert(notDelegated);
                LPVaultSwap(targets[i]).deleverage(r);
                vm.expectRevert(notDelegated);
                LPVaultSwap(targets[i]).onFlashLoan(address(usdc), 1, 0, "");
            }
        }
    }

    /// @notice REQ-ACCESS-153: `grantRole` of either admin role to anyone but the timelock reverts
    /// `AdminRoleOnlyTimelock(role, account)`; other roles follow AccessControl; the timelock holds both admin roles.
    // TEST-242 verifies: REQ-SWAP-040, REQ-ACCESS-153, PROP-070, Q-259
    // TEST-062 verifies: REQ-SWAP-040, REQ-ACCESS-153
    function test_TEST_242_adminRolesOnlyTimelock() public {
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        bytes32 root = 0x00;
        assertTrue(IAccessControl(address(lvs)).hasRole(admin, timelock), "APPLICATION_ADMIN");
        assertTrue(IAccessControl(address(lvs)).hasRole(root, timelock), "DEFAULT_ADMIN_ROLE");
        assertEq(lvs.TIMELOCK(), timelock, "TIMELOCK");
        assertEq(lvs.APPLICATION_ADMIN(), admin, "role id");
        vm.startPrank(timelock);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.AdminRoleOnlyTimelock.selector, admin, carol));
        IAccessControl(address(lvs)).grantRole(admin, carol);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.AdminRoleOnlyTimelock.selector, root, carol));
        IAccessControl(address(lvs)).grantRole(root, carol);
        bytes32 other = keccak256("SOME_ROLE");
        IAccessControl(address(lvs)).grantRole(other, carol);
        vm.stopPrank();
        assertTrue(IAccessControl(address(lvs)).hasRole(other, carol), "other roles grantable");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, carol, root));
        IAccessControl(address(lvs)).grantRole(admin, carol);
    }

    /// @notice `upgradeToAndCall` needs `APPLICATION_ADMIN`; the timelock's upgrade keeps the address, the registry and
    /// the carry.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-069
    // TEST-062 verifies: REQ-SWAP-040, REQ-SWAP-069
    function test_TEST_242_upgradeNeedsApplicationAdmin() public {
        LPVaultSwap next = new LPVaultSwap(immutables(), _logics());
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, AvanaRoles.APPLICATION_ADMIN
            )
        );
        UUPSUpgradeable(address(lvs)).upgradeToAndCall(address(next), "");
        vm.prank(timelock);
        lvs.addKeeper(carol);
        vm.prank(timelock);
        UUPSUpgradeable(address(lvs)).upgradeToAndCall(address(next), "");
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(address(lvs), implSlot)))), address(next), "implementation");
        assertTrue(lvs.isApprovedKeeper(carol), "registry kept");
        assertEq(lvs.getKeepers().length, 2, "list kept");
        assertEq(lvs.TIMELOCK(), timelock, "timelock kept");
        (address proxy,) = _bobAccount();
        _liquidateAs(keeper, _params(proxy, 1950e6));
    }

    /// @notice The views return the construction values and the implementation constants.
    // TEST-242 verifies: REQ-SWAP-040, REQ-SWAP-076, REQ-SWAP-122
    function test_TEST_242_views() public view {
        assertEq(lvs.LOCK(), address(lock), "LOCK");
        assertEq(lvs.AAVE_ADAPTER(), address(adapter), "AAVE_ADAPTER");
        assertEq(lvs.COLLATERALIZATION(), address(coll), "COLLATERALIZATION");
        assertEq(lvs.MARKET_REGISTRY(), address(registry), "MARKET_REGISTRY");
        assertEq(lvs.PARAMETER_STORE(), address(store), "PARAMETER_STORE");
        assertEq(lvs.PAYOUT_ESCROW(), address(escrow), "PAYOUT_ESCROW");
        assertEq(lvs.PAYOUT_TRANSFER_GAS(), 100_000, "PAYOUT_TRANSFER_GAS");
        assertEq(lvs.MAX_REPAY_TRANSFERS(), 4, "MAX_REPAY_TRANSFERS");
        assertEq(lvs.MAX_KEEPERS(), 32, "MAX_KEEPERS");
        assertEq(lvs.KEEPER_FLOOR(), 1, "KEEPER_FLOOR");
    }

    /// @notice TEST-032 for LPVaultSwap: no rescue, sweep, withdraw, arbitrary call, multicall, in-kind or budget
    /// selector, no second liquidation entry point, no flash-source setter.
    // TEST-032 verifies: REQ-SWAP-043, REQ-SWAP-031, REQ-SWAP-072, REQ-SWAP-080, REQ-SWAP-113, REQ-FLASH-006, REQ-ACCESS-139
    // TEST-059 verifies: REQ-SWAP-029, REQ-SWAP-043, INV-037
    function test_TEST_032_selectorInventory() public {
        string[14] memory absent = [
            "sweep(address)",
            "rescue(address,uint256)",
            "rescueTokens(address,address,uint256)",
            "withdraw(address,uint256)",
            "execute(address,bytes)",
            "multicall(bytes[])",
            "liquidatePermissionless((address,uint256,uint256,uint256,uint8,uint256[],uint256,uint256,uint256))",
            "setFlashSource(address)",
            "enableInKind(uint256)",
            "setInKindWindow(uint256,uint64)",
            "reportRecoveryShortfall(uint256)",
            "topUp(uint256)",
            "draw(address,uint256)",
            "setSettlementBudget(address,uint256)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = address(lvs).call(abi.encodeWithSignature(absent[i]));
            assertFalse(ok, absent[i]);
        }
        (bool sent,) = address(lvs).call{value: 1}("");
        assertFalse(sent, "no receive: ETH refused");
    }
}
