# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-32..36: principal-capped collection (SPEC-BACK-008, INV-033).

Uniswap v3 periphery NonfungiblePositionManager (Solidity 0.7.6, unchecked uint128):
  decreaseLiquidity(l): (p0, p1) = pool.burn(l)                 principal, rounded down in core
                        owed_i += uint128(p_i) + uint128(fee_i)  NFPM per-token owed (wraps)
  collect(max_i):       want_i = min(max_i, owed_i)
                        got_i  = pool.collect(want_i) = min(want_i, poolOwed_i)
                        owed_i -= want_i                          (subtracts the request, not got_i)
Pool position (NFPM, tickLower, tickUpper) is shared by every NFPM position in the range:
  pool.burn adds p_i to poolOwed_i, so poolOwed_i >= p_i right after the burn.
LPVault (SPEC-BACK-008): collect(max_i = p_i) with p_i the decreaseLiquidity return values, for a seizure,
a reconciliation, a deleverage release and a partial removal alike.
"""
from z3 import BitVec, BitVecVal, ULT, ULE, UGT, UGE, If, And, Or, Not, ZeroExt, Extract
from _common import check, done

W = 128
owed, p, fees, poolOwed = [BitVec(n, W) for n in ["owed", "p", "fees", "poolOwed"]]

def umin(a, b): return If(ULT(a, b), a, b)
def wide(x): return ZeroExt(2, x)

# NFPM arithmetic exactly as compiled (wraps at 2^128)
owed1 = owed + (p + fees)
pool1 = poolOwed + p
want = umin(p, owed1)
got = umin(want, pool1)
owed2 = owed1 - want

no_wrap = [ULT(wide(owed) + wide(p) + wide(fees), wide(BitVecVal(2**128 - 1, W)) + 1),
           ULT(wide(poolOwed) + wide(p), wide(BitVecVal(2**128 - 1, W)) + 1)]

# MATH-ST-32 verifies: SPEC-BACK-008, INV-033, LIQ-023, Q-061
check("MATH-ST-32",
      "principal-capped collect returns exactly the principal p (no more, no less) when owed sums fit uint128",
      no_wrap + [Or(got != p, want != p)],
      "PROVED")

# MATH-ST-33 verifies: SPEC-BACK-008, INV-033, FEE-POST-001, Q-061
check("MATH-ST-33",
      "depositor's owed after seizure == owed before + fees accrued (fees untouched)",
      no_wrap + [owed2 != owed + fees],
      "PROVED")

# The pool can hold fewer fee wei than the NFPM records (NFPM comment: 'a few less wei ...
# due to rounding down in core'). Even then the LPVault's principal collect is exact,
# because the burn credits p to the pool position in the same call.
# MATH-ST-34 verifies: SPEC-BACK-008, INV-033, Q-061
check("MATH-ST-34",
      "principal collect is exact even if the pool's fee balance is short (poolOwed < owed)",
      no_wrap + [ULT(poolOwed, owed), got != p],
      "PROVED")

# Full seizure (last liquidity removed): NFPM folds fees into owed during decreaseLiquidity,
# so the later collect (which skips the fee update when liquidity == 0) loses nothing.
# Same arithmetic as ST-33; recorded separately for Q-061's last-liquidity clause.
# MATH-ST-35 verifies: SPEC-BACK-008, FEE-POST-001, Q-061, Q-134
check("MATH-ST-35",
      "after the last liquidity is removed the depositor can still collect owed + fees",
      no_wrap + [Or(owed2 != owed + fees, ULT(owed2, fees))],
      "PROVED")

# Bound: owed + p + fees must stay below 2^128 (3.4e20 whole tokens at 18 decimals,
# 3.4e32 at 6). Without it NFPM's unchecked add wraps and collect returns less than p.
# MATH-ST-36 verifies: SPEC-BACK-008, Q-061
check("MATH-ST-36",
      "without the uint128 bound the NFPM add wraps and collect < principal (counterexample, unreachable in practice)",
      [UGT(p, BitVecVal(0, W)), got != p],
      "COUNTEREXAMPLE", show=[owed, p, fees, poolOwed])

done()
