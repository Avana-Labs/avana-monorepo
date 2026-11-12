// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistrySafetyEvents} from "../../src/policy/market-registry/IMarketRegistrySafetyEvents.sol";
import {BreakerReasons, BreakerScope} from "../../src/policy/market-registry/types/Breaker.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {MarketDef} from "../../src/types/MarketDef.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Breaker latches and breach times bit by bit: each of the 32 reason bits through `recordBreach`, the
/// market/debt scope boundary of a key, combined reasons and their event order, manual trips on markets of every
/// status, resets against every overlap of live and latched reasons, and the clean slate after a debt reserve's
/// removal.
contract MarketRegistryBreakerMatrixUnitTest is MarketRegistryFixture {
    uint256 internal marketId;
    address internal vt;
    bytes32 internal mKey;
    bytes32 internal dKey;

    function setUp() public {
        _setUpWorld();
        (marketId, vt,) = _activeMarket();
        mKey = bytes32(marketId);
        dKey = keccak256(abi.encode(address(spoke), GHO_RESERVE));
    }

    function _breach(
        bytes32 key,
        uint32 reasons
    ) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(address(rm));
        registry.recordBreach(key, reasons);
        logs = vm.getRecordedLogs();
    }

    // TEST-228 verifies: REQ-MREG-026, REQ-MREG-025, SPEC-BRK-007, SPEC-BRK-008, Q-399
    // Sources: 5.1 TEST-228
    // Every one of the 32 reason bits alone: a security bit latches and emits BreakerLatched only; a temporary bit
    // records the time and emits GateBreached only; any other bit (MANUAL included) changes nothing and emits nothing.
    function test_TEST_228_everyReasonBitAlone() public {
        vm.warp(7777);
        for (uint256 b = 0; b < 32; ++b) {
            uint256 snap = vm.snapshotState();
            uint32 bit = uint32(1 << b);
            Vm.Log[] memory logs = _breach(mKey, bit);
            (uint32 latched, uint64 last) = registry.marketBreaker(marketId);
            if (bit & BreakerReasons.SECURITY != 0) {
                assertEq(latched, bit, "security bit latches");
                assertEq(last, 0, "no breach time for a security bit");
                assertEq(logs.length, 1);
                assertEq(logs[0].topics[0], IMarketRegistrySafetyEvents.BreakerLatched.selector);
                assertEq(logs[0].topics[1], bytes32(uint256(BreakerScope.Market)));
                assertEq(logs[0].topics[2], mKey);
                assertEq(abi.decode(logs[0].data, (uint32)), bit);
            } else if (bit & BreakerReasons.TEMPORARY != 0) {
                assertEq(latched, 0, "temporary bit never latches");
                assertEq(last, 7777);
                assertEq(logs.length, 1);
                assertEq(logs[0].topics[0], IMarketRegistrySafetyEvents.GateBreached.selector);
                assertEq(logs[0].topics[1], mKey);
                (uint32 reasons, uint64 at) = abi.decode(logs[0].data, (uint32, uint64));
                assertEq(reasons, bit);
                assertEq(at, 7777);
            } else {
                assertEq(latched, 0, "other bit latches nothing");
                assertEq(last, 0, "other bit records no time");
                assertEq(logs.length, 0, "other bit emits nothing");
            }
            vm.revertToState(snap);
        }
    }

    // TEST-228 verifies: REQ-MREG-026, REQ-MREG-025
    // The security and temporary halves of one report: BreakerLatched first with the latched set, then GateBreached
    // with only the temporary bits.
    function test_TEST_228_combinedReportEmitsBothInOrder() public {
        vm.warp(10_000);
        uint32 all = type(uint32).max;
        Vm.Log[] memory logs = _breach(dKey, all);
        assertEq(logs.length, 2);
        assertEq(logs[0].topics[0], IMarketRegistrySafetyEvents.BreakerLatched.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(BreakerScope.DebtReserve)));
        assertEq(abi.decode(logs[0].data, (uint32)), BreakerReasons.SECURITY);
        assertEq(logs[1].topics[0], IMarketRegistrySafetyEvents.GateBreached.selector);
        (uint32 temp, uint64 at) = abi.decode(logs[1].data, (uint32, uint64));
        assertEq(temp, BreakerReasons.TEMPORARY);
        assertEq(at, 10_000);
        (uint32 latched, uint64 last) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, BreakerReasons.SECURITY);
        assertEq(last, 10_000);
    }

    // TEST-228 verifies: REQ-MREG-025, REQ-CONFIG-006
    // A key at or below 2^32 - 1 is a market key; any larger key is a debt key.
    function test_TEST_228_scopeBoundaryOfAKey() public {
        bytes32[4] memory keys =
            [bytes32(0), bytes32(uint256(type(uint32).max)), bytes32(uint256(type(uint32).max) + 1), dKey];
        BreakerScope[4] memory want =
            [BreakerScope.Market, BreakerScope.Market, BreakerScope.DebtReserve, BreakerScope.DebtReserve];
        for (uint256 i = 0; i < keys.length; ++i) {
            vm.expectEmit(address(registry));
            emit IMarketRegistrySafetyEvents.BreakerLatched(want[i], keys[i], BreakerReasons.ISSUER);
            vm.prank(address(rm));
            registry.recordBreach(keys[i], BreakerReasons.ISSUER);
        }
    }

    // TEST-228 verifies: REQ-MREG-026, SPEC-BRK-007
    // Each temporary breach moves the time forward; a later security-only report leaves it.
    function test_TEST_228_breachTimeFollowsTheLatestTemporaryReport() public {
        vm.warp(100);
        _breach(mKey, BreakerReasons.ORACLE);
        vm.warp(250);
        _breach(mKey, BreakerReasons.POOL_DEPTH);
        assertEq(registry.lastBreachAt(mKey), 250);
        vm.warp(900);
        _breach(mKey, BreakerReasons.DEFICIT);
        assertEq(registry.lastBreachAt(mKey), 250, "security report keeps the time");
        (, uint64 last) = registry.marketBreaker(marketId);
        assertEq(last, 250);
        // The debt key of the same Spoke is independent.
        assertEq(registry.lastBreachAt(dKey), 0);
    }

    // TEST-228 verifies: REQ-MREG-026
    // A report adding a security reason emits the whole latched set; one adding none emits no BreakerLatched.
    function test_TEST_228_latchedEventCarriesTheWholeSet() public {
        _breach(mKey, BreakerReasons.ISSUER);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.BreakerLatched(
            BreakerScope.Market, mKey, BreakerReasons.ISSUER | BreakerReasons.CONFIG_DRIFT
        );
        vm.prank(address(rm));
        registry.recordBreach(mKey, BreakerReasons.CONFIG_DRIFT | BreakerReasons.ISSUER);
        Vm.Log[] memory logs = _breach(mKey, BreakerReasons.ISSUER | BreakerReasons.MANUAL);
        assertEq(logs.length, 0);
    }

    // TEST-228 verifies: REQ-MREG-025, Q-241
    // A manual trip works on a market of any known status and adds MANUAL to what is already latched; a repeated trip
    // emits the same set again.
    function test_TEST_228_manualTripOnEveryKnownStatus() public {
        _breach(mKey, BreakerReasons.DEFICIT);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.BreakerLatched(
            BreakerScope.Market, mKey, BreakerReasons.DEFICIT | BreakerReasons.MANUAL
        );
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(marketId);
        vm.expectEmit(address(registry));
        emit IMarketRegistrySafetyEvents.BreakerLatched(
            BreakerScope.Market, mKey, BreakerReasons.DEFICIT | BreakerReasons.MANUAL
        );
        vm.prank(aaveGuardian);
        registry.tripMarketBreaker(marketId);
        // Registered, Offboarding, Cancelled and Closed markets can be tripped too.
        (uint256 reg,,) = _listMarket2();
        assertEq(uint8(registry.getMarket(reg).status), uint8(MarketStatus.Registered));
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(reg);
        vm.prank(address(timelock));
        registry.cancelRegistration(reg);
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(reg);
        vm.prank(address(timelock));
        registry.setMarketOffboarding(marketId);
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(marketId);
        vm.warp(block.timestamp + 5 days);
        registry.closeMarket(marketId);
        vm.prank(emergencyGuardian);
        registry.tripMarketBreaker(marketId);
        (uint32 latched,) = registry.marketBreaker(reg);
        assertEq(latched, BreakerReasons.MANUAL);
    }

    function _listMarket2() internal returns (uint256 id2, address vt2, RegistryLPOracleMock o2) {
        PositionShape memory wide = PositionShape(ShapeKind.TickRange, -100, 100);
        (vt2, o2) = _deployTokenAndOracle(registry.marketCount() + 1, wide);
        MarketDef memory d = _marketDef(vt2, address(o2));
        d.shape = wide;
        vm.prank(address(timelock));
        id2 = registry.listCollateralMarket(d);
    }

    // TEST-228 verifies: REQ-MREG-025, SPEC-BRK-008, ATTACK-139, Q-241, Q-399
    // A reset succeeds exactly when no latched security reason still holds; otherwise it reverts with exactly the
    // reasons that are latched, live and security, and the latch is kept. Temporary and manual reasons never block.
    function testFuzz_TEST_228_resetBlockedByExactlyTheLiveLatchedSecurityReasons(
        uint32 latchedSeed,
        uint32 live,
        bool manual
    ) public {
        uint32 latched = latchedSeed & BreakerReasons.SECURITY;
        if (latched != 0) _breach(mKey, latched);
        if (manual) {
            vm.prank(emergencyGuardian);
            registry.tripMarketBreaker(marketId);
            latched |= BreakerReasons.MANUAL;
        }
        rm.setLive(marketId, live);
        uint32 still = live & latched & BreakerReasons.SECURITY;
        vm.prank(aaveGuardian);
        if (latched == 0) {
            vm.expectRevert(IMarketRegistryErrors.NothingToReset.selector);
        } else if (still != 0) {
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ConditionStillHolds.selector, mKey, still));
        } else {
            vm.expectEmit(address(registry));
            emit IMarketRegistrySafetyEvents.BreakerReset(BreakerScope.Market, mKey, aaveGuardian);
        }
        registry.resetMarketBreaker(marketId);
        (uint32 after_,) = registry.marketBreaker(marketId);
        assertEq(after_, still != 0 ? latched : 0);
    }

    // TEST-228 verifies: REQ-MREG-025, SPEC-BRK-008, ATTACK-139
    // The same rule on a debt key, read from the RiskModule's live debt reasons of that reserve.
    function testFuzz_TEST_228_debtResetFollowsTheLiveDebtReasons(
        uint32 latchedSeed,
        uint32 live
    ) public {
        uint32 latched = latchedSeed & BreakerReasons.SECURITY;
        vm.assume(latched != 0);
        _breach(dKey, latched);
        rm.setLiveDebt(address(spoke), GHO_RESERVE, live);
        uint32 still = live & latched;
        vm.prank(emergencyGuardian);
        if (still != 0) {
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ConditionStillHolds.selector, dKey, still));
        }
        registry.resetDebtBreaker(address(spoke), GHO_RESERVE);
        (uint32 after_,) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(after_, still != 0 ? latched : 0);
    }

    // TEST-228 verifies: REQ-MREG-025, Q-241
    // A reset of a debt key with nothing latched reports NothingToReset whether or not the reserve exists.
    function test_TEST_228_resetWithNothingLatchedNeedsNoReserve() public {
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.NothingToReset.selector);
        registry.resetDebtBreaker(alice, 1234);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.NothingToReset.selector);
        registry.resetMarketBreaker(1234);
    }

    // TEST-228 verifies: REQ-MREG-010, REQ-MREG-025, Q-397
    // Removing a debt reserve clears its latch and breach time with the record; a trip then reports the reserve unknown,
    // and a re-enabled reserve starts clean.
    function test_TEST_228_removalClearsTheDebtLatch() public {
        // A Spoke-wide debt reserve with no live market settling into it: a fresh registry world without the market.
        _setUpWorld();
        dKey = keccak256(abi.encode(address(spoke), GHO_RESERVE));
        vm.warp(4242);
        _breach(dKey, BreakerReasons.DEFICIT | BreakerReasons.ORACLE);
        vm.prank(emergencyGuardian);
        registry.tripDebtBreaker(address(spoke), GHO_RESERVE);
        (uint32 latched, uint64 last) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, BreakerReasons.DEFICIT | BreakerReasons.MANUAL);
        assertEq(last, 4242);
        vm.prank(address(timelock));
        registry.removeDebtReserve(address(spoke), GHO_RESERVE);
        (latched, last) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, 0);
        assertEq(last, 0);
        assertEq(registry.lastBreachAt(dKey), 0);
        vm.prank(emergencyGuardian);
        vm.expectRevert(
            abi.encodeWithSelector(IMarketRegistryErrors.UnknownDebtReserve.selector, address(spoke), GHO_RESERVE)
        );
        registry.tripDebtBreaker(address(spoke), GHO_RESERVE);
        vm.prank(address(timelock));
        registry.enableDebtReserve(address(spoke), _ghoDef());
        (latched, last) = registry.debtBreaker(address(spoke), GHO_RESERVE);
        assertEq(latched, 0);
        assertEq(last, 0);
    }

    // TEST-228 verifies: REQ-MREG-025, REQ-MREG-026
    // The views never revert, for any market id, Spoke or key.
    function testFuzz_TEST_228_breakerViewsNeverRevert(
        uint256 anyId,
        address anySpoke,
        uint256 anyReserve,
        bytes32 anyKey
    ) public view {
        (uint32 a, uint64 b) = registry.marketBreaker(anyId);
        (uint32 c, uint64 d) = registry.debtBreaker(anySpoke, anyReserve);
        uint64 e = registry.lastBreachAt(anyKey);
        assertEq(uint256(a) + b + c + d + e, 0);
    }
}
