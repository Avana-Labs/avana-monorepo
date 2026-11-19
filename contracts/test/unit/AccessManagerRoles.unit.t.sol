// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaAccess} from "../../script/deploy/lib/AvanaAccess.sol";
import {AvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/AvanaFirstLossReserve.sol";
import {IAvanaFirstLossReserve} from "../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {CollHubSpokeConfig, ICollHubConfigurator} from "../utils/fixtures/CollateralizationFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title AccessManagerRolesUnitTest
/// @notice The role and delay mapping of `AvanaAccess` on the deployed stack: every governed function of the
/// ParameterStore, MarketRegistry, LPVaultSwap, VaultTokenFactory, RiskModule, AaveAdapter and a
/// First-Loss Reserve sits on the role the map names, and the governance Safe holds that role with its delay. A tighten
/// setter executes only 12 hours after it is scheduled, a normal setter only after the governance delay (5 days), a
/// First-Loss Reserve withdraw only after 14 days; the DAO can cancel each; an unscheduled call by the Safe reverts
/// `AccessManagerNotScheduled` and any call by an account without a role reverts `AccessManagedUnauthorized`.
/// forge-config: default.isolate = false
contract AccessManagerRolesUnitTest is RealStackFlows {
    uint256 internal mA;
    AvanaFirstLossReserve internal reserve;
    address internal reserveRecipient = makeAddr("reserveRecipient");

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        reserve = new AvanaFirstLossReserve(aave.hub, address(gho), ghoAssetId, address(accessManager));
        uint24 maxRp = IAaveV4Hub(aave.hub).MAX_RISK_PREMIUM_THRESHOLD();
        vm.prank(aaveDao);
        ICollHubConfigurator(aave.hubConfigurator)
            .addSpoke(aave.hub, address(reserve), ghoAssetId, CollHubSpokeConfig(1_000_000, 0, maxRp, true, false));
        _bindAccess(AvanaAccess.Kind.FirstLossReserve, address(reserve));
    }

    // ─── The map ───

    /// @notice Every binding of `AvanaAccess` is in force on the deployed contracts: the function carries the mapped
    /// role, the governance Safe holds the role with the role's delay, the DAO is the role's guardian and holds no
    /// Avana role itself, and nothing outside the map is restricted to a role.
    // TEST-062 verifies: REQ-ACCESS-155, REQ-ACCESS-156, INV-084
    function test_TEST_062_everyMappedFunctionCarriesItsRoleAndDelay() public view {
        AvanaAccess.Binding[] memory all = AvanaAccess.bindings();
        for (uint256 i = 0; i < all.length; ++i) {
            address target = _targetOf(all[i].kind);
            assertEq(
                accessManager.getTargetFunctionRole(target, all[i].selector), all[i].role, "selector on another role"
            );
            (bool immediate, uint32 delay) = accessManager.canCall(governanceMultisig, target, all[i].selector);
            assertFalse(immediate, "the Safe never calls at once");
            assertEq(delay, AvanaAccess.roleDelay(all[i].role, NORMAL_DELAY), "delay of the role");
            (immediate, delay) = accessManager.canCall(governor, target, all[i].selector);
            assertTrue(immediate, "governor calls at once");
            (immediate, delay) = accessManager.canCall(aaveGovernanceExecutor, target, all[i].selector);
            assertFalse(immediate);
            assertEq(delay, 0, "the DAO holds no Avana role");
            (immediate, delay) = accessManager.canCall(attacker, target, all[i].selector);
            assertFalse(immediate);
            assertEq(delay, 0, "a stranger has no delay to wait");
        }
    }

    /// @notice The roles carry the delays of the design and the DAO is the guardian of each.
    // TEST-062 verifies: REQ-ACCESS-155, REQ-ACCESS-156
    function test_TEST_062_rolesDelaysAndGuardian() public view {
        uint64[3] memory ids = [AvanaRoles.TIGHTEN_ROLE, AvanaRoles.GOVERNANCE_ROLE, AvanaRoles.RESERVE_WITHDRAW_ROLE];
        uint32[3] memory delays = [uint32(12 hours), NORMAL_DELAY_32, uint32(14 days)];
        for (uint256 i = 0; i < ids.length; ++i) {
            (bool member, uint32 delay) = accessManager.hasRole(ids[i], governanceMultisig);
            assertTrue(member, "the Safe holds the role");
            assertEq(delay, delays[i], "execution delay");
            assertEq(accessManager.getRoleGuardian(ids[i]), AvanaRoles.ADMIN_ROLE, "the DAO is the guardian");
            assertEq(accessManager.getRoleAdmin(ids[i]), AvanaRoles.ADMIN_ROLE, "the DAO is the admin");
        }
        (bool isMember,) = accessManager.hasRole(AvanaRoles.ADMIN_ROLE, aaveGovernanceExecutor);
        assertTrue(isMember, "the DAO is the manager's admin");
    }

    // ─── A tighten setter: 12 hours ───

    // TEST-063 verifies: REQ-PSTORE-002, REQ-CONFIG-053, REQ-ACCESS-155
    function test_TEST_063_tightenSetterExecutesAfterTwelveHours() public {
        bytes memory data = abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (mA, 0));
        _scheduleWaitAndCancelThenRun(address(store), data, 12 hours);
        assertEq(store.marketUsdCap(mA), 0, "tightened after 12 hours");
    }

    /// @notice A MarketRegistry tighten function, the offboarding of an Active market, takes 12 hours too.
    // TEST-063 verifies: REQ-MREG-004, REQ-ACCESS-155
    function test_TEST_063_registryTightenExecutesAfterTwelveHours() public {
        bytes memory data = abi.encodeCall(IMarketRegistry.setMarketOffboarding, (mA));
        _scheduleWaitAndCancelThenRun(address(registry), data, 12 hours);
        assertGt(registry.windDownState(mA).offboardedAt, 0, "offboarding started after 12 hours");
    }

    /// @notice LPVaultSwap `removeKeeper` is a tighten function; `addKeeper` is a governance one.
    // TEST-063 verifies: REQ-SWAP-035, REQ-SWAP-033, REQ-ACCESS-155
    function test_TEST_063_keeperChangesFollowTheirRoles() public {
        address extra = makeAddr("extraKeeper");
        _scheduleWaitAndCancelThenRun(lpVaultSwap, abi.encodeCall(ILPVaultSwap.addKeeper, (extra)), NORMAL_DELAY);
        assertTrue(lvs.isApprovedKeeper(extra), "added after the governance delay");
        _scheduleWaitAndCancelThenRun(lpVaultSwap, abi.encodeCall(ILPVaultSwap.removeKeeper, (extra)), 12 hours);
        assertFalse(lvs.isApprovedKeeper(extra), "removed after 12 hours");
    }

    // ─── Normal setters: the governance delay ───

    // TEST-063 verifies: REQ-PSTORE-002, REQ-CONFIG-053, REQ-ACCESS-155
    function test_TEST_063_normalSetterExecutesAfterTheGovernanceDelay() public {
        address recipient = makeAddr("newFeeRecipient");
        bytes memory data = abi.encodeCall(IParameterStore.setFeeRecipient, (recipient));
        _scheduleWaitAndCancelThenRun(address(store), data, NORMAL_DELAY);
        assertEq(store.feeRecipient(), recipient, "set after the governance delay");
    }

    // TEST-063 verifies: REQ-MREG-004, REQ-ACCESS-155
    function test_TEST_063_registrySetterExecutesAfterTheGovernanceDelay() public {
        bytes32 hash = keccak256("a new standard Spoke code hash");
        bytes memory data = abi.encodeCall(IMarketRegistry.approveSpokeCodeHash, (hash));
        _scheduleWaitAndCancelThenRun(address(registry), data, NORMAL_DELAY);
        assertTrue(registry.isApprovedSpokeCodeHash(hash), "approved after the governance delay");
    }

    /// @notice An upgrade of each upgradeable contract takes the governance delay, never the short one.
    // TEST-063 verifies: REQ-ACCESS-155, INV-065
    function test_TEST_063_upgradesTakeTheGovernanceDelay() public view {
        address[5] memory proxies = [address(store), address(registry), address(riskModule), adapter, lpVaultSwap];
        for (uint256 i = 0; i < proxies.length; ++i) {
            bytes memory data = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(1), ""));
            (bool immediate, uint32 delay) = accessManager.canCall(governanceMultisig, proxies[i], bytes4(data));
            assertFalse(immediate);
            assertEq(delay, NORMAL_DELAY, "upgrade delay");
        }
    }

    // ─── First-Loss Reserve withdraw: 14 days ───

    // TEST-293 verifies: REQ-FLR-023, REQ-FLR-025, REQ-FLR-033, SPEC-FLR-003
    function test_TEST_293_reserveWithdrawExecutesAfterFourteenDays() public {
        gho.mint(avanaLabs, 100_000e18);
        vm.startPrank(avanaLabs);
        gho.approve(address(reserve), 100_000e18);
        reserve.fund(100_000e18);
        vm.stopPrank();
        bytes memory data = abi.encodeCall(IAvanaFirstLossReserve.withdraw, (40_000e18, reserveRecipient));
        _scheduleWaitAndCancelThenRun(address(reserve), data, 14 days);
        assertEq(gho.balanceOf(reserveRecipient), 40_000e18, "withdrawn after 14 days");
        assertEq(reserve.totalWithdrawn(), 40_000e18);
    }

    // ─── Unscheduled calls ───

    /// @notice The governance Safe calling a governed function without scheduling it reverts
    /// `AccessManagerNotScheduled`; an account without a role reverts `AccessManagedUnauthorized`; the DAO, which holds
    /// no Avana role, is refused as a stranger is.
    // TEST-062 verifies: REQ-ACCESS-153, INV-084
    function test_TEST_062_unscheduledCallsRevert() public {
        bytes[3] memory calls = [
            abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (mA, 0)),
            abi.encodeCall(IParameterStore.setFeeRecipient, (makeAddr("someone"))),
            abi.encodeCall(IMarketRegistry.approveSpokeCodeHash, (keccak256("h")))
        ];
        address[3] memory targets = [address(store), address(store), address(registry)];
        for (uint256 i = 0; i < calls.length; ++i) {
            bytes32 opId = accessManager.hashOperation(governanceMultisig, targets[i], calls[i]);
            vm.prank(governanceMultisig);
            vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, opId));
            (bool ok,) = targets[i].call(calls[i]);
            ok;
            address[2] memory strangers = [attacker, aaveGovernanceExecutor];
            for (uint256 j = 0; j < strangers.length; ++j) {
                vm.prank(strangers[j]);
                vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, strangers[j]));
                (ok,) = targets[i].call(calls[i]);
            }
        }
    }

    // ─── Helpers ───

    uint32 internal constant NORMAL_DELAY_32 = 432_000;

    /// @dev One governed call, end to end. The governance Safe schedules it and it is ready after `delay`; one second
    /// earlier the manager refuses it (`AccessManagerNotReady`); the DAO cancels it and it can no longer run; scheduled
    /// again it runs, as the Safe, at the ready time.
    function _scheduleWaitAndCancelThenRun(
        address target,
        bytes memory data,
        uint256 delay
    ) internal {
        (bytes32 id, uint256 readyAt) = _scheduleOp(governanceMultisig, target, data);
        assertEq(readyAt, block.timestamp + delay, "ready after the role's delay");
        vm.warp(readyAt - 1);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, id));
        accessManager.execute(target, data);

        vm.prank(aaveGovernanceExecutor);
        accessManager.cancel(governanceMultisig, target, data);
        assertEq(accessManager.getSchedule(id), 0, "cancelled by the DAO");
        vm.warp(readyAt + 1);
        vm.prank(governanceMultisig);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, id));
        accessManager.execute(target, data);

        (id, readyAt) = _scheduleOp(governanceMultisig, target, data);
        assertEq(readyAt, block.timestamp + delay, "scheduled again");
        vm.warp(readyAt);
        _refreshFeeds();
        vm.prank(governanceMultisig);
        accessManager.execute(target, data);
        assertEq(accessManager.getSchedule(id), 0, "consumed");
    }

    function _targetOf(
        AvanaAccess.Kind kind
    ) internal view returns (address) {
        if (kind == AvanaAccess.Kind.ParameterStore) return address(store);
        if (kind == AvanaAccess.Kind.MarketRegistry) return address(registry);
        if (kind == AvanaAccess.Kind.LPVaultSwap) return lpVaultSwap;
        if (kind == AvanaAccess.Kind.VaultTokenFactory) return address(vtFactory);
        if (kind == AvanaAccess.Kind.RiskModule) return address(riskModule);
        if (kind == AvanaAccess.Kind.AaveAdapter) return adapter;
        if (kind == AvanaAccess.Kind.LpVault) return integration;
        return address(reserve);
    }
}
