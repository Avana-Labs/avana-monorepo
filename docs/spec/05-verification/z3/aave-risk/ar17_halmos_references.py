# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-90..92 — Reference formulas of three Halmos checks.

Each Halmos check below proves that the Solidity code returns a reference formula `R` for every input in its bit
widths; this script proves the inequalities of the property on `R` over the same inputs, so the two parts together
give the property. `R` is the shape `Math.mulDiv(x, y, s, Ceil)` computes when the product fits 256 bits:
`R = floor(x y / s) + (x y mod s > 0 ? 1 : 0)`, encoded here with an explicit quotient and remainder.

  MATH-AR-90  contracts/test/halmos/RiskModule.halmos.t.sol  check_PROP_030_chargeCoversFloorFormula
              (SPEC-CAP-001 usdCharge at d = 6; PROP-030)
  MATH-AR-91  contracts/test/halmos/Collateralization.halmos.t.sol  check_PROP_028_exitChargeIndependentOfSplitFormula
              (SPEC-BACK-005 remaining charge; PROP-028)
  MATH-AR-92  contracts/test/halmos/RiskModule.halmos.t.sol  check_PROP_067_rescueValueRoundsUpFormula
              (SPEC-CF-005 rescue value E at CF 3,120, d = 6; PROP-067)

The inequalities are proved for every natural number (the upper bounds are used only for the no-wrap items `b` and
`d`), so they hold over the Halmos input ranges. The no-wrap items justify the checks' assumption
`mulmod(x, y, 2^256 - 1) == x * y`: below `2^256 - 1` both sides are the exact product.
"""
from z3 import Ints, If, And
from _common import prove, finish

B256 = 2**256


def ceil_shape(x, y, s, tag):
    """(R, hyps): R = floor(x y / s) + (x y mod s > 0), for x, y >= 0 and s >= 1, with fresh quotient and remainder."""
    q, m = Ints(f'{tag}_quot {tag}_rem')
    # q >= 0 follows from x y >= 0 and m < s; it is stated to help the solver and removes no case.
    hyps = [x * y == q * s + m, m >= 0, m < s, q >= 0]
    return q + If(m > 0, 1, 0), hyps


# ---------------------------------------------------------------------------
# MATH-AR-90  usdCharge = R(units, max(price8, floor), 10^6) covers the floor and the price.
# The booking price is a variable equal to max(price8, floor), so the product u x p has no if-then-else inside.
u, a, b, p = Ints('units price8 floor bookPrice')
D6 = 10**6
r90, h90 = ceil_shape(u, p, D6, 'chg')
base90 = [u >= 0, a >= 0, b >= 0, p == If(a > b, a, b)] + h90
# Asked in one query, the goal of 90d timed out at 120 s (z3 4.13.0); it is proved in three steps: R is at least
# the exact value at the booking price (90a), that value is at least the value at the floor and at the price
# (90c), and the two chain (90d).
# MATH-AR-90 verifies: SPEC-CAP-001, SPEC-CAP-006, INV-028
prove('MATH-AR-90a', 'R x 10^6 >= units x bookPrice (R rounds up)', base90, r90 * D6 >= u * p)
prove('MATH-AR-90c', 'bookPrice = max(price8, floor): units x bookPrice >= units x floor and >= units x price8',
      [u >= 0, a >= 0, b >= 0, p >= a, p >= b], And(u * p >= u * b, u * p >= u * a))
prove('MATH-AR-90d', 'from 90a and 90c: R x 10^6 >= units x floor and R x 10^6 >= units x price8',
      base90 + [r90 * D6 >= u * p, u * p >= u * b, u * p >= u * a], And(r90 * D6 >= u * b, r90 * D6 >= u * a))
prove('MATH-AR-90b', 'units < 2^40, price8 and floor < 2^32: units x max(price8, floor) < 2^256 - 1 and R x 10^6 < 2^256',
      base90 + [u < 2**40, a < 2**32, b < 2**32], And(u * p < B256 - 1, r90 * D6 < B256))

# ---------------------------------------------------------------------------
# MATH-AR-91  remainingCharge(V0, r, U0) = R(V0, r, U0): monotone in r, at most V0, 0 at r = 0, V0 at r = U0.
v, n, r1, r2 = Ints('V0 U0 r1 r2')
c1, h1 = ceil_shape(v, r1, n, 'rem1')
c2, h2 = ceil_shape(v, r2, n, 'rem2')
base91 = [v >= 0, n >= 1, r2 >= 0, r2 <= r1, r1 <= n] + h1 + h2
zero, hz = ceil_shape(v, 0, n, 'rem0')
full, hf = ceil_shape(v, n, n, 'remU')
# MATH-AR-91 verifies: SPEC-BACK-005, SPEC-BACK-013, SPEC-CAP-004, INV-027
prove('MATH-AR-91a', 'r2 <= r1 <= U0: R(r2) <= R(r1) (a later exit never raises the remaining charge)', base91, c2 <= c1)
prove('MATH-AR-91b', 'r1 <= U0: R(r1) <= V0', base91, c1 <= v)
prove('MATH-AR-91c', 'R(0) = 0 and R(U0) = V0 (the last exit releases exactly what remains)',
      [v >= 0, n >= 1] + hz + hf, And(zero == 0, full == v))
prove('MATH-AR-91d', 'V0, U0 < 2^64, r <= U0: V0 x r < 2^256 - 1',
      base91 + [v < 2**64, n < 2**64], v * r1 < B256 - 1)

# ---------------------------------------------------------------------------
# MATH-AR-92  E = R(units, price8 x 3120 x 1e18, 10^10) rounds up; 0 when units or price8 is 0.
eu, ep = Ints('rescueUnits rescuePrice8')
w = ep * 3120 * 10**18
D10 = 10**10
e92, h92 = ceil_shape(eu, w, D10, 'E')
e_code = If(And(eu > 0, ep > 0), e92, 0)
base92 = [eu >= 0, ep >= 0] + h92
# MATH-AR-92 verifies: SPEC-CF-005, INV-082
prove('MATH-AR-92a', 'E x 10^10 >= units x price8 x 3120 x 1e18 (E is 0 when units or price8 is 0, else R)',
      base92, e_code * D10 >= eu * ep * 3120 * 10**18)
prove('MATH-AR-92b', 'units, price8 < 2^40: price8 x 3120 x 1e18 < 2^112, units x that < 2^256 - 1, E x 10^10 < 2^256',
      base92 + [eu < 2**40, ep < 2**40], And(w < 2**112, eu * w < B256 - 1, e_code * D10 < B256))

finish()
