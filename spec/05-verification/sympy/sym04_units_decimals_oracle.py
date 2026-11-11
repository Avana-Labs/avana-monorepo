# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-30..34 — vault-token decimals, LPOracle 8-decimal price, Aave value, sqrtPriceX96 from prices
([2.4] SPEC-UNIT-001, 003, 004, 005; [2.10] SPEC-ORC-004, 005, 008, 009, 010).

One base unit = one unit of liquidity, d = (d0 + d1)/2; stablecoin valuation prices capped at $1.
Aave V4 value math: value(amount) = amount * price8 / 10^decimals (toValue, 8-dec USD price).
Chainlink answer a_i with f_i decimals: P_i = a_i / 10^f_i USD per whole token.
Exact reals; the served price8 = isqrt(4 v0 v1) - 1 rounds this ideal value down (rounding: MATH-UO-01..05, MATH-UO-10..21).
"""
import sympy as sp
from _common import eq, info, done

L, a0, a1, P0, P1 = sp.symbols("L a0 a1 P0 P1", positive=True)
d, d0, d1, f0, f1 = sp.symbols("d d0 d1 f0 f1", real=True)

p0, p1 = P0 / 10 ** d0, P1 / 10 ** d1                 # USD per raw unit
v_raw = 2 * sp.sqrt(p0 * p1)                          # USD per raw unit of liquidity (SYM-22)

# ---------- SYM-30: d = (d0+d1)/2 is the unique d with whole-token value 2 sqrt(P0 P1) ----------
whole = v_raw * 10 ** d
# SYM-30 verifies: SPEC-UNIT-001, SPEC-UNIT-003, SPEC-ORC-005
eq("SYM-30a", "value of one whole vault token = 2 sqrt(P0 P1) 10^(d - (d0+d1)/2)",
   whole, 2 * sp.sqrt(P0 * P1) * 10 ** (d - (d0 + d1) / 2))
sol = sp.solve(sp.Eq(d - (d0 + d1) / 2, 0), d)
# SYM-30 verifies: SPEC-UNIT-001, SPEC-ORC-005
eq("SYM-30b", "whole-token value == 2 sqrt(P0 P1) solves to d = (d0 + d1)/2 (unique)", sol[0], (d0 + d1) / 2)
# SYM-30 verifies: SPEC-UNIT-003, SPEC-ORC-005
eq("SYM-30c", "at peg P0 = P1 = $1 a whole token is worth exactly $2",
   whole.subs(d, (d0 + d1) / 2).subs({P0: 1, P1: 1}), 2)
rows = []
for (x0, x1) in [(6, 6), (6, 18), (18, 18), (6, 8), (6, 9), (18, 8)]:
    s = x0 + x1
    if s % 2 == 0:
        rows.append(f"d0={x0:>2} d1={x1:>2}: d = {s // 2}  whole token = $2.000")
    else:
        lo, hi = s // 2, s // 2 + 1
        vlo = sp.N(2 * 10 ** sp.Rational(lo * 2 - s, 2), 4)
        vhi = sp.N(2 * 10 ** sp.Rational(hi * 2 - s, 2), 4)
        rows.append(f"d0={x0:>2} d1={x1:>2}: (d0+d1)/2 = {sp.Rational(s, 2)} not an integer -> d={lo}: ${vlo}, d={hi}: ${vhi}")
# SYM-30 verifies: SPEC-UNIT-001
info("SYM-30d", "integer requirement: d0 + d1 must be even (every launch pair is; an odd sum reverts OddDecimalSum)",
     "\n".join(rows))

# ---------- SYM-31: Aave toValue on raw vault units equals the direct LP value ----------
n = sp.symbols("n", positive=True)                    # raw vault-token units = units of L
price8 = 10 ** 8 * 2 * sp.sqrt(P0 * P1)               # LPOracle answer for one whole token
aave_value = n * price8 / 10 ** d / 10 ** 8
# SYM-31 verifies: SPEC-UNIT-004, SPEC-UNIT-003, SPEC-ORC-008
eq("SYM-31", "Aave value(n units) = n x price8 / 10^d equals n x 2 sqrt(p0 p1) (raw) iff d = (d0+d1)/2",
   aave_value.subs(d, (d0 + d1) / 2), n * v_raw)

# ---------- SYM-32: LPOracle 8-dec answer from two Chainlink answers ----------
P0f, P1f = a0 / 10 ** f0, a1 / 10 ** f1
ans = 10 ** 8 * 2 * sp.sqrt(P0f * P1f)
# SYM-32 verifies: SPEC-ORC-008
eq("SYM-32a", "price8 = 2 sqrt(a0 a1) 10^(8 - (f0+f1)/2)", ans, 2 * sp.sqrt(a0 * a1) * 10 ** (8 - (f0 + f1) / 2))
# SYM-32 verifies: SPEC-ORC-008
eq("SYM-32b", "with 8-dec feeds (f0 = f1 = 8): price8 = 2 sqrt(a0 a1)", ans.subs({f0: 8, f1: 8}), 2 * sp.sqrt(a0 * a1))
# stable legs capped at stableCeilingUsd = $1 (SPEC-ORC-004): v = min(q, 1e8) for 8-decimal prices
g = sp.symbols("a_gho", positive=True)
# SYM-32 verifies: SPEC-ORC-004
info("SYM-32c", "market with a USD stable leg (SPEC-ORC-004)", "ideal price = 2 sqrt(min(q_stable, 1e8) x v_X) for 8-dec prices; "
     "equals 2 sqrt(q_stable v_X) while the stable is <= $1 and 2 sqrt(1e8 v_X) above.")

# ---------- SYM-33: sqrtPriceX96 from two USD feeds ----------
Q = sp.Integer(2) ** 96
P_raw = (P0f / 10 ** d0) / (P1f / 10 ** d1)           # raw token1 per raw token0
sqrtX96 = Q * sp.sqrt(a0 * 10 ** (f1 + d1) / (a1 * 10 ** (f0 + d0)))
# SYM-33 verifies: SPEC-ORC-009
eq("SYM-33a", "sqrtPriceX96 = 2^96 sqrt(a0 10^(f1+d1) / (a1 10^(f0+d0))) squares to P_raw",
   (sqrtX96 / Q) ** 2, P_raw)
# SYM-33 verifies: SPEC-ORC-009
eq("SYM-33b", "8-dec feeds: sqrtPriceX96 = 2^96 sqrt(a0/a1 x 10^(d1-d0))",
   sqrtX96.subs({f0: 8, f1: 8}), Q * sp.sqrt(a0 / a1 * 10 ** (d1 - d0)))
# amounts at that sqrt price, valued at the same feeds, give the oracle value (ties SYM-22 to the feeds)
sq = sqrtX96 / Q
x, y = L / sq, L * sq
# SYM-33 verifies: SPEC-ORC-009, SPEC-ORC-007
eq("SYM-33c", "amounts at the feed-implied sqrtPrice, valued at the feeds: x p0 + y p1 == 2 L sqrt(p0 p1)",
   x * P0f / 10 ** d0 + y * P1f / 10 ** d1, 2 * L * sp.sqrt(P0f * P1f / 10 ** (d0 + d1)))
# SYM-33 verifies: SPEC-ORC-009, SPEC-ORC-010
eq("SYM-33d", "swapping token order inverts the ratio: sqrtX96' = 2^192 / sqrtX96 (orientation, MATH-UO-13)",
   Q * sp.sqrt(1 / P_raw), Q ** 2 / sqrtX96)
# SYM-33 verifies: SPEC-ORC-010
info("SYM-33e", "reference ticks at $1/$1 (tick = log_1.0001 P_raw)",
     f"d0 = d1: tick 0;  d0=18,d1=6 (e.g. GHO/USDC): tick = {sp.N(sp.log(sp.Rational(1, 10**12)) / sp.log(sp.Rational(10001, 10000)), 10)}"
     f";  d0=6,d1=18: tick = {sp.N(sp.log(10**12) / sp.log(sp.Rational(10001, 10000)), 10)}")

# ---------- SYM-34: per-raw-unit value scales: whole-token price8 and the Hub addCap unit ----------
# SYM-34 verifies: SPEC-UNIT-005, SPEC-UNIT-004
info("SYM-34", "unit summary at peg",
     "1 raw vault unit = 1 unit of L = $2 x 10^-d; 1 whole token (10^d units) = $2; price8 = 2e8;\n"
     "Hub addCap in whole tokens, sized at stressFloorUsd = $1 per whole token.")

done()
