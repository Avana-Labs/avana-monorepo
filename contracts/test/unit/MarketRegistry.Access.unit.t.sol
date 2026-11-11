// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryHubsLogic} from "../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryImmutables} from "../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice Roles, initialization, upgrades, the logic-contract wiring and the selector inventory of the MarketRegistry.
contract MarketRegistryAccessUnitTest is MarketRegistryFixture {
    function setUp() public {
        _setUpWorld();
    }

    // TEST-242 verifies: REQ-MREG-005, REQ-ACCESS-153, INV-084, Q-259
    // Sources: 5.1 TEST-242
    function test_TEST_242_adminRolesOnlyForTimelock() public {
        bytes32 defaultAdmin = registry.DEFAULT_ADMIN_ROLE();
        vm.startPrank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AdminRoleOnlyTimelock.selector, APP_ADMIN, alice));
        registry.grantRole(APP_ADMIN, alice);
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.AdminRoleOnlyTimelock.selector, defaultAdmin, alice)
        );
        registry.grantRole(defaultAdmin, alice);
        registry.grantRole(FREEZE_GUARDIAN, alice);
        vm.stopPrank();
        assertTrue(registry.hasRole(FREEZE_GUARDIAN, alice));
        assertTrue(registry.hasRole(APP_ADMIN, address(timelock)));
        assertTrue(registry.hasRole(defaultAdmin, address(timelock)));
        assertEq(registry.getRoleAdmin(PAUSE_GUARDIAN), APP_ADMIN);
        assertEq(registry.getRoleAdmin(FREEZE_GUARDIAN), APP_ADMIN);
        assertEq(registry.getRoleAdmin(APP_ADMIN), defaultAdmin);
    }

    // TEST-242 verifies: REQ-MREG-005, REQ-CONFIG-002
    function test_TEST_242_initializeOnlyWithTimelockAndOnce() public {
        MarketRegistry impl = new MarketRegistry(im, logics);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AdminRoleOnlyTimelock.selector, bytes32(0), alice));
        new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (alice)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(address(timelock));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(timelock));
    }

    // TEST-066 verifies: REQ-MREG-004, REQ-MREG-022, REQ-MREG-028, Q-262, Q-263
    // Sources: 5.1 TEST-066
    function test_TEST_066_guardianPowersAreStopsOnly() public {
        bytes[] memory adminOnly = new bytes[](8);
        adminOnly[0] = abi.encodeCall(registry.recordHub, (alice, RiskTier.Stable));
        adminOnly[1] = abi.encodeCall(registry.unfreezeAddress, (alice));
        adminOnly[2] = abi.encodeCall(registry.restorePriceRoute, (address(usdc)));
        adminOnly[3] = abi.encodeCall(registry.setRoute, (1, address(usdc), address(gho), 0, alice));
        adminOnly[4] = abi.encodeCall(registry.setFlashSource, (alice));
        adminOnly[5] = abi.encodeCall(registry.setCrossHubLinesEnabled, (true));
        adminOnly[6] = abi.encodeCall(registry.recordCreditLine, (address(hub), address(gho), 1));
        adminOnly[7] = abi.encodeCall(registry.upgradeToAndCall, (alice, ""));
        for (uint256 i = 0; i < adminOnly.length; ++i) {
            vm.prank(emergencyGuardian);
            (bool ok, bytes memory ret) = address(registry).call(adminOnly[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), IAccessControl.AccessControlUnauthorizedAccount.selector);
        }
        // Guardian stops take effect at once.
        vm.startPrank(emergencyGuardian);
        registry.freeze(address(hub));
        registry.pause(address(hub), PauseReason.General);
        registry.freezeAddress(attacker);
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, emergencyGuardian));
        registry.cancelStandbySwitch(address(usdc));
        vm.stopPrank();
        vm.prank(aaveGovernanceExecutor);
        registry.cancelStandbySwitch(address(usdc));
    }

    // TEST-066 verifies: REQ-MREG-004, REQ-MREG-017
    function test_TEST_066_freezeRoleAloneCannotLift() public {
        address freezer = makeAddr("freezeOnly");
        vm.prank(address(timelock));
        registry.grantRole(FREEZE_GUARDIAN, freezer);
        vm.startPrank(freezer);
        registry.freeze(address(hub));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, freezer));
        registry.unfreeze(address(hub));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, freezer));
        registry.pause(address(hub), PauseReason.General);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, freezer));
        registry.resetMarketBreaker(1);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, freezer));
        registry.useStandbyRoute(address(usdc), RouteSlot.Primary);
        vm.stopPrank();
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-MREG-026, REQ-CONFIG-028
    // Sources: 5.1 TEST-062
    function test_TEST_062_strangerRefusedOnEveryWrite() public {
        bytes[] memory guarded = new bytes[](10);
        guarded[0] = abi.encodeCall(registry.freeze, (address(hub)));
        guarded[1] = abi.encodeCall(registry.pause, (address(hub), PauseReason.General));
        guarded[2] = abi.encodeCall(registry.freezeAll, ());
        guarded[3] = abi.encodeCall(registry.pauseAll, (PauseReason.General));
        guarded[4] = abi.encodeCall(registry.unfreeze, (address(hub)));
        guarded[5] = abi.encodeCall(registry.unpause, (address(hub)));
        guarded[6] = abi.encodeCall(registry.freezeAddress, (bob));
        guarded[7] = abi.encodeCall(registry.tripMarketBreaker, (1));
        guarded[8] = abi.encodeCall(registry.resetDebtBreaker, (address(spoke), 0));
        guarded[9] = abi.encodeCall(registry.useStandbyRoute, (address(usdc), RouteSlot.Primary));
        for (uint256 i = 0; i < guarded.length; ++i) {
            vm.prank(attacker);
            (bool ok, bytes memory ret) = address(registry).call(guarded[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, attacker));
        }
        vm.prank(attacker);
        vm.expectRevert(IMarketRegistryErrors.NotRiskModule.selector);
        registry.recordBreach(bytes32(uint256(1)), 1);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, APP_ADMIN)
        );
        registry.listToken(address(gho), _tokenDef(new address[](0), new address[](0), new address[](0)));
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-002, REQ-MREG-003
    // Sources: 5.1 TEST-168
    function test_TEST_168_upgradeKeepsStateAndNeedsAdmin() public {
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        MarketRegistry next = new MarketRegistry(im, logics);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, APP_ADMIN)
        );
        registry.upgradeToAndCall(address(next), "");
        vm.prank(address(timelock));
        registry.upgradeToAndCall(address(next), "");
        assertEq(uint8(registry.pauseState(address(hub))), 1);
        assertTrue(registry.getToken(address(usdc)).listed);
        assertEq(registry.getDebtReserveIds(address(spoke)).length, 1);
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-005
    function test_TEST_168_logicContractsRefuseDirectCallsAndMismatches() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, address(this)));
        MarketRegistryHubsLogic(logics.hubs).recordHub(alice, RiskTier.Stable);
        MarketRegistryLogics memory swapped = logics;
        (swapped.hubs, swapped.listing) = (logics.listing, logics.hubs);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("logic")));
        new MarketRegistry(im, swapped);
        MarketRegistryImmutables memory other = im;
        other.lock = makeAddr("otherLock");
        MarketRegistryLogics memory foreign = logics;
        foreign.safety = _deployLogics(other).safety;
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("logic")));
        new MarketRegistry(im, foreign);
        other = im;
        other.riskModule = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("immutables"))
        );
        new MarketRegistryHubsLogic(other);
        other = im;
        other.flashLiquidator = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("immutables"))
        );
        new MarketRegistryHubsLogic(other);
    }

    // TEST-168 verifies: REQ-CONFIG-005, REQ-CONFIG-064
    function test_TEST_168_immutableGetters() public view {
        assertEq(registry.TIMELOCK(), address(timelock));
        assertEq(registry.AAVE_GOVERNANCE_EXECUTOR(), aaveGovernanceExecutor);
        assertEq(registry.VAULT_TOKEN_FACTORY(), address(factory));
        assertEq(registry.AAVE_ADAPTER(), address(adapterMock));
        assertEq(registry.COLLATERALIZATION(), address(collat));
        assertEq(registry.LOCK(), lockAddr);
        assertEq(registry.PROXY_MANAGER(), proxyManager);
        assertEq(registry.PARAMETER_STORE(), address(ps));
        assertEq(registry.RISK_MODULE(), address(rm));
        assertEq(registry.LP_VAULT_SWAP(), address(lpVaultSwap));
        assertEq(registry.PAYOUT_ESCROW(), payoutEscrow);
        assertEq(registry.FLASH_LIQUIDATOR(), flashLiquidator);
        assertEq(registry.STANDARD_SPOKE_IMPLEMENTATION(), address(spokeImpl));
        assertEq(registry.flashSource(), address(flash));
        assertEq(registry.MAX_ADDRESS_FREEZES_PER_DAY(), 20);
    }

    // TEST-053 verifies: REQ-MREG-016, REQ-MREG-029, REQ-MREG-011, REQ-MREG-013, Q-401
    // Sources: 5.1 TEST-053, TEST-035
    function test_TEST_053_noInKindNoBuyNoSellBackSelectors() public {
        string[8] memory absent = [
            "enableInKind(uint256)",
            "disableInKind(uint256)",
            "autoEnableInKind(uint256)",
            "isInKindEnabled(uint256)",
            "setBuyRoute(uint256,address,uint8,address)",
            "restoreBuyRoute(uint256,address,uint8,address)",
            "setSellBackRoute(uint256,address,address)",
            "setInKindAutoTrigger(uint256,bool)"
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok, bytes memory ret) =
                address(registry).call(abi.encodeWithSignature(absent[i], uint256(1), address(0), uint8(0), address(0)));
            assertFalse(ok);
            assertEq(ret.length, 0);
        }
    }

    // TEST-035 verifies: REQ-MREG-003, REQ-CONFIG-082
    // Sources: 5.1 TEST-035
    function test_TEST_035_noPerMarketPauseSelector() public {
        string[4] memory absent =
            ["pauseMarket(uint256)", "freezeMarket(uint256)", "pauseFunction(bytes4)", "suspendKeeper(address)"];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok, bytes memory ret) = address(registry).call(abi.encodeWithSignature(absent[i], uint256(1)));
            assertFalse(ok);
            assertEq(ret.length, 0);
        }
    }
}
