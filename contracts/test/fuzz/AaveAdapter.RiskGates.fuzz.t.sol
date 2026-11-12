// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";
import {RiskSequencerFeed} from "../utils/mocks/RiskModuleMocks.sol";

/// @title AaveAdapterRiskGatesFuzzTest
/// @notice The reviewed RiskModule's gates reached through the Adapter on the real Aave V4 Spoke, over random inputs:
/// the sequencer gate (down, unknown, grace, up), a breaker's recovery window after a breach, the pool-share
/// concentration breaker reading Avana's pool units from the real Collateralization under the Adapter's Lock, and the
/// health check with rescue units excluded. Repay passes in every case.
/// forge-config: default.isolate = false
contract AaveAdapterRiskGatesFuzzTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
    }

    function _tryBorrow(
        uint256 amount
    ) internal returns (bool ok, bytes memory err) {
        uint256 n = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.prank(alice);
        (ok, err) = adapter.call(abi.encodeCall(adapterC.borrow, (MARKET_ID, debtReserveId, amount, alice, d, 0, n)));
    }

    function _repayOne() internal {
        _fund(carol, debtReserveId, 1e18);
        uint256 d = _deadline();
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 1e18, false, d);
    }

    // TEST-275 verifies: REQ-ADAPTER-102, REQ-RISK-081, REQ-PROXY-026, REQ-PROXY-032
    // Sources: 2.10 SPEC-ORC-021 (up, down, unknown, grace)
    /// @notice A borrow passes only when the sequencer feed reports up with a restart older than the grace period:
    /// `SequencerDown()` for down, unknown or unreadable, `SequencerGrace(startedAt + grace)` inside the grace period.
    /// Repay passes in every case.
    function testFuzz_TEST_275_sequencerOutcome(
        int8 answer,
        uint32 sinceRestart,
        uint32 grace,
        bool reverts
    ) public {
        sinceRestart = uint32(bound(sinceRestart, 1, 10 days));
        grace = uint32(bound(grace, 0, 2 days));
        RiskSequencerFeed feed = new RiskSequencerFeed();
        uint256 startedAt = block.timestamp - sinceRestart;
        feed.set(answer, startedAt, reverts);
        rstore.setSequencer(address(feed), grace);
        bool up = !reverts && answer == 0;
        (bool ok, bytes memory err) = _tryBorrow(1e18);
        if (!up) {
            assertFalse(ok, "down refuses");
            assertEq(err, abi.encodeWithSelector(IRiskModuleErrors.SequencerDown.selector), "SequencerDown");
        } else if (sinceRestart < grace) {
            assertFalse(ok, "grace refuses");
            assertEq(
                err, abi.encodeWithSelector(IRiskModuleErrors.SequencerGrace.selector, startedAt + grace), "grace end"
            );
        } else {
            assertTrue(ok, "up passes");
        }
        _repayOne();
    }

    // TEST-028 verifies: REQ-ADAPTER-094, REQ-RISK-065
    /// @notice After a breach recorded at `lastBreach` with nothing latched, borrowing reopens exactly
    /// `gateRecoverySeconds` later; a latched reason refuses whatever the time.
    function testFuzz_TEST_028_breakerRecovery(
        uint32 sinceBreach,
        bool latched
    ) public {
        sinceBreach = uint32(bound(sinceBreach, 0, 7200));
        uint64 at = uint64(block.timestamp - sinceBreach);
        uint32 reasons = latched ? BreakerReasons.MANUAL : 0;
        registry.setLatched(bytes32(MARKET_ID), reasons, at);
        bool recovering = sinceBreach < 1800;
        (bool ok, bytes memory err) = _tryBorrow(1e18);
        if (latched || recovering) {
            uint32 expected = reasons | (recovering ? BreakerReasons.TEMPORARY : 0);
            assertFalse(ok, "breaker refuses");
            assertEq(
                err, abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_ID, expected), "reasons"
            );
        } else {
            assertTrue(ok, "recovered");
        }
        _repayOne();
    }

    // TEST-060 verifies: REQ-COLL-018, REQ-LOCK-016, REQ-RISK-065, SPEC-BRK-002
    // Sources: 5.1 TEST-060 (poolUnits answers the RiskModule while the AaveAdapter holds the Lock)
    /// @notice The concentration breaker reads Avana's pool units from the real Collateralization inside the Adapter's
    /// Lock: a borrow trips `POOL_SHARE` exactly when `units × 10,000 > cap × depth`.
    function testFuzz_TEST_060_poolShareBreaker(
        uint16 capBps,
        uint64 depth
    ) public {
        capBps = uint16(bound(capBps, 1, 9999));
        depth = uint64(bound(depth, 1, 1e15));
        bytes32 key = keccak256(abi.encode(INTEGRATION, pool, bytes32(0)));
        rstore.setPoolShare(key, capBps);
        riskVault.setDepth(depth, true);
        uint256 units = coll.poolUnits(key);
        assertEq(units, UNITS, "Avana's units in the pool");
        bool trips = units * 10_000 > uint256(capBps) * depth;
        (bool ok, bytes memory err) = _tryBorrow(1e18);
        if (trips) {
            assertFalse(ok, "concentration refuses");
            assertEq(
                err,
                abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_ID, BreakerReasons.POOL_SHARE),
                "POOL_SHARE"
            );
        } else {
            assertTrue(ok, "below the cap");
        }
    }

    // TEST-236 verifies: REQ-PROXY-022, SPEC-PROXY-001, REQ-RISK-068, INV-025
    /// @notice With a rescue top-up on the account, a borrow passes when the collateral that is not rescue covers the
    /// debt with a margin, and is refused `HealthFactorTooLow` when only the rescue units would cover it; Aave alone
    /// would admit both.
    function testFuzz_TEST_236_rescueExclusion(
        uint128 rescueUnits,
        uint256 extra
    ) public {
        rescueUnits = uint128(bound(rescueUnits, 1_000_000_000, 4 * uint256(UNITS)));
        riskModule.setRescue(true);
        _pledgeAs(alice, MARKET_ID, rescueUnits);
        riskModule.setRescue(false);
        // Regular CF-weighted collateral $16,000; rescue $1.60 per 1e6 units.
        uint256 regular = 16_000e18;
        uint256 rescue = uint256(rescueUnits) * 16e11;
        extra = bound(extra, 1e18, regular + rescue - 1000e18 - 1e18);
        uint256 debtAfter = 1000e18 + extra;
        (bool ok, bytes memory err) = _tryBorrow(extra);
        if (regular * 1000 >= debtAfter * 1001) {
            assertTrue(ok, "covered without the rescue units");
        } else if (regular * 1001 <= debtAfter * 1000) {
            assertFalse(ok, "only the rescue units cover it");
            assertEq(bytes4(err), IRiskModuleErrors.HealthFactorTooLow.selector, "HealthFactorTooLow");
        }
    }
}
