// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistry} from "../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryBase} from "../../src/policy/market-registry/IMarketRegistryBase.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {RiskTier} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketDef} from "../../src/types/MarketTypes.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @notice Role and caller matrix over every external write of the MarketRegistry: each selector against each caller
/// class (stranger, Emergency Guardian, Aave governance executor, RiskModule, governor), with the exact access error
/// for every refused pair and no access error for every admitted pair.
contract MarketRegistryAccessMatrixUnitTest is MarketRegistryFixture {
    /// @dev Access classes of the writes (REQ-MREG-004, REQ-MREG-028, REQ-CONFIG-080, REQ-CONFIG-081).
    uint8 internal constant ADMIN = 0;
    uint8 internal constant ANYONE = 1;

    struct Write {
        string name;
        bytes data;
        uint8 class;
    }

    address internal stranger = makeAddr("stranger");
    uint256 internal marketId;
    address internal vt;

    function setUp() public {
        _setUpWorld();
        (marketId, vt,) = _activeMarket();
    }

    /// @dev Every external write of the registry with arguments that reach the logic body.
    function _writes() internal view returns (Write[] memory w) {
        address h = address(hub);
        address sp = address(spoke);
        address[] memory one = new address[](1);
        one[0] = address(this);
        MarketDef memory def = _marketDef(vt, address(0));
        w = new Write[](20);
        w[0] = Write("recordHub", abi.encodeCall(registry.recordHub, (alice, RiskTier.Stable)), ADMIN);
        w[1] = Write(
            "setAvanaFirstLossReserve", abi.encodeCall(registry.setAvanaFirstLossReserve, (h, alice, bob)), ADMIN
        );
        w[2] = Write("setFlashSource", abi.encodeCall(registry.setFlashSource, (address(flash))), ADMIN);
        w[3] = Write("approveSpokeCodeHash", abi.encodeCall(registry.approveSpokeCodeHash, (keccak256("x"))), ADMIN);
        w[4] =
            Write("recordIntegrationContracts", abi.encodeCall(registry.recordIntegrationContracts, (V3, one)), ADMIN);
        w[5] = Write("deployCdpSpoke", abi.encodeCall(registry.deployCdpSpoke, (_spokeDef())), ADMIN);
        w[6] = Write("enableDebtReserve", abi.encodeCall(registry.enableDebtReserve, (sp, _ghoDef())), ADMIN);
        w[7] = Write("removeDebtReserve", abi.encodeCall(registry.removeDebtReserve, (sp, 7)), ADMIN);
        w[8] = Write("listToken", abi.encodeCall(registry.listToken, (alice, _tokenDef(new address[](0), one))), ADMIN);
        w[9] = Write("setPriceSource", abi.encodeCall(registry.setPriceSource, (alice, one, one)), ADMIN);
        w[10] = Write("listCollateralMarket", abi.encodeCall(registry.listCollateralMarket, (def)), ADMIN);
        w[11] = Write("activateMarket", abi.encodeCall(registry.activateMarket, (marketId)), ADMIN);
        w[12] = Write("cancelRegistration", abi.encodeCall(registry.cancelRegistration, (marketId)), ADMIN);
        w[13] = Write("setMarketOffboarding", abi.encodeCall(registry.setMarketOffboarding, (marketId)), ADMIN);
        w[14] = Write(
            "setRoute", abi.encodeCall(registry.setRoute, (marketId, address(usdc), address(gho), 0, alice)), ADMIN
        );
        w[15] = Write(
            "disableRoute", abi.encodeCall(registry.disableRoute, (marketId, address(usdc), address(gho), 0)), ADMIN
        );
        w[16] = Write(
            "restoreRoute",
            abi.encodeCall(registry.restoreRoute, (marketId, address(usdc), address(gho), 0, alice)),
            ADMIN
        );
        w[17] = Write("setSettlementReserve", abi.encodeCall(registry.setSettlementReserve, (marketId, 0)), ADMIN);
        w[18] = Write("upgradeToAndCall", abi.encodeCall(registry.upgradeToAndCall, (alice, "")), ADMIN);
        w[19] =
            Write("finalizeIntegrationContracts", abi.encodeCall(registry.finalizeIntegrationContracts, (V3)), ADMIN);
    }

    function _holdsAdmin(
        address caller
    ) internal view returns (bool) {
        return caller == governor;
    }

    /// @dev The access error the router returns to `caller` for `class`, or empty when the caller is admitted.
    function _accessError(
        uint8 class,
        address caller
    ) internal view returns (bytes memory) {
        if (class == ADMIN) {
            return _holdsAdmin(caller)
                ? bytes("")
                : abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller);
        }
        return "";
    }

    function _isAccessError(
        bytes memory ret
    ) internal pure returns (bool) {
        if (ret.length < 4) return false;
        bytes4 sel = bytes4(ret);
        return
            sel == IAccessManaged.AccessManagedUnauthorized.selector || sel == IMarketRegistryBase.Unauthorized.selector;
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

    function _callers() internal view returns (address[5] memory c) {
        c = [stranger, emergencyGuardian, aaveGovernanceExecutor, address(rm), governor];
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-MREG-005, REQ-MREG-019, REQ-MREG-022, REQ-MREG-026, REQ-MREG-028, REQ-CONFIG-001, REQ-CONFIG-002, INV-084, REQ-ACCESS-033, REQ-ACCESS-034, REQ-ACCESS-045, REQ-ACCESS-046, REQ-ACCESS-047, REQ-ACCESS-048, REQ-ACCESS-184, REQ-ACCESS-133, REQ-ACCESS-134, REQ-ACCESS-036, REQ-ACCESS-145, REQ-ACCESS-175, REQ-ACCESS-062, REQ-ACCESS-063, REQ-ACCESS-172, REQ-ACCESS-158, REQ-ACCESS-159, REQ-ACCESS-170, REQ-ACCESS-075, REQ-ACCESS-087, REQ-ACCESS-089, REQ-ACCESS-025, REQ-ACCESS-094, REQ-ACCESS-111, REQ-ACCESS-112, REQ-ACCESS-174
    // Sources: 5.1 TEST-062, TEST-066
    function test_TEST_062_everyWriteAgainstEveryCallerClass() public {
        Write[] memory w = _writes();
        address[5] memory c = _callers();
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
        vm.assume(caller != governor && caller != governanceMultisig);
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
        address[5] memory c = _callers();
        for (uint256 j = 0; j < c.length; ++j) {
            uint256 snap = vm.snapshotState();
            vm.prank(c[j]);
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistry.MarketNotOffboarding.selector, marketId));
            registry.closeMarket(marketId);
            vm.revertToState(snap);
        }
    }

    // TEST-062 verifies: REQ-MREG-004, REQ-MREG-026
    // The router checks the caller before the logic runs, so a refused caller sees the access error even when the
    // arguments would also fail (an unknown Hub, market or debt reserve).
    function test_TEST_062_accessCheckedBeforeArguments() public {
        bytes memory unauthorized = abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        registry.recordHub(address(0), RiskTier.None);
        vm.expectRevert(unauthorized);
        registry.activateMarket(999);
        vm.expectRevert(unauthorized);
        registry.removeDebtReserve(alice, 999);
        vm.stopPrank();
    }

    // TEST-242 verifies: REQ-MREG-005, INV-084
    // The governance Safe holds its roles with an execution delay, so a direct call reverts with the delay it needs and
    // only a scheduled operation passes; the DAO holds only the manager's admin role and no Avana role.
    function test_TEST_242_governanceSafeNeedsItsDelay() public {
        vm.prank(governanceMultisig);
        vm.expectRevert();
        registry.setFlashSource(address(flash));
        vm.prank(aaveGovernanceExecutor);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, aaveGovernanceExecutor)
        );
        registry.setFlashSource(address(flash));
        assertEq(registry.authority(), address(accessManager));
    }

    // TEST-062 verifies: REQ-CONFIG-001, REQ-CONFIG-002
    // The implementation behind the proxy has no authority: every guarded write on it is refused.
    function test_TEST_062_implementationHasNoAuthority() public {
        MarketRegistry impl = new MarketRegistry(im, logics);
        assertEq(impl.authority(), address(0));
        vm.prank(governor);
        vm.expectRevert();
        impl.recordHub(alice, RiskTier.Stable);
    }
}
