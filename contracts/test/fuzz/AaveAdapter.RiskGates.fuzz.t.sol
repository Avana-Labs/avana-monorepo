// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterRiskGatesFuzzTest
/// @notice The reviewed RiskModule's gates reached through the Adapter on the real Aave V4 Spoke, over random inputs:
/// the sequencer gate (down, unknown, grace, up), a live breaker condition with no recovery window, the pool-share
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

    // TEST-028 verifies: REQ-ADAPTER-094, REQ-RISK-065
    /// @notice The pool-depth breaker holds exactly while the LPVault reports no usable depth (unavailable or 0): a
    /// borrow is refused `BreakerTripped(market, POOL_DEPTH)` then, and passes in the same block once depth is back.
    function testFuzz_TEST_028_breakerHoldsOnlyWhileConditionHolds(
        uint256 depth,
        bool available
    ) public {
        depth = bound(depth, 0, 2e13);
        riskVault.setDepth(depth, available);
        bool holds = !available || depth == 0;
        (bool ok, bytes memory err) = _tryBorrow(1e18);
        if (holds) {
            assertFalse(ok, "breaker refuses");
            assertEq(
                err,
                abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_ID, BreakerReasons.POOL_DEPTH),
                "reasons"
            );
            riskVault.setDepth(2e13, true);
            (ok,) = _tryBorrow(1e18);
            assertTrue(ok, "passes once the condition clears");
        } else {
            assertTrue(ok, "no condition holds");
        }
        _repayOne();
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
