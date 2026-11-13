// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {Test} from "forge-std/Test.sol";

/// @title SettlementMathPropertiesFuzzTest
/// @notice Algebraic properties of every SettlementMath formula of 2.11, checked against independent restatements over
/// listing-range inputs: exact values, rounding direction, monotonicity, bounds and the identities the waterfall
/// relies on. Each property fails if a rounding is flipped, a bound is moved by one or a term is dropped.
/// forge-config: default.fuzz.runs = 10000
contract SettlementMathPropertiesFuzzTest is Test {
    uint256 internal constant BPS = 10_000;

    function _ceil(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @notice SPEC-LIQ-001: `bNet = 10⁴ + ⌊(b − 10⁴)(10⁴ − lf)/10⁴⌋`, never above `b`, non-decreasing in `b`,
    /// non-increasing in `lf`, and 10⁴ when `b ≤ 10⁴` or `lf ≥ 10⁴`.
    // TEST-198 verifies: SPEC-LIQ-001
    function testFuzz_TEST_198_netBonus(
        uint256 b,
        uint256 lf,
        uint256 db,
        uint256 dlf
    ) public pure {
        b = bound(b, 0, 30_000);
        lf = bound(lf, 0, 12_000);
        db = bound(db, 0, 1000);
        dlf = bound(dlf, 0, 1000);
        uint256 n = SettlementMath.netBonus(b, lf);
        if (b <= BPS || lf >= BPS) {
            assertEq(n, BPS, "no bonus term");
        } else {
            assertEq(n, BPS + (b - BPS) * (BPS - lf) / BPS, "formula");
            assertLe(n, b, "never above b");
        }
        assertGe(SettlementMath.netBonus(b + db, lf), n, "non-decreasing in b");
        assertLe(SettlementMath.netBonus(b, lf + dlf), n, "non-increasing in lf");
    }

    /// @notice SPEC-LIQ-003: `s = min(allow, ⌊10⁴(bNet − 10⁴)/bNet⌋)`; `bNet (10⁴ − s) ≥ 10⁸`; the next larger `s`
    /// breaks that bound unless the allowance binds (the rounding is down, not to nearest).
    // TEST-198 verifies: SPEC-LIQ-003, SPEC-LIQ-016, PROP-017
    function testFuzz_TEST_198_effectiveSlippage(
        uint256 bNet,
        uint256 allow
    ) public pure {
        bNet = bound(bNet, 0, 3 * BPS);
        allow = bound(allow, 0, 9999);
        uint256 s = SettlementMath.effectiveSlippage(bNet, allow);
        if (bNet <= BPS) {
            assertEq(s, 0, "no bonus, no slippage");
            return;
        }
        uint256 raw = BPS * (bNet - BPS) / bNet;
        assertEq(s, raw < allow ? raw : allow, "formula");
        assertGe(bNet * (BPS - s), BPS * BPS, "covers D");
        if (raw < allow) assertLt(bNet * (BPS - s - 1), BPS * BPS, "largest such s");
    }

    /// @notice SPEC-LIQ-019: `sLeg = min(9,999, s + min(maxShortfallBps, ⌊maxShortfall × 10⁴ / V⌋))`, at least `s`,
    /// non-decreasing in `maxShortfall`, `s` itself when the budget or `V` is 0.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-111
    function testFuzz_TEST_233_legSlippage(
        uint256 s,
        uint256 budget,
        uint256 value,
        uint256 cap,
        uint256 more
    ) public pure {
        s = bound(s, 0, 9999);
        budget = bound(budget, 0, 1e30);
        value = bound(value, 0, 1e30);
        cap = bound(cap, 0, 5000);
        more = bound(more, 0, 1e30);
        uint256 sLeg = SettlementMath.legSlippage(s, budget, value, cap);
        uint256 relax = budget == 0 || value == 0 ? 0 : (budget >= value ? BPS : budget * BPS / value);
        if (relax > cap) relax = cap;
        uint256 expected = s + relax > 9999 ? 9999 : s + relax;
        assertEq(sLeg, expected, "formula");
        assertGe(sLeg, s, "never below s");
        assertGe(SettlementMath.legSlippage(s, budget + more, value, cap), sLeg, "monotone in the budget");
        assertEq(SettlementMath.legSlippage(s, 0, value, cap), s, "no budget, no relaxation");
    }

    /// @notice `s_P = min(allowance, 30)`.
    // TEST-232 verifies: SPEC-LIQ-014
    function testFuzz_TEST_232_pendingSlippage(
        uint256 allow
    ) public pure {
        allow = bound(allow, 0, 9999);
        assertEq(SettlementMath.pendingSlippage(allow), allow < 30 ? allow : 30);
    }

    /// @notice SPEC-LIQ-004: `V = ⌊c Pc 10^dd / (10^dv Pdebt)⌋` exactly, linear up to rounding in `c`, and the unit
    /// value `U` is the ceiling of one raw unit's value (never below the floor value of one unit).
    // TEST-198 verifies: SPEC-LIQ-004, SPEC-LIQ-005
    function testFuzz_TEST_198_valuesAndUnits(
        uint256 c,
        uint256 pc,
        uint256 pd,
        uint8 dv,
        uint8 dd
    ) public pure {
        c = bound(c, 0, 1e30);
        pc = bound(pc, 1, 1e12);
        pd = bound(pd, 1, 1e12);
        dv = uint8(bound(dv, 0, 18));
        dd = uint8(bound(dd, 0, 18));
        uint256 v = SettlementMath.seizedValue(c, pc, dv, dd, pd);
        assertEq(v, c * pc * 10 ** dd / (10 ** dv * pd), "V");
        uint256 u = SettlementMath.unitValue(pc, dv, dd, pd);
        assertEq(u, _ceil(pc * 10 ** dd, 10 ** dv * pd), "U is the ceiling of one unit");
        assertGe(u * 1, SettlementMath.seizedValue(1, pc, dv, dd, pd), "U >= floor value of one unit");
        assertEq(SettlementMath.legValue(c, pc, dv, dd, pd), v, "a leg values like the seizure");
        assertLe(SettlementMath.seizedValue(c / 2, pc, dv, dd, pd) * 2, v, "halves never exceed the whole");
    }

    /// @notice SPEC-LIQ-005: `minRec = max(0, ⌈V(10⁴ − s)/10⁴⌉ − U − ε)`, rounding the slippage term up, never above
    /// `V`, non-decreasing in `V` and non-increasing in `s`, `U` and `ε`.
    // TEST-198 verifies: SPEC-LIQ-005, PROP-018, PROP-048
    function testFuzz_TEST_198_recoveryFloor(
        uint256 v,
        uint256 s,
        uint256 u,
        uint256 eps,
        uint256 dv
    ) public pure {
        v = bound(v, 0, 1e30);
        s = bound(s, 0, 9999);
        u = bound(u, 0, 1e20);
        eps = bound(eps, 0, 1e20);
        dv = bound(dv, 0, 1e20);
        uint256 f = SettlementMath.recoveryFloor(v, s, u, eps);
        uint256 term = _ceil(v * (BPS - s), BPS);
        assertEq(f, term > u + eps ? term - u - eps : 0, "formula");
        assertLe(f, v, "never above V");
        assertGe(SettlementMath.recoveryFloor(v + dv, s, u, eps), f, "monotone in V");
        if (s < 9999) assertLe(SettlementMath.recoveryFloor(v, s + 1, u, eps), f, "antitone in s");
        assertLe(SettlementMath.recoveryFloor(v, s, u + 1, eps), f, "antitone in U");
    }

    /// @notice SPEC-LIQ-018: a leg is dust exactly when `Vleg ≤ Uleg`; a non-dust leg's minimum is
    /// `max(1, ⌈Vleg(10⁴ − sLeg)/10⁴⌉ − Uleg − ⌊ε/n'⌋)`, at least 1 and at most `Vleg`.
    // TEST-232 verifies: SPEC-LIQ-018, REQ-SWAP-100, INV-083
    function testFuzz_TEST_232_legMinimum(
        uint256 vLeg,
        uint256 sLeg,
        uint256 uLeg,
        uint256 eps,
        uint256 n
    ) public pure {
        vLeg = bound(vLeg, 0, 1e30);
        sLeg = bound(sLeg, 0, 9999);
        uLeg = bound(uLeg, 0, 1e20);
        eps = bound(eps, 0, 1e20);
        n = bound(n, 1, 4);
        assertEq(SettlementMath.isDustLeg(vLeg, uLeg), vLeg <= uLeg, "dust rule");
        uint256 m = SettlementMath.legMinOut(vLeg, sLeg, uLeg, eps, n);
        uint256 term = _ceil(vLeg * (BPS - sLeg), BPS);
        uint256 cut = uLeg + eps / n;
        assertEq(m, term > cut ? term - cut : 1, "formula, never 0");
        assertGe(m, 1, "at least 1");
        if (vLeg > uLeg) assertLe(m, vLeg, "never above the leg's value");
    }

    /// @notice SPEC-LIQ-019 and SPEC-LIQ-022: with `R_f = max(R, minRec)`, `shortfall = max(minRec − R, g)` where
    /// `g = max(0, D + A + B − Kf − R)`; `g` never exceeds the floor gap while `D ≤ Kf`; the waterfall splits
    /// `S = A + kr + B` exactly; and `keeperOut = Kf + R + shortfall − D − A − B` conserves the debt asset.
    // TEST-198 verifies: SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-LIQ-022, INV-035, INV-036, PROP-069
    function testFuzz_TEST_198_waterfallIdentities(
        uint256 v,
        uint256 d,
        uint256 extra,
        uint256 r,
        uint256 minRec,
        uint256 share
    ) public pure {
        v = bound(v, 0, 1e30);
        d = bound(d, 0, 1e30);
        extra = bound(extra, 0, 1e30);
        r = bound(r, 0, 1e30);
        minRec = bound(minRec, 0, v);
        share = bound(share, 0, BPS);
        SettlementMath.Payouts memory p = _checkPayouts(v, d, r, minRec, share);
        _checkTopUp(d, extra, r, minRec, p);
    }

    function _checkPayouts(
        uint256 v,
        uint256 d,
        uint256 r,
        uint256 minRec,
        uint256 share
    ) internal pure returns (SettlementMath.Payouts memory p) {
        uint256 rf = SettlementMath.recoveryWithFloor(minRec, r);
        assertEq(rf, r > minRec ? r : minRec, "R_f");
        p = SettlementMath.payouts(v, d, rf, share);
        uint256 sur = rf > d ? rf - d : 0;
        uint256 gain = v > d ? v - d : 0;
        assertEq(p.surplus, sur, "S");
        assertEq(p.oracleGain, gain, "G");
        uint256 fee = gain * share / BPS;
        assertEq(p.avanaFee, fee < sur ? fee : sur, "A");
        assertEq(p.avanaFee + p.keeperReward + p.borrowerSurplus, sur, "A + kr + B = S");
        assertEq(p.borrowerSurplus, sur > gain ? sur - gain : 0, "B = max(0, S - G)");
    }

    function _checkTopUp(
        uint256 d,
        uint256 extra,
        uint256 r,
        uint256 minRec,
        SettlementMath.Payouts memory p
    ) internal pure {
        uint256 g = SettlementMath.roundingGap(d, p.avanaFee, p.borrowerSurplus, d + extra, r);
        uint256 floorGap = minRec > r ? minRec - r : 0;
        assertLe(g, floorGap, "g <= floor gap while D <= Kf");
        uint256 shortfall = SettlementMath.shortfallTopUp(minRec, r, g, type(uint256).max);
        assertEq(shortfall, floorGap > g ? floorGap : g, "shortfall = max(floor gap, g)");
        uint256 out = SettlementMath.keeperPayout(d + extra, r + shortfall, d, p.avanaFee, p.borrowerSurplus);
        assertEq(d + extra + r + shortfall, d + p.avanaFee + p.borrowerSurplus + out, "conservation");
        assertGe(out, extra, "the unused funding returns");
    }

    /// @notice SPEC-LIQ-015: the exact cap `φ × 10⁴ ≤ maxFlashFeeBps × F`, for caps below and above 10⁴.
    // TEST-198 verifies: SPEC-LIQ-015, REQ-FLASH-002
    function testFuzz_TEST_198_flashPremiumWithinCap(
        uint256 premium,
        uint256 amount,
        uint256 cap
    ) public pure {
        premium = bound(premium, 0, 1e30);
        amount = bound(amount, 0, 1e30);
        cap = bound(cap, 0, 20_000);
        assertEq(SettlementMath.flashPremiumWithinCap(premium, amount, cap), premium * BPS <= cap * amount, "exact");
    }

    /// @notice SPEC-LIQ-020: `cap = ⌊max(0, ⌊V(10⁴ − s)/10⁴⌋ − U − ε) × 10⁴ / (10⁴ + m)⌋`, its premium at the cap
    /// rate fits in `Vnet`, `x = min(debt, cap)` and `assetOut = R − x − φ`.
    // TEST-198 verifies: SPEC-LIQ-020, INV-089
    function testFuzz_TEST_198_deleverageSizing(
        uint256 v,
        uint256 s,
        uint256 u,
        uint256 eps,
        uint256 m,
        uint256 debt
    ) public pure {
        v = bound(v, 0, 1e30);
        s = bound(s, 0, 9999);
        u = bound(u, 0, 1e20);
        eps = bound(eps, 0, 1e20);
        m = bound(m, 0, 100);
        debt = bound(debt, 1, 1e30);
        uint256 net = v * (BPS - s) / BPS;
        net = net > u + eps ? net - u - eps : 0;
        uint256 cap = SettlementMath.deleverageCap(v, s, u, eps, m);
        assertEq(cap, net * BPS / (BPS + m), "formula");
        assertLe(cap + _ceil(cap * m, BPS), net, "x plus its premium at the cap rate fits Vnet");
        uint256 x = debt < cap ? debt : cap;
        if (x == 0) return;
        assertEq(SettlementMath.deleverageRepayment(debt, cap, 0), x, "x = min(debt, cap)");
        uint256 phi = x * m / BPS;
        assertEq(SettlementMath.deleverageAssetOut(x + phi + 7, x, phi), 7, "assetOut = R - x - phi");
    }
}
