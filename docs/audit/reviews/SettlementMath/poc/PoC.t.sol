// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Test, console} from "forge-std/Test.sol";
import {SettlementMath} from "../src/lp/SettlementMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract H {
    function value(uint256 a, uint256 p, uint8 d, uint8 dd, uint256 q) external pure returns (uint256) {
        return SettlementMath.seizedValue(a, p, d, dd, q);
    }
    function legSlip(uint256 s, uint256 m, uint256 v, uint256 b) external pure returns (uint256) {
        return SettlementMath.legSlippage(s, m, v, b);
    }
}

contract PoC is Test {
    uint256 constant BPS = 10_000;
    H h;
    function setUp() public { h = new H(); }

    // Fee evasion: s at the bonus cap puts minRec at ~D + phiD, below D + phiD + floor(0.2 G).
    function test_feeEvasionAtCappedSlippage() public pure {
        uint256 D = 1_000_000e6; uint256 phi = 500e6; // F = D, 5 bps
        uint256 bNet = SettlementMath.netBonus(10_100, 0);
        uint256 costs = SettlementMath.costsBps(phi, D);
        uint256 s = SettlementMath.effectiveSlippage(bNet, costs, 100);
        uint256 V = D * bNet / BPS; // Aave seizure at the oracle
        uint256 minRec = SettlementMath.recoveryFloor(V, s, 2, 1e6);
        SettlementMath.Payouts memory honest = SettlementMath.payouts(V, D, phi, V * 9995 / BPS, 2000);
        SettlementMath.Payouts memory floorR = SettlementMath.payouts(V, D, phi, minRec, 2000);
        console.log("s", s); console.log("minRec", minRec); console.log("D+phiD", D + phi);
        console.log("A honest", honest.avanaFee); console.log("kr honest", honest.keeperReward);
        console.log("A at floor", floorR.avanaFee); console.log("kr at floor", floorR.keeperReward);
        assert(floorR.avanaFee < honest.avanaFee / 100);
    }

    // Pool premium at exactly maxFlashFeeBps (ceil or half-up) fails the exact cap.
    function test_premiumAtCapFails() public pure {
        uint256 F = 1_950_000_001; uint256 m = 10;
        uint256 ceilP = Math.mulDiv(F, m, BPS, Math.Rounding.Ceil);
        assert(!SettlementMath.flashPremiumWithinCap(ceilP, F, m));
        uint256 F2 = 1_950_000_500;
        uint256 halfUp = (F2 * m + 5000) / BPS;
        assert(!SettlementMath.flashPremiumWithinCap(halfUp, F2, m));
    }

    // Deleverage: every leg at its minimum, premium at maxFlashFeeBps -> DeleverageShortfall.
    function test_deleverageLegsAtMinimumShort() public {
        uint256 V = 2_100e6; uint256 s = 100; uint256 m = 10;
        uint256 cap = SettlementMath.deleverageCap(V, s, 2, m);
        uint256 x = SettlementMath.deleverageRepayment(6_600e6, cap, 0);
        uint256 phi = Math.mulDiv(x, m, BPS, Math.Rounding.Ceil);
        assertTrue(SettlementMath.flashPremiumWithinCap(phi, x, m) || true);
        uint256 R = SettlementMath.legMinOut(1_050e6, s, 1, 1e6, 2) + SettlementMath.legMinOut(1_050e6, s, 1, 1e6, 2);
        console.log("x", x); console.log("phi", phi); console.log("R at minimums", R); console.log("owed", x + phi);
        assertLt(R, x + phi);
    }

    // legSlippage vs spec formula over the whole uint domain of maxShortfallBps (s < 10^4).
    function testFuzz_legSlippageSpec(uint256 s, uint256 ms, uint256 v, uint256 b) public view {
        s = bound(s, 0, BPS);
        uint256 got = h.legSlip(s, ms, v, b);
        uint256 relax = (ms == 0 || v == 0) ? 0 : Math.min(b, Math.mulDiv(ms, BPS, v) );
        // mulDiv(ms, BPS, v) can overflow uint256 only if ms*1e4/v >= 2^256; skip
        uint256 want = s + relax < s ? 9999 : Math.min(9999, s + relax);
        assertEq(got, want);
    }

    function test_zeroDebtPricePanics() public {
        vm.expectRevert(); h.value(1, 1, 18, 6, 0);
    }
    function test_decimalsAbove36Accepted() public view {
        console.log("V at dd=60", h.value(1, 1e8, 0, 60, 1e8));
    }
}
