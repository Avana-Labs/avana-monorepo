"""Arithmetic safety of the custody formulas on 256-bit words (T-21, SPEC-UNIT-006).

A checked uint256 operation reverts iff its exact integer result is at least 2^256
(or below 0 for a subtraction). Each check below proves, over unbounded integers,
that the exact result of a product or sum the spec computes with plain checked
arithmetic stays below 2^256 inside the stated bounds, and that each storage
narrowing (uint128) is lossless. Products of bounded variables are decided by Z3's
nonlinear arithmetic engine; this is equivalent to the bit-precise statement and
avoids bit-blasting 256-bit multipliers.
"""
from z3 import Ints, And, Not
from common import prove, satisfiable, summary

U256 = 2 ** 256


def main():
    V0, rem, L, p, a, x, tc, addCap, n = Ints("V0 rem L price8 amount x totalCredited addCap n")
    nonneg = [v >= 0 for v in (V0, rem, L, p, a, x, tc, addCap, n)]
    # FV-CUS-21 verifies: SPEC-BACK-005, SPEC-BACK-003, SPEC-BACK-009, SPEC-UNIT-004, SPEC-UNIT-005, SPEC-UNIT-006, REQ-VAULT-012, REQ-VAULT-110
    prove("FV-CUS-21-charge-mul", "T-21 SPEC-BACK-005 V0 * remainingUnits < 2^256 (V0 < 2^128, units < 2^120)",
          V0 * rem < U256, nonneg + [V0 < 2 ** 128, rem < 2 ** 120])
    prove("FV-CUS-21-book-mul", "T-21 SPEC-BACK-003 L * max(price8, floor) < 2^184 (L < 2^120, price8 < 2^64)",
          L * p < 2 ** 184, nonneg + [L < 2 ** 120, p < 2 ** 64])
    prove("FV-CUS-21-credit-add", "T-21 totalCredited + L < 2^121 (totalCredited <= supply < 2^120, L < 2^120)",
          tc + L < 2 ** 121, nonneg + [tc < 2 ** 120, L < 2 ** 120])
    prove("FV-CUS-21-uint128", "T-21 credited (L <= 2^120 - 1) and usdCharge (< 2^128) fit uint128",
          And(L < 2 ** 128, V0 < 2 ** 128), nonneg + [L < 2 ** 120, V0 < 2 ** 128])
    prove("FV-CUS-21-addcap", "T-21 SPEC-UNIT-005 addCap * 10^d < 2^120 for addCap < 2^40 - 1 and d <= 18",
          addCap * 10 ** 18 < 2 ** 120, nonneg + [addCap < 2 ** 40 - 1])
    prove("FV-CUS-21-aavevalue", "T-21 SPEC-UNIT-004 Aave value n * price8 * 10^(18-d) < 2^256 (n < 2^120, price8 < 2^64, d >= 6)",
          n * p * 10 ** 12 < U256, nonneg + [n < 2 ** 120, p < 2 ** 64])
    sl, cb, ch = Ints("sliceUsd chargeBefore usdChargeAdded")
    # FV-CUS-21 verifies: SPEC-BACK-013, SPEC-BACK-014, REQ-COLL-015, REQ-COLL-016
    prove("FV-CUS-21-rescue-mul", "T-21 SPEC-BACK-014 L * sliceUsd < 2^248 (L < 2^120, sliceUsd < 2^128)",
          L * sl < 2 ** 248, nonneg + [sl >= 0, L < 2 ** 120, sl < 2 ** 128])
    prove("FV-CUS-21-rebase-add", "T-21 SPEC-BACK-013 currentUsdCharge + usdCharge < 2^129 and the rebased units credited + added < 2^121, so the sums never overflow before the InvalidCharge and LiquidityAboveBound checks",
          And(cb + ch < 2 ** 129, rem + L < 2 ** 121),
          nonneg + [cb >= 0, ch >= 0, cb < 2 ** 128, ch < 2 ** 128, rem < 2 ** 120, L < 2 ** 120])
    satisfiable("FV-CUS-21-pending-mul", "T-21 witness: amount * x in SPEC-BACK-012 can reach 2^256 inside the bounds, so the 512-bit mulDiv is required",
                And(nonneg + [a < 2 ** 248, x < 2 ** 120, a * x >= U256]), show=[a, x])
    return summary("fv_arith")


if __name__ == "__main__":
    raise SystemExit(main())
