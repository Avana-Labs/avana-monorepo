# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-70..71 — the markDebtFree gas floor and the per-record effect of the seizure order
([2.3] REQ-COLL-040, SPEC-BACK-006, SPEC-BACK-005, SPEC-BACK-014).

  gas floor:  the Spoke read forwards F = A - floor(A / 64) of the gas A available at the call (EIP-150);
              a read that runs out of gas returns with floor(A / 64) left. markDebtFree reverts
              InsufficientGas when a failed read leaves less than DEBT_MARK_GAS_FLOOR = 50,000.
  order:      a debit walks the seizure list in stored order; each debited record releases
              chargeBefore - ceil(V0 * remaining / U0) (SPEC-BACK-005) and caps its rescue units at its credit
              (SPEC-BACK-014), so the units debited are fixed by the call and the released charge and the rescue
              units kept depend on which record carries the debit.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, And, If, Implies
from _common import prove, witness, note, finish

FLOOR = 50_000

# ---------------------------------------------------------------------------
A, F, left, cost = Ints('available forwarded leftAfterOOG readCost')
call = [A >= 0, F == A - A / 64, left == A / 64]
# MATH-UO-70 verifies: REQ-COLL-040
prove('MATH-UO-70a',
      'a failed read that leaves at least 50,000 gas was given at least 63 x 50,000 = 3,150,000 gas, so a read '
      'costing at most that cannot have failed from starvation',
      call + [left >= FLOOR], F >= 63 * FLOOR)
# MATH-UO-70 verifies: REQ-COLL-040
prove('MATH-UO-70b',
      'a read that needs more gas than it was given (starved) leaves under 50,000 whenever its cost is at most '
      '3,150,000: the call reverts InsufficientGas instead of keeping the mark',
      call + [cost <= 63 * FLOOR, F < cost], left < FLOOR)
# MATH-UO-70 verifies: REQ-COLL-040
witness('MATH-UO-70c',
        'wrong reading (floor 1,000): a read costing 600,000 starved at 500,000 forwarded leaves over 1,000 gas, so the '
        'call would return and keep the mark',
        call + [cost == 600_000, F < cost, F >= 500_000, left >= 1_000])

# ---------------------------------------------------------------------------
# Two records A (head) and B with their own bases; a debit of x units, 0 < x <= creditA.
uA, vA, cA, uB, vB, cB, x, remA, remB, relA, relB = Ints('U0a V0a creditA U0b V0b creditB x remA remB relA relB')
base = [uA >= 1, vA >= 1, uB >= 1, vB >= 1, cA >= 1, cA <= uA, cB >= 1, cB <= uB, x >= 1, x <= cA, x <= cB]
chargeA_before, chargeB_before = Ints('chargeA chargeB')
ceil = lambda q, num, den: [q * den >= num, q * den < num + den]
rel = (base + ceil(chargeA_before, vA * cA, uA) + ceil(chargeB_before, vB * cB, uB)
       + ceil(remA, vA * (cA - x), uA) + ceil(remB, vB * (cB - x), uB)
       + [relA == chargeA_before - remA, relB == chargeB_before - remB])
# MATH-UO-71 verifies: SPEC-BACK-006, SPEC-BACK-005
witness('MATH-UO-71a',
        'the same x units debited from A or from B release different charges when the bases differ (A pledged at '
        '$2.00 per whole token, B at $1.00): the order decides the cap room released, not the units',
        rel + [uA == 5_000_000_000, vA == 1_000_000_000_000, cA == 4_000_000_000,
               uB == 6_000_000_000, vB == 600_000_000_000, cB == 6_000_000_000, x == 1_000_000_000, relA != relB])
# MATH-UO-71 verifies: SPEC-BACK-006, SPEC-BACK-005
prove('MATH-UO-71b', 'with equal bases (V0a = V0b, U0a = U0b) and equal credit the release does not depend on the order',
      rel + [uA == uB, vA == vB, cA == cB], relA == relB)
rA, rA2, rB = Ints('rescueA rescueA2 rescueB')
# MATH-UO-71 verifies: SPEC-BACK-006, SPEC-BACK-014
prove('MATH-UO-71c',
      'debiting a record without rescue units leaves the account rescue units unchanged; debiting one with rescue '
      'units can only lower them, to at least min(rescue, credit after the debit)',
      base + [rA >= 0, rA <= cA, rB == 0, rA2 == If(rA < cA - x, rA, cA - x)],
      And(rA2 <= rA, rA2 >= 0, Implies(rA <= cA - x, rA2 == rA)))

note('MATH-UO-71d', 'SPEC-BACK-006 example (re-credit keeps NFT 42 at the head)',
     'NFT 42: U0 5,000,000,000, V0 1,000,000,000,000, credit 4,000,000,000 after a partial seizure; '
     'NFT 7 re-credited to 6,000,000,000 behind it; a debit of 1,000,000,000 takes NFT 42 first and releases '
     f'{(10**12 * 4_000_000_000 + 5_000_000_000 - 1) // 5_000_000_000 - (10**12 * 3_000_000_000 + 5_000_000_000 - 1) // 5_000_000_000:,} '
     '(USD 8 decimals) of NFT 42\'s basis')

finish()
