// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryWindDown} from "../../src/policy/market-registry/IMarketRegistryWindDown.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Role and caller matrix over every external write of the MarketRegistry: each selector against each caller
/// class (stranger, freeze-only guardian, pause-only guardian, full guardian, Aave governance executor, RiskModule,
/// timelock), with the exact access error for every refused pair and no access error for every admitted pair.
contract MarketRegistryAccessMatrixUnitTest is MarketRegistryFixture {
    /// @dev Access classes of the writes (REQ-MREG-004, REQ-MREG-019, REQ-MREG-022, REQ-MREG-025, REQ-MREG-026,
    /// REQ-MREG-028, REQ-CONFIG-080, REQ-CONFIG-081).
    uint8 internal constant ADMIN = 0;
    uint8 internal constant FREEZE_OR_ADMIN = 1;
    uint8 internal constant PAUSE_OR_ADMIN = 2;
    uint8 internal constant EXECUTOR = 3;
    uint8 internal constant RISK = 4;
    uint8 internal constant ANYONE = 5;

    struct Write {
        string name;
        bytes data;
        uint8 class;
    }

    address internal freezeOnly = makeAddr("freezeOnlyGuardian");
    address internal pauseOnly = makeAddr("pauseOnlyGuardian");
    address internal stranger = makeAddr("stranger");
    uint256 internal marketId;
    address internal vt;

    function setUp() public {
        _setUpWorld();
        (marketId, vt,) = _activeMarket();
        vm.startPrank(address(timelock));
        registry.grantRole(FREEZE_GUARDIAN, freezeOnly);
        registry.grantRole(PAUSE_GUARDIAN, pauseOnly);
        vm.stopPrank();
    }

    /// @dev Every external write of the registry with arguments that reach the logic body.
    function _writes() internal view returns (Write[] memory w) {
        address h = address(hub);
        address sp = address(spoke);
        address[] memory one = new address[](1);
        one[0] = address(this);
        MarketDef memory def = _marketDef(vt, address(0));
        w = new Write[](40);
        w[0] = Write("recordHub", abi.encodeCall(registry.recordHub, (alice, RiskTier.Stable)), ADMIN);
        w[1] = Write("registerIntegration", abi.encodeCall(registry.registerIntegration, (2, alice, bob)), ADMIN);
        w[2] = Write("setCoverageSpoke", abi.encodeCall(registry.setCoverageSpoke, (h, alice, bob)), ADMIN);
        w[3] = Write("setCrossHubLine", abi.encodeCall(registry.setCrossHubLine, (h, address(gho), sp, 0)), ADMIN);
        w[4] = Write("setCrossHubLinesEnabled", abi.encodeCall(registry.setCrossHubLinesEnabled, (true)), ADMIN);
        w[5] = Write("setFlashSource", abi.encodeCall(registry.setFlashSource, (address(flash))), ADMIN);
        w[6] = Write("approveSpokeCodeHash", abi.encodeCall(registry.approveSpokeCodeHash, (keccak256("x"))), ADMIN);
        w[7] =
            Write("recordIntegrationContracts", abi.encodeCall(registry.recordIntegrationContracts, (V3, one)), ADMIN);
        w[8] = Write("deployCdpSpoke", abi.encodeCall(registry.deployCdpSpoke, (_spokeDef())), ADMIN);
        w[9] = Write("enableDebtReserve", abi.encodeCall(registry.enableDebtReserve, (sp, _ghoDef())), ADMIN);
        w[10] = Write("removeDebtReserve", abi.encodeCall(registry.removeDebtReserve, (sp, 7)), ADMIN);
        w[11] = Write(
            "listToken",
            abi.encodeCall(registry.listToken, (alice, _tokenDef(new address[](0), one, new address[](0)))),
            ADMIN
        );
        w[12] = Write(
            "setPriceSource", abi.encodeCall(registry.setPriceSource, (alice, one, one, new address[](0))), ADMIN
        );
        w[13] = Write("listCollateralMarket", abi.encodeCall(registry.listCollateralMarket, (def)), ADMIN);
        w[14] = Write("activateMarket", abi.encodeCall(registry.activateMarket, (marketId)), ADMIN);
        w[15] = Write("cancelRegistration", abi.encodeCall(registry.cancelRegistration, (marketId)), ADMIN);
        w[16] = Write("setMarketOffboarding", abi.encodeCall(registry.setMarketOffboarding, (marketId)), ADMIN);
        w[17] = Write(
            "setRoute", abi.encodeCall(registry.setRoute, (marketId, address(usdc), address(gho), 0, alice)), ADMIN
        );
        w[18] = Write(
            "disableRoute", abi.encodeCall(registry.disableRoute, (marketId, address(usdc), address(gho), 0)), ADMIN
        );
        w[19] = Write(
            "restoreRoute",
            abi.encodeCall(registry.restoreRoute, (marketId, address(usdc), address(gho), 0, alice)),
            ADMIN
        );
        w[20] = Write("restorePriceRoute", abi.encodeCall(registry.restorePriceRoute, (address(usdc))), ADMIN);
        w[21] = Write("unfreezeAddress", abi.encodeCall(registry.unfreezeAddress, (alice)), ADMIN);
        w[22] = Write("setSettlementReserve", abi.encodeCall(registry.setSettlementReserve, (marketId, 0)), ADMIN);
        w[23] = Write("recordCreditLine", abi.encodeCall(registry.recordCreditLine, (h, address(gho), 1)), ADMIN);
        w[24] = Write("upgradeToAndCall", abi.encodeCall(registry.upgradeToAndCall, (alice, "")), ADMIN);
        w[25] = Write("freeze", abi.encodeCall(registry.freeze, (h)), FREEZE_OR_ADMIN);
        w[26] = Write("freezeAll", abi.encodeCall(registry.freezeAll, ()), FREEZE_OR_ADMIN);
        w[27] = Write("freezeAddress", abi.encodeCall(registry.freezeAddress, (bob)), FREEZE_OR_ADMIN);
        w[28] = Write("tripMarketBreaker", abi.encodeCall(registry.tripMarketBreaker, (marketId)), FREEZE_OR_ADMIN);
        w[29] = Write("tripDebtBreaker", abi.encodeCall(registry.tripDebtBreaker, (sp, 0)), FREEZE_OR_ADMIN);
        w[30] = Write("pause", abi.encodeCall(registry.pause, (h, PauseReason.General)), PAUSE_OR_ADMIN);
        w[31] = Write("pauseAll", abi.encodeCall(registry.pauseAll, (PauseReason.General)), PAUSE_OR_ADMIN);
        w[32] = Write("unfreeze", abi.encodeCall(registry.unfreeze, (h)), PAUSE_OR_ADMIN);
        w[33] = Write("unpause", abi.encodeCall(registry.unpause, (h)), PAUSE_OR_ADMIN);
        w[34] = Write("resetMarketBreaker", abi.encodeCall(registry.resetMarketBreaker, (marketId)), PAUSE_OR_ADMIN);
        w[35] = Write("resetDebtBreaker", abi.encodeCall(registry.resetDebtBreaker, (sp, 0)), PAUSE_OR_ADMIN);
        w[36] = Write(
            "useStandbyRoute",
            abi.encodeCall(registry.useStandbyRoute, (address(usdc), RouteSlot.Primary)),
            PAUSE_OR_ADMIN
        );
        w[37] = Write("cancelStandbySwitch", abi.encodeCall(registry.cancelStandbySwitch, (address(usdc))), EXECUTOR);
        w[38] = Write("recordBreach", abi.encodeCall(registry.recordBreach, (bytes32(marketId), 8)), RISK);
        w[39] = Write("syncDrawCap", abi.encodeCall(registry.syncDrawCap, (sp, 0)), ANYONE);
    }

    function _holdsAdmin(
        address caller
    ) internal view returns (bool) {
        return caller == address(timelock);
    }

    /// @dev The access error the router returns to `caller` for `class`, or empty when the caller is admitted.
    function _accessError(
        uint8 class,
        address caller
    ) internal view returns (bytes memory) {
        bool admin = _holdsAdmin(caller);
        if (class == ADMIN) {
            return admin
                ? bytes("")
                : abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, APP_ADMIN);
        }
        if (class == FREEZE_OR_ADMIN) {
            return admin || registry.hasRole(FREEZE_GUARDIAN, caller)
                ? bytes("")
                : abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, caller);
        }
        if (class == PAUSE_OR_ADMIN) {
            return admin || registry.hasRole(PAUSE_GUARDIAN, caller)
                ? bytes("")
                : abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, caller);
        }
        if (class == EXECUTOR) {
            return caller == aaveGovernanceExecutor
                ? bytes("")
                : abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, caller);
        }
        if (class == RISK) {
            return
                caller == address(rm) ? bytes("") : abi.encodeWithSelector(IMarketRegistryErrors.NotRiskModule.selector);
        }
        return "";
    }

    function _isAccessError(
        bytes memory ret
    ) internal pure returns (bool) {
        if (ret.length < 4) return false;
        bytes4 sel = bytes4(ret);
        return sel == IAccessControl.AccessControlUnauthorizedAccount.selector
            || sel == IMarketRegistryErrors.Unauthorized.selector || sel == IMarketRegistryErrors.NotRiskModule.selector;
    }

    /// @dev Runs `w` as `caller` from a snapshot and checks the access outcome; the state is restored afterwards.
    function _check(
        Write memory w,
        address caller
    ) internal {
        bytes memory expected = _accessError(w.class, caller);
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(registry).call(w.data);
        vm.revertToState(snap);
        if (expected.length != 0) {
            assertFalse(ok, string.concat(w.name, ": refused caller admitted"));
            assertEq(ret, expected, string.concat(w.name, ": wrong access error"));
        } else {
            assertFalse(!ok && _isAccessError(ret), string.concat(w.name, ": admitted caller refused"));
        }
    }

    function _callers() internal view returns (address[7] memory c) {
        c = [stranger, freezeOnly, pauseOnly, emergencyGuardian, aaveGovernanceExecutor, address(rm), address(timelock)];
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-MREG-005, REQ-MREG-019, REQ-MREG-022, REQ-MREG-026, REQ-MREG-028, REQ-CONFIG-001, REQ-CONFIG-002, INV-084
    // Sources: 5.1 TEST-062, TEST-066
    function test_TEST_062_everyWriteAgainstEveryCallerClass() public {
        Write[] memory w = _writes();
        address[7] memory c = _callers();
        for (uint256 i = 0; i < w.length; ++i) {
            for (uint256 j = 0; j < c.length; ++j) {
                _check(w[i], c[j]);
            }
        }
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-MREG-026, REQ-MREG-028
    function testFuzz_TEST_062_anyAddressWithoutARoleIsRefused(
        address caller,
        uint256 pick
    ) public {
        vm.assume(caller != address(timelock) && caller != aaveGovernanceExecutor && caller != address(rm));
        vm.assume(!registry.hasRole(FREEZE_GUARDIAN, caller) && !registry.hasRole(PAUSE_GUARDIAN, caller));
        Write[] memory w = _writes();
        Write memory one = w[bound(pick, 0, w.length - 1)];
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(registry).call(one.data);
        if (one.class == ANYONE) {
            assertFalse(!ok && _isAccessError(ret));
        } else {
            assertFalse(ok);
            assertEq(ret, _accessError(one.class, caller));
        }
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-CONFIG-080, REQ-CONFIG-081
    function test_TEST_062_permissionlessWritesAdmitEveryCaller() public {
        address[7] memory c = _callers();
        for (uint256 j = 0; j < c.length; ++j) {
            uint256 snap = vm.snapshotState();
            vm.prank(c[j]);
            registry.syncDrawCap(address(spoke), GHO_RESERVE);
            vm.prank(c[j]);
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketNotOffboarding.selector, marketId));
            registry.stepWindDown(marketId);
            vm.prank(c[j]);
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketNotOffboarding.selector, marketId));
            registry.closeMarket(marketId);
            vm.revertToState(snap);
        }
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-MREG-026
    // The router checks the caller before the logic runs, so a refused caller sees the access error even when the
    // arguments would also fail (an unknown Hub, market or debt reserve).
    function test_TEST_062_accessCheckedBeforeArguments() public {
        bytes memory unauthorized = abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        registry.freeze(alice);
        vm.expectRevert(unauthorized);
        registry.pause(alice, PauseReason.None);
        vm.expectRevert(unauthorized);
        registry.unpause(alice);
        vm.expectRevert(unauthorized);
        registry.tripMarketBreaker(999);
        vm.expectRevert(unauthorized);
        registry.tripDebtBreaker(alice, 999);
        vm.expectRevert(unauthorized);
        registry.freezeAddress(address(timelock));
        vm.expectRevert(unauthorized);
        registry.useStandbyRoute(alice, RouteSlot.None);
        vm.expectRevert(unauthorized);
        registry.cancelStandbySwitch(alice);
        vm.expectRevert(IMarketRegistryErrors.NotRiskModule.selector);
        registry.recordBreach(bytes32(0), 0);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, APP_ADMIN)
        );
        registry.recordHub(address(0), RiskTier.None);
        vm.stopPrank();
    }

    // TEST-066 verifies: REQ-MREG-004, REQ-MREG-005, Q-259
    // Guardian roles are administered by APPLICATION_ADMIN only: a guardian cannot add or remove a guardian, and a
    // revoked guardian loses its stops at once.
    function test_TEST_066_guardianRolesAdministeredByAdminOnly() public {
        vm.startPrank(emergencyGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, emergencyGuardian, APP_ADMIN
            )
        );
        registry.grantRole(PAUSE_GUARDIAN, alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, emergencyGuardian, APP_ADMIN
            )
        );
        registry.revokeRole(FREEZE_GUARDIAN, aaveGuardian);
        vm.stopPrank();

        vm.expectEmit(address(registry));
        emit IAccessControl.RoleRevoked(FREEZE_GUARDIAN, aaveGuardian, address(timelock));
        vm.prank(address(timelock));
        registry.revokeRole(FREEZE_GUARDIAN, aaveGuardian);
        assertFalse(registry.hasRole(FREEZE_GUARDIAN, aaveGuardian));
        vm.prank(aaveGuardian);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, aaveGuardian));
        registry.freeze(address(hub));
        // The pause role it still holds keeps working.
        vm.prank(aaveGuardian);
        registry.pause(address(hub), PauseReason.General);
        assertEq(uint8(registry.pauseState(address(hub))), uint8(PauseState.Paused));
    }

    // TEST-066 verifies: REQ-MREG-004, REQ-MREG-005
    function test_TEST_066_guardianRenouncesItsOwnRoleOnly() public {
        vm.prank(pauseOnly);
        registry.renounceRole(PAUSE_GUARDIAN, pauseOnly);
        assertFalse(registry.hasRole(PAUSE_GUARDIAN, pauseOnly));
        vm.prank(pauseOnly);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, pauseOnly));
        registry.pause(address(hub), PauseReason.General);
        vm.prank(pauseOnly);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        registry.renounceRole(FREEZE_GUARDIAN, freezeOnly);
        assertTrue(registry.hasRole(FREEZE_GUARDIAN, freezeOnly));
    }

    // TEST-242 verifies: REQ-MREG-005, REQ-ACCESS-153, INV-084
    function testFuzz_TEST_242_adminRolesNeverGrantedToAnotherAddress(
        address account,
        bool defaultAdmin
    ) public {
        vm.assume(account != address(timelock));
        bytes32 role = defaultAdmin ? registry.DEFAULT_ADMIN_ROLE() : APP_ADMIN;
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.AdminRoleOnlyTimelock.selector, role, account));
        registry.grantRole(role, account);
        assertFalse(registry.hasRole(role, account));
    }

    // TEST-242 verifies: REQ-MREG-005, INV-084
    function test_TEST_242_regrantToTheTimelockIsANoOp() public {
        bytes32 defaultAdmin = registry.DEFAULT_ADMIN_ROLE();
        vm.recordLogs();
        vm.startPrank(address(timelock));
        registry.grantRole(APP_ADMIN, address(timelock));
        registry.grantRole(defaultAdmin, address(timelock));
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(registry.hasRole(APP_ADMIN, address(timelock)));
        assertTrue(registry.hasRole(defaultAdmin, address(timelock)));
    }

    // TEST-242 verifies: REQ-MREG-005, REQ-CONFIG-002
    // A guardian role can be granted to any address, including a contract or the timelock itself; the admin roles
    // are the only restricted grants.
    function testFuzz_TEST_242_guardianRolesGrantableToAnyAddress(
        address account,
        bool pauseRole
    ) public {
        vm.assume(account != address(0));
        bytes32 role = pauseRole ? PAUSE_GUARDIAN : FREEZE_GUARDIAN;
        vm.prank(address(timelock));
        registry.grantRole(role, account);
        assertTrue(registry.hasRole(role, account));
    }

    // TEST-062 verifies: REQ-CONFIG-001, REQ-CONFIG-002
    // The implementation behind the proxy holds no roles: every guarded write on it is refused.
    function test_TEST_062_implementationHoldsNoRoles() public {
        MarketRegistry impl = new MarketRegistry(im, logics);
        assertFalse(impl.hasRole(APP_ADMIN, address(timelock)));
        vm.startPrank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(timelock), APP_ADMIN
            )
        );
        impl.recordHub(alice, RiskTier.Stable);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, address(timelock)));
        impl.freeze(address(hub));
        vm.stopPrank();
    }
}
