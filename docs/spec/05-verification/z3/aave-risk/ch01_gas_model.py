# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Per-chain gas model of one liquidation (SPEC-CHAIN-001).

MATH-CH-01 verifies: SPEC-CHAIN-001, INV-096, LIQ-087

Avana has no minimum debt on any chain (Q-381). Avana's own keepers liquidate every account and pay the gas, so no
liquidation depends on a keeper's profit, and SPEC-CHAIN-001 states only the gas model, in gas units:

  G(n) = 4,610,000 + 170,000 * n      gas units of one liquidation of an account with n records, flash loan included

The constants are the real-stack calibration of TEST-269 (4 borrowed reserves, the worst case: 4,774,703 gas for 1
record, 7,267,678 for 16), rounded up to the next 10,000. It is used for two things: the record cap per account per
market (16) must keep the largest account within the liquidation gas budget of 7,500,000 (decided 2026-11-14), itself
under half the per-transaction gas limit, 16,777,216 / 2 = 8,388,608, and Avana's keeper gas budget, k liquidations
of at most
k * G(16) gas units. The gas price is an operating input and does not appear here.

Changed on 2026-11-10 (Q-381): MATH-CH-01 used to derive a minimum debt from a keeper break-even in USD (gas price,
ETH price, bonus and swap cost). That derivation is removed; the ID now checks the gas units model above.

Checks (exact integers):
  1. COMPUTED: G(1) = 4,780,000; G(16) = 7,330,000 <= 7,500,000 <= 8,388,608; G(125) = 25,860,000 (an uncapped
     list of 125 records cannot be liquidated in one transaction); G(72) = 16,850,000 exceeds the whole limit; the
     largest n with G(n) <= 7,500,000 is 17 and with G(n) <= 8,388,608 is 22.
  2. PROVED: for every integer 0 <= n <= 16, G(n) <= 7,500,000 (the liquidation gas budget, under half the
     per-transaction limit).
  3. PROVED: four liquidations of accounts within the cap need at most 4 * G(16) gas units; the bound adds one
     G(16) per liquidation, which sizes the keeper gas budget.
"""
import sys
from z3 import Int, Solver, Not, And, unsat

BASE, PER_RECORD, CAP, TX_LIMIT, BUDGET = 4_610_000, 170_000, 16, 16_777_216, 7_500_000
HALF = TX_LIMIT // 2


def gas(n):
    return BASE + PER_RECORD * n


ok = True
figures = [
    ("G(1)", 4_780_000, gas(1)),
    ("G(16)", 7_330_000, gas(CAP)),
    ("G(16) <= liquidation gas budget (7,500,000)", True, gas(CAP) <= BUDGET),
    ("liquidation gas budget <= half the per-transaction limit (8,388,608)", True, BUDGET <= HALF),
    ("G(125)", 25_860_000, gas(125)),
    ("G(125) > per-transaction limit", True, gas(125) > TX_LIMIT),
    ("G(72)", 16_850_000, gas(72)),
    ("G(72) > per-transaction limit", True, gas(72) > TX_LIMIT),
    ("largest n with G(n) <= the budget", 17, (BUDGET - BASE) // PER_RECORD),
    ("largest n with G(n) <= half the limit", 22, (HALF - BASE) // PER_RECORD),
]
for label, stated, actual in figures:
    good = stated == actual
    ok &= good
    print(f"MATH-CH-01 {label}: stated {stated}, computed {actual} -> {'COMPUTED' if good else 'MISMATCH'}")

n = Int("n")
s = Solver()
s.add(n >= 0, n <= CAP, Not(BASE + PER_RECORD * n <= BUDGET))
res = s.check()
print(f"MATH-CH-01 every account within the cap (n <= 16) fits the liquidation gas budget -> {'PROVED' if res == unsat else 'COUNTEREXAMPLE'}")
ok &= res == unsat

ns = [Int(f"n{i}") for i in range(4)]
s = Solver()
within = And(*[And(x >= 0, x <= CAP) for x in ns])
s.add(within, Not(sum(BASE + PER_RECORD * x for x in ns) <= len(ns) * gas(CAP)))
res = s.check()
print(f"MATH-CH-01 keeper gas budget: 4 liquidations within the cap need <= 4 * G(16) gas units -> {'PROVED' if res == unsat else 'COUNTEREXAMPLE'}")
ok &= res == unsat
sys.exit(0 if ok else 1)
