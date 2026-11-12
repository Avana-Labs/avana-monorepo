// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapShortfallFuzzTest
/// @notice The caller's shortfall top-up fuzzed (2.11 SPEC-LIQ-019, REQ-SWAP-025, REQ-SWAP-101, REQ-SWAP-111,
/// REQ-SWAP-112): for any route crash rate and budget, every leg runs at `sLeg = min(9,999, s + min(maxShortfallBps,
/// ⌊maxShortfall × 10⁴ / V⌋))`; the call settles exactly when some route meets that relaxed minimum and the floor gap
/// is within the budget, pulling exactly `max(minRec − R, g)` from the caller and never more than `maxShortfall`; an
/// unused budget is never pulled; without a budget nothing relaxes.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapShortfallFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _sLeg(
        uint256 budget,
        uint256 value
    ) internal pure returns (uint256) {
        uint256 relax = budget == 0 || value == 0 ? 0 : (budget >= value ? BPS : budget * BPS / value);
        if (relax > MAX_SHORTFALL_BPS) relax = MAX_SHORTFALL_BPS;
        uint256 s = SLIPPAGE_BPS + relax;
        return s > 9999 ? 9999 : s;
    }

    /// @notice Any crash rate from 0.88 to 1.00 on both routes and any budget up to 400 USDC.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-025, REQ-SWAP-101, REQ-SWAP-111, INV-034
    function testFuzz_TEST_233_relaxedLegsAndExactTopUp(
        uint256 rateBps,
        uint256 budget
    ) public {
        rateBps = bound(rateBps, 8800, 10_000);
        budget = bound(budget, 0, 400e6);
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        (uint256 a0, uint256 a1) = _released(975e6);
        uint256 v = _valueOf(975e6, P_VAULT, PRICE_UNIT, 6);
        uint256 legMin = _usdtLegMinOut(a1, _sLeg(budget, v), 1);
        uint256 routed = a1 * rateBps / 10_000;
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = budget;
        _fund(usdc, keeper, 1950e6 + budget);
        uint256 before = usdc.balanceOf(keeper);
        vm.prank(keeper);
        try lvs.liquidate(p) returns (LiquidationResult memory r) {
            assertGe(routed, legMin, "settled only when the relaxed minimum was met");
            assertEq(r.recovered, a0 + routed, "R");
            uint256 floorGap = r.minOut > r.recovered ? r.minOut - r.recovered : 0;
            assertGe(r.shortfall, floorGap, "the floor gap is topped up");
            assertLe(r.shortfall, budget, "never above the budget");
            assertEq(usdc.balanceOf(keeper), before - r.callerFunds - r.shortfall + r.keeperOut, "pulled exactly");
            if (floorGap == 0) assertLe(r.shortfall, 1e6, "an unused budget is never pulled beyond the rounding gap");
        } catch (bytes memory reason) {
            bytes4 s = bytes4(reason);
            if (routed < legMin) {
                assertEq(s, ILPVaultSwapErrors.NoRouteAvailable.selector, "no route meets the relaxed minimum");
            } else {
                assertEq(s, ILPVaultSwapErrors.RecoveryBelowFloor.selector, "the gap exceeds the budget");
            }
        }
    }

    /// @notice With no budget no leg relaxes: any rate below the unrelaxed minimum reverts `NoRouteAvailable`, any rate
    /// at or above it settles with no shortfall.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-060
    function testFuzz_TEST_233_noBudgetNoRelaxation(
        uint256 rateBps
    ) public {
        rateBps = bound(rateBps, 9800, 10_000);
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        (, uint256 a1) = _released(975e6);
        uint256 legMin = _usdtLegMinOut(a1, SLIPPAGE_BPS, 1);
        if (a1 * rateBps / 10_000 < legMin) {
            _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.NoRouteAvailable.selector));
        } else {
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
            assertEq(r.shortfall, 0, "no shortfall without a budget");
        }
    }
}
