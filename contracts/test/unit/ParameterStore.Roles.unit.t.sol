// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {DebtReserveParams} from "../../src/policy/parameter-store/types/DebtReserveParams.sol";
import {FeedDef} from "../../src/policy/parameter-store/types/FeedDef.sol";
import {MarketParams} from "../../src/policy/parameter-store/types/MarketParams.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {SecondSourceKind} from "../../src/types/SecondSourceKind.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockAggregator} from "../utils/mocks/ParameterStoreMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice The role matrix of every ParameterStore setter: the Joint Configuration Safe (`APPLICATION_RISK_STEWARD`)
/// runs each of the 20 tighten setters and `setAvanaFeeShareBps` at once with the timelock path's checks and its own
/// address as `caller`; the guardians hold `useStandbySecondSource` only; the timelock's delay class of every
/// selector; and who administers each role.
contract ParameterStoreRolesUnitTest is ParameterStoreFixture {
    bytes32 internal constant ADMIN = AvanaRoles.APPLICATION_ADMIN;
    bytes32 internal constant GUARDIAN = AvanaRoles.APPLICATION_PAUSE_GUARDIAN;
    bytes32 internal constant STEWARD = AvanaRoles.APPLICATION_RISK_STEWARD;
    address internal safe = makeAddr("jointConfigurationSafe");
    bytes internal notStricter = abi.encodeWithSelector(IParameterStoreErrors.NotStricter.selector);

    function setUp() public {
        _deployStore(false);
        _listMarket();
        vm.startPrank(address(timelock));
        store.grantRole(STEWARD, safe);
        store.grantRole(GUARDIAN, emergencyGuardian);
        store.grantRole(GUARDIAN, aaveGuardian);
        vm.stopPrank();
    }

    /// @dev The steward repeats its own call: the value is no longer strictly safer, exactly as on the timelock path.
    function _stewardRepeats(
        bytes memory data
    ) internal {
        vm.prank(safe);
        (bool ok, bytes memory ret) = address(store).call(data);
        assertFalse(ok, "steward repeated a tightening");
        assertEq(ret, notStricter);
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(data);
        assertFalse(ok, "timelock repeated a tightening");
        assertEq(ret, notStricter);
    }

    function _unauthorized(
        address who,
        bytes32 role
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who, role);
    }

    // ─── The 21 steward selectors, one by one ───

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-031, REQ-CONFIG-051, REQ-ACCESS-037
    function test_TEST_062_stewardRaisesHardFloor() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("hardHealthFloor", bytes32(M), 0, 1.1e18, safe);
        store.tightenHardHealthFloor(M, 1.1e18);
        assertEq(store.hardHealthFloor(M), 1.1e18);
        _stewardRepeats(abi.encodeCall(store.tightenHardHealthFloor, (M, 1.1e18)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-052, REQ-CONFIG-051, REQ-ACCESS-041, REQ-ACCESS-185
    function test_TEST_062_stewardLowersSlippage() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("slippageAllowanceBps", bytes32(M), 100, 50, safe);
        store.tightenSlippageAllowanceBps(M, 50);
        _stewardRepeats(abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 50)));
        // The steward meets the same liveness floor.
        vm.prank(safe);
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenSlippageAllowanceBps(M, 29);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-050, REQ-ACCESS-132
    function test_TEST_062_stewardLowersRoundingAllowance() public {
        _tl();
        store.setDebtAssetParams(gho, DebtReserveParams(1e18));
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened(
            "floorRoundingAllowance", bytes32(uint256(uint160(gho))), 1e18, 0.5e18, safe
        );
        store.tightenFloorRoundingAllowance(gho, 0.5e18);
        assertEq(store.floorRoundingAllowance(gho), 0.5e18);
        _stewardRepeats(abi.encodeCall(store.tightenFloorRoundingAllowance, (gho, 0.5e18)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-023, REQ-PSTORE-009, REQ-ACCESS-038
    function test_TEST_062_stewardLowersBorrowAge() public {
        address f = address(fUsdc);
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.FeedConfigured(f, 8, 1e6, 1e12, 86_400, 1800, 88_200, 25, 25, 4200, 88_200);
        store.tightenBorrowPriceMaxAge(f, 4200);
        assertEq(store.borrowPriceMaxAge(f), 4200);
        assertEq(store.liquidationPriceMaxAge(f), 88_200);
        _stewardRepeats(abi.encodeCall(store.tightenBorrowPriceMaxAge, (f, 4200)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-052, REQ-ACCESS-039
    function test_TEST_062_stewardLowersConsistencyTolerance() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("consistencyToleranceBps", bytes32(M), 50, 40, safe);
        store.tightenConsistencyToleranceBps(M, 40);
        _stewardRepeats(abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 40)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-024, REQ-CONFIG-057, REQ-ACCESS-040, REQ-ACCESS-077
    function test_TEST_062_stewardLowersAgreementTolerance() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened(
            "feedAgreementToleranceBps", bytes32(uint256(uint160(usdc))), 150, 120, safe
        );
        store.tightenFeedAgreementToleranceBps(usdc, 120);
        assertEq(store.feedAgreementToleranceBps(usdc), 120);
        _stewardRepeats(abi.encodeCall(store.tightenFeedAgreementToleranceBps, (usdc, 120)));
        // No temporary override: below the stored lower bound the steward is refused like the timelock.
        vm.prank(safe);
        vm.expectRevert(IParameterStoreErrors.LivenessBound.selector);
        store.tightenFeedAgreementToleranceBps(usdc, 99);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-015, REQ-ACCESS-138
    function test_TEST_062_stewardLowersPoolRiskFactor() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("poolRiskFactor", bytes32(M), 4000, 3000, safe);
        store.tightenPoolRiskFactor(M, 3000);
        _stewardRepeats(abi.encodeCall(store.tightenPoolRiskFactor, (M, 3000)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-070, REQ-ACCESS-131
    function test_TEST_062_stewardRaisesRouteDepth() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.RouteDepthThresholdSet(M, usdc, gho, 1, 0, 2_000_000e8);
        store.tightenRouteDepthThreshold(M, usdc, gho, 1, 2_000_000e8);
        assertEq(store.routeDepthThreshold(M, usdc, gho, 1), 2_000_000e8);
        assertEq(store.routeDepthThreshold(M, usdc, gho, 0), 0);
        _stewardRepeats(abi.encodeCall(store.tightenRouteDepthThreshold, (M, usdc, gho, 1, 2_000_000e8)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-RISK-042
    function test_TEST_062_stewardLowersMarketCap() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapTightened("marketUsdCap", bytes32(M), 5_000_000e8, 4_000_000e8, safe);
        store.tightenMarketUsdCap(M, 4_000_000e8);
        _stewardRepeats(abi.encodeCall(store.tightenMarketUsdCap, (M, 4_000_000e8)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-RISK-042
    function test_TEST_062_stewardLowersTopUpSlice() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapTightened("topUpSliceUsd", bytes32(M), 500_000e8, 0, safe);
        store.tightenTopUpSliceUsd(M, 0);
        assertEq(store.topUpSliceUsd(M), 0);
        _stewardRepeats(abi.encodeCall(store.tightenTopUpSliceUsd, (M, 0)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-RISK-042, REQ-PSTORE-026
    function test_TEST_062_stewardLowersTokenCap() public {
        bytes32 scope = keccak256(abi.encode(address(hub), usdc));
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapTightened("tokenUsdCap", scope, 20_000_000e8, 10_000_000e8, safe);
        store.tightenTokenUsdCap(address(hub), usdc, 10_000_000e8);
        _stewardRepeats(abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 10_000_000e8)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-RISK-042, REQ-PSTORE-026
    function test_TEST_062_stewardLowersDepositorCap() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapTightened(
            "depositorUsdCap", bytes32(uint256(uint160(address(hub)))), 1_000_000e8, 500_000e8, safe
        );
        store.tightenDepositorUsdCap(address(hub), 500_000e8);
        _stewardRepeats(abi.encodeCall(store.tightenDepositorUsdCap, (address(hub), 500_000e8)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-RISK-042, Q-403
    function test_TEST_062_stewardLowersPoolShareDefault() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapTightened("poolShareMaxBps", bytes32(0), 10_000, 2500, safe);
        store.tightenPoolShareMaxBps(2500);
        _stewardRepeats(abi.encodeCall(store.tightenPoolShareMaxBps, (2500)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-005, REQ-ACCESS-146
    function test_TEST_062_stewardRaisesMinPledge() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.MinPledgeUsdSet(M, 10e8, 20e8);
        store.tightenMinPledgeUsd(M, 20e8);
        _stewardRepeats(abi.encodeCall(store.tightenMinPledgeUsd, (M, 20e8)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-RISK-042, Q-383
    function test_TEST_062_stewardLowersPoolShareOverride() public {
        bytes32 key = keccak256(abi.encode(uint32(1), address(pool), bytes32(0)));
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.CapTightened("poolShareMaxBpsOf", key, 10_000, 1000, safe);
        store.tightenPoolShareMaxBpsOf(M, 1000);
        assertEq(store.poolShareMaxBpsOf(key), 1000);
        _stewardRepeats(abi.encodeCall(store.tightenPoolShareMaxBpsOf, (M, 1000)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-024, REQ-ACCESS-186
    function test_TEST_062_stewardLowersFlashFee() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("maxFlashFeeBps", bytes32(0), 10, 5, safe);
        store.tightenMaxFlashFeeBps(5);
        assertEq(store.maxFlashFeeBps(), 5);
        _stewardRepeats(abi.encodeCall(store.tightenMaxFlashFeeBps, (5)));
        // Raising it back is structural: the steward is refused with the admin role named.
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.setMaxFlashFeeBps(10);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-030
    function test_TEST_062_stewardRaisesGateRecovery() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("gateRecoverySeconds", bytes32(0), 1800, 3600, safe);
        store.tightenGateRecoverySeconds(3600);
        _stewardRepeats(abi.encodeCall(store.tightenGateRecoverySeconds, (3600)));
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.loosenGateRecoverySeconds(1800);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-016
    function test_TEST_062_stewardLowersDeficitThreshold() public {
        _tl();
        store.loosenBreakerDeficitMax(address(hub), gho, 10_000e18);
        bytes32 scope = keccak256(abi.encode(address(hub), gho));
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("breakerDeficitMax", scope, 10_000e18, 5000e18, safe);
        store.tightenBreakerDeficitMax(address(hub), gho, 5000e18);
        _stewardRepeats(abi.encodeCall(store.tightenBreakerDeficitMax, (address(hub), gho, 5000e18)));
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.loosenBreakerDeficitMax(address(hub), gho, 10_000e18);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-018
    function test_TEST_062_stewardLowersMaxShortfall() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened("maxShortfallBps", bytes32(0), 1000, 50, safe);
        store.tightenMaxShortfallBps(50);
        _stewardRepeats(abi.encodeCall(store.tightenMaxShortfallBps, (50)));
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-020
    function test_TEST_062_stewardRaisesStressRise() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterTightened(
            "debtStressRiseBps", bytes32(uint256(uint160(usdc))), 0, 500, safe
        );
        store.tightenDebtStressRiseBps(usdc, 500);
        _stewardRepeats(abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 500)));
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.loosenDebtStressRiseBps(usdc, 100);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-010
    function test_TEST_062_stewardMovesFeeShareBothWays() public {
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("avanaFeeShareBps", bytes32(0), 2000, 3000);
        store.setAvanaFeeShareBps(3000);
        vm.prank(safe);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("avanaFeeShareBps", bytes32(0), 3000, 1000);
        store.setAvanaFeeShareBps(1000);
        assertEq(store.avanaFeeShareBps(), 1000);
        // The recipient stays on the timelock.
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.setFeeRecipient(bob);
    }

    // ─── Everything else the steward may not touch ───

    // TEST-062 verifies: REQ-PSTORE-002, REQ-CONFIG-058, REQ-CONFIG-053, REQ-CONFIG-054
    function test_TEST_062_stewardRefusedOnLoosenStructuralAndListing() public {
        bytes[] memory calls = _timelockOnlyCalls();
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(safe);
            (bool ok, bytes memory ret) = address(store).call(calls[i]);
            assertFalse(ok, "steward ran a timelock-only setter");
            assertEq(ret, _unauthorized(safe, ADMIN));
        }
    }

    // ─── Guardian ───

    // TEST-066 verifies: REQ-PSTORE-029, REQ-CONFIG-058, EMG-103, REQ-ACCESS-179
    function test_TEST_066_bothGuardiansSwitchToTheStandby() public {
        _recordSources();
        vm.prank(aaveGuardian);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.SecondSourceSwitched(usdc, true, aaveGuardian);
        store.useStandbySecondSource(usdc);
        assertTrue(store.onStandby(usdc));
        _tl();
        store.restoreSecondSource(usdc);
        vm.prank(emergencyGuardian);
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.SecondSourceSwitched(usdc, true, emergencyGuardian);
        store.useStandbySecondSource(usdc);
        assertTrue(store.onStandby(usdc));
    }

    // TEST-066 verifies: REQ-PSTORE-029, REQ-PSTORE-002, REQ-CONFIG-058, REQ-ACCESS-179
    function test_TEST_066_onlyGuardiansSwitch() public {
        _recordSources();
        // The timelock holds the admin roles but not the guardian role.
        _tl();
        vm.expectRevert(_unauthorized(address(timelock), GUARDIAN));
        store.useStandbySecondSource(usdc);
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, GUARDIAN));
        store.useStandbySecondSource(usdc);
        // A guardian cannot switch back: restoring is a timelock operation.
        vm.prank(emergencyGuardian);
        store.useStandbySecondSource(usdc);
        vm.prank(emergencyGuardian);
        vm.expectRevert(_unauthorized(emergencyGuardian, ADMIN));
        store.restoreSecondSource(usdc);
        assertTrue(store.onStandby(usdc));
    }

    // TEST-066 verifies: REQ-PSTORE-029, REQ-CONFIG-058
    function test_TEST_066_guardianHoldsNoTighteningOrSetter() public {
        bytes[] memory calls = _timelockOnlyCalls();
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(emergencyGuardian);
            (bool ok, bytes memory ret) = address(store).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, _unauthorized(emergencyGuardian, ADMIN));
        }
        vm.prank(emergencyGuardian);
        vm.expectRevert(_unauthorized(emergencyGuardian, ADMIN));
        store.tightenMarketUsdCap(M, 1);
    }

    // ─── Role administration ───

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-002, REQ-ACCESS-153
    function test_TEST_242_roleAdminsAreFixed() public view {
        assertEq(store.getRoleAdmin(bytes32(0)), bytes32(0));
        assertEq(store.getRoleAdmin(ADMIN), bytes32(0));
        assertEq(store.getRoleAdmin(GUARDIAN), ADMIN);
        assertEq(store.getRoleAdmin(STEWARD), ADMIN);
        assertTrue(store.hasRole(STEWARD, safe));
        assertFalse(store.hasRole(ADMIN, safe));
        assertFalse(store.hasRole(bytes32(0), safe));
        assertFalse(store.hasRole(STEWARD, address(timelock)));
        assertFalse(store.hasRole(GUARDIAN, address(timelock)));
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-PSTORE-002, REQ-ACCESS-153
    function test_TEST_242_onlyTheTimelockGrantsAndRevokes() public {
        address[3] memory holders = [safe, emergencyGuardian, attacker];
        bytes32[4] memory roles = [bytes32(0), ADMIN, GUARDIAN, STEWARD];
        for (uint256 i = 0; i < holders.length; ++i) {
            for (uint256 j = 0; j < roles.length; ++j) {
                bytes32 needed = store.getRoleAdmin(roles[j]);
                vm.prank(holders[i]);
                vm.expectRevert(_unauthorized(holders[i], needed));
                store.grantRole(roles[j], alice);
                vm.prank(holders[i]);
                vm.expectRevert(_unauthorized(holders[i], needed));
                store.revokeRole(roles[j], address(timelock));
            }
        }
        // The timelock grants and revokes the delegated roles freely.
        vm.prank(address(timelock));
        store.grantRole(STEWARD, alice);
        assertTrue(store.hasRole(STEWARD, alice));
        vm.prank(address(timelock));
        store.revokeRole(STEWARD, safe);
        assertFalse(store.hasRole(STEWARD, safe));
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.tightenMinPledgeUsd(M, 20e8);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-ACCESS-153, Q-259
    function test_TEST_242_adminRolesNeverLeaveTheTimelock() public {
        address[4] memory others = [safe, emergencyGuardian, governanceMultisig, address(store)];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.prank(address(timelock));
            vm.expectRevert(
                abi.encodeWithSelector(IParameterStoreErrors.AdminRoleOnlyTimelock.selector, ADMIN, others[i])
            );
            store.grantRole(ADMIN, others[i]);
            vm.prank(address(timelock));
            vm.expectRevert(
                abi.encodeWithSelector(IParameterStoreErrors.AdminRoleOnlyTimelock.selector, bytes32(0), others[i])
            );
            store.grantRole(bytes32(0), others[i]);
            assertFalse(store.hasRole(ADMIN, others[i]));
        }
    }

    // TEST-062 verifies: REQ-PSTORE-002
    function test_TEST_062_renouncedStewardHoldsNothing() public {
        vm.prank(safe);
        store.renounceRole(STEWARD, safe);
        assertFalse(store.hasRole(STEWARD, safe));
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.tightenMaxShortfallBps(1);
        vm.prank(safe);
        vm.expectRevert(_unauthorized(safe, ADMIN));
        store.setAvanaFeeShareBps(1);
    }

    // ─── Delay class of every selector through the timelock ───

    // TEST-063 verifies: REQ-PSTORE-002, REQ-CONFIG-053, REQ-CONFIG-054, REQ-ACCESS-155
    function test_TEST_063_delayClassOfEverySelector() public view {
        bytes[] memory tight = _tightenCalls();
        for (uint256 i = 0; i < tight.length; ++i) {
            assertEq(_required(_one(address(store), tight[i])), SHORT_DELAY, "tighten selector not short");
        }
        bytes[] memory rest = _timelockOnlyCalls();
        for (uint256 i = 0; i < rest.length; ++i) {
            assertEq(_required(_one(address(store), rest[i])), NORMAL_DELAY, "normal selector short");
        }
        // The fee share is steward-callable but not short-eligible: through the timelock it waits the normal delay.
        assertEq(_required(_one(address(store), abi.encodeCall(store.setAvanaFeeShareBps, (1)))), NORMAL_DELAY);
        assertEq(_required(_one(address(store), abi.encodeCall(store.useStandbySecondSource, (usdc)))), NORMAL_DELAY);
    }

    // ─── Fixtures of calls ───

    function _recordSources() internal {
        MockAggregator pyth = new MockAggregator(8, 1e6, 1e12);
        MockAggregator redstone = new MockAggregator(8, 1e6, 1e12);
        vm.startPrank(address(timelock));
        store.setFeed(address(pyth), _feedDef(86_400, 1800));
        store.setFeed(address(redstone), _feedDef(86_400, 1800));
        SecondSource memory s = SecondSource(SecondSourceKind.OracleNetwork, address(pyth), bytes32(0), 88_200, 0, 100);
        SecondSource memory b =
            SecondSource(SecondSourceKind.OracleNetwork, address(redstone), bytes32(0), 88_200, 0, 100);
        store.setSecondSource(usdc, s, b);
        vm.stopPrank();
    }

    function _tightenCalls() internal view returns (bytes[] memory c) {
        c = new bytes[](20);
        c[0] = abi.encodeCall(store.tightenHardHealthFloor, (M, 1.1e18));
        c[1] = abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 50));
        c[2] = abi.encodeCall(store.tightenFloorRoundingAllowance, (gho, 1));
        c[3] = abi.encodeCall(store.tightenBorrowPriceMaxAge, (address(fUsdc), 1));
        c[4] = abi.encodeCall(store.tightenConsistencyToleranceBps, (M, 10));
        c[5] = abi.encodeCall(store.tightenFeedAgreementToleranceBps, (usdc, 100));
        c[6] = abi.encodeCall(store.tightenPoolRiskFactor, (M, 1));
        c[7] = abi.encodeCall(store.tightenRouteDepthThreshold, (M, usdc, gho, 0, 1));
        c[8] = abi.encodeCall(store.tightenMarketUsdCap, (M, 1e8));
        c[9] = abi.encodeCall(store.tightenTopUpSliceUsd, (M, 0));
        c[10] = abi.encodeCall(store.tightenTokenUsdCap, (address(hub), usdc, 1));
        c[11] = abi.encodeCall(store.tightenDepositorUsdCap, (address(hub), 1));
        c[12] = abi.encodeCall(store.tightenPoolShareMaxBps, (1));
        c[13] = abi.encodeCall(store.tightenMinPledgeUsd, (M, 20e8));
        c[14] = abi.encodeCall(store.tightenPoolShareMaxBpsOf, (M, 1));
        c[15] = abi.encodeCall(store.tightenMaxFlashFeeBps, (0));
        c[16] = abi.encodeCall(store.tightenGateRecoverySeconds, (7200));
        c[17] = abi.encodeCall(store.tightenBreakerDeficitMax, (address(hub), gho, 0));
        c[18] = abi.encodeCall(store.tightenMaxShortfallBps, (0));
        c[19] = abi.encodeCall(store.tightenDebtStressRiseBps, (usdc, 100));
    }

    /// @dev Every APPLICATION_ADMIN-only selector (loosen, structural, listing, second source, role change, upgrade).
    function _timelockOnlyCalls() internal view returns (bytes[] memory c) {
        MarketParams memory mp;
        FeedDef memory fd;
        SecondSource memory ss;
        c = new bytes[](46);
        uint256 k;
        c[k++] = abi.encodeCall(store.loosenHardHealthFloor, (M, 0));
        c[k++] = abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 101));
        c[k++] = abi.encodeCall(store.loosenFloorRoundingAllowance, (gho, 1));
        c[k++] = abi.encodeCall(store.loosenRouteDepthThreshold, (M, usdc, gho, 0, 1));
        c[k++] = abi.encodeCall(store.loosenMarketUsdCap, (M, 6_000_000e8));
        c[k++] = abi.encodeCall(store.loosenTopUpSliceUsd, (M, 600_000e8));
        c[k++] = abi.encodeCall(store.loosenTokenUsdCap, (address(hub), usdc, 21_000_000e8));
        c[k++] = abi.encodeCall(store.loosenDepositorUsdCap, (address(hub), 1_100_000e8));
        c[k++] = abi.encodeCall(store.loosenPoolShareMaxBps, (10_000));
        c[k++] = abi.encodeCall(store.loosenMinPledgeUsd, (M, 1));
        c[k++] = abi.encodeCall(store.loosenPoolShareMaxBpsOf, (M, 10_000));
        c[k++] = abi.encodeCall(store.loosenGateRecoverySeconds, (600));
        c[k++] = abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), gho, 1));
        c[k++] = abi.encodeCall(store.loosenMaxShortfallBps, (2000));
        c[k++] = abi.encodeCall(store.loosenDebtStressRiseBps, (usdc, 100));
        c[k++] = abi.encodeCall(store.setBorrowPriceMaxAge, (address(fUsdc), 1));
        c[k++] = abi.encodeCall(store.setConsistencyToleranceBps, (M, 60));
        c[k++] = abi.encodeCall(store.setFeedAgreementToleranceBps, (usdc, 200));
        c[k++] = abi.encodeCall(store.setPoolRiskFactor, (M, 100));
        c[k++] = abi.encodeCall(store.setFeeRecipient, (alice));
        c[k++] = abi.encodeCall(store.setMaxFlashFeeBps, (20));
        c[k++] = abi.encodeCall(store.setSecondSource, (usdc, ss, ss));
        c[k++] = abi.encodeCall(store.restoreSecondSource, (usdc));
        c[k++] = abi.encodeCall(store.setCachedWindow, (1));
        c[k++] = abi.encodeCall(store.setDisagreementPauseMax, (1));
        c[k++] = abi.encodeCall(store.setTwapWindow, (M, 1800));
        c[k++] = abi.encodeCall(store.setUsdBand, (0.9e8, 1.1e8));
        c[k++] = abi.encodeCall(store.setLiquidationPriceMaxAge, (address(fUsdc), 88_200));
        c[k++] = abi.encodeCall(store.setFeedMaxAge, (address(fUsdc), 88_200));
        c[k++] = abi.encodeCall(store.setGraceDuration, (1));
        c[k++] = abi.encodeCall(store.setGraceHealthFactor, (0.95e18));
        c[k++] = abi.encodeCall(store.setFeedAgreementMarginBps, (1));
        c[k++] = abi.encodeCall(store.setSlippageAllowanceMinBps, (M, 1));
        c[k++] = abi.encodeCall(store.setTokenCollateralFactorBps, (usdc, 1));
        c[k++] = abi.encodeCall(store.setStressFloorUsd, (M, 2));
        c[k++] = abi.encodeCall(store.setInitialMarketParams, (M, mp));
        c[k++] = abi.encodeCall(store.setInitialMarketCaps, (M, 1, 1, 1));
        c[k++] = abi.encodeCall(store.setInitialHubCaps, (address(hub), 1));
        c[k++] = abi.encodeCall(store.setInitialTokenCap, (address(hub), usdt, 1));
        c[k++] = abi.encodeCall(store.setFeed, (address(fUsdc), fd));
        c[k++] = abi.encodeCall(store.setDebtAssetParams, (gho, DebtReserveParams(1)));
        c[k++] = abi.encodeCall(store.setLiquidationExpectations, (address(spoke), 1.1e18, 200));
        c[k++] = abi.encodeCall(store.setSequencer, (address(0), 0));
        c[k++] = abi.encodeCall(store.setCoverageRatioBps, (2000));
        c[k++] = abi.encodeCall(store.grantRole, (GUARDIAN, alice));
        c[k++] = abi.encodeCall(store.revokeRole, (GUARDIAN, emergencyGuardian));
        assert(k == c.length);
    }
}
