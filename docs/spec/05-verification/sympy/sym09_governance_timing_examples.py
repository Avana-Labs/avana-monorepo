# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-141..149 — worked examples of the AvanaTimelock and governance bounds ([2.15] SPEC-GOV-001..015),
recomputed in exact integers from the final rules.

Constants: SHORT_DELAY 43,200; MIN_NORMAL_DELAY 345,600; MAX_DELAY 432,000; GRACE_PERIOD 1,209,600 seconds.
Each check compares the figures a page states with the values the rule gives (residual = sum of squared
differences, 0 when every figure matches).
"""
import sympy as sp
from _common import eq, done

SHORT, MIN_NORMAL, MAX, GRACE = 43_200, 345_600, 432_000, 1_209_600


def eqm(pid, title, lhs, rhs):
    return eq(pid, title, sum((sp.sympify(a) - sp.sympify(b)) ** 2 for a, b in zip(lhs, rhs)), 0)


def required(calls, normal=MAX):
    short_list = {"tightenMarketUsdCap", "disableRoute", "restoreRoute"}
    return SHORT if calls and all(c in short_list for c in calls) else normal


# SYM-141 verifies: SPEC-GOV-001
eqm("SYM-141", "SPEC-GOV-001: [tightenMarketUsdCap, disableRoute] needs 43,200 s; adding loosenTopUpSliceUsd needs 432,000 s and delay 43,200 reverts",
    [required(["tightenMarketUsdCap", "disableRoute"]), required(["tightenMarketUsdCap", "disableRoute", "loosenTopUpSliceUsd"]),
     int(43_200 < required(["tightenMarketUsdCap", "disableRoute", "loosenTopUpSliceUsd"]))],
    [43_200, 432_000, 1])
ready = 1_780_000_000 + 432_000
# SYM-142 verifies: SPEC-GOV-002, SPEC-GOV-013
eqm("SYM-142", "SPEC-GOV-002/013: ready at 1,780,432,000, executable through 1,781,641,599, expired at 1,781,641,600; clean-up at 1,781,000,000 is refused",
    [ready, ready + GRACE - 1, ready + GRACE, int(1_781_000_000 >= ready + GRACE)],
    [1_780_432_000, 1_781_641_599, 1_781_641_600, 0])
cut_exec = 1_780_000_000 + 432_000
# SYM-143 verifies: SPEC-GOV-003, SPEC-GOV-012
eqm("SYM-143", "SPEC-GOV-003/012: cut to 345,600 executes at 1,780,432,000; next upgrade ready at 1,780,777,600, 9 days after; 345,599, 259,200, 432,001, 864,000, 300,000 rejected",
    [cut_exec, cut_exec + 345_600, (cut_exec + 345_600 - 1_780_000_000) // 86_400,
     sum(int(not (MIN_NORMAL <= v <= MAX)) for v in (345_599, 259_200, 432_001, 864_000, 300_000))],
    [1_780_432_000, 1_780_777_600, 9, 5])
# SYM-144 verifies: SPEC-GOV-007, SPEC-GOV-010
eqm("SYM-144", "SPEC-GOV-007/010: disableRoute scheduled at 1,780,000,000 executes no earlier than 1,780,043,200 and no later than 1,781,252,799; expired at 1,781,252,800",
    [1_780_000_000 + SHORT, 1_780_000_000 + SHORT + GRACE - 1, 1_780_000_000 + SHORT + GRACE],
    [1_780_043_200, 1_781_252_799, 1_781_252_800])
active, floor_k, max_k = 3, 1, 32
a1 = active - 1                                  # freeze one (3 - 1 >= 1)
a2 = a1 - 1                                      # removeKeeper of an active keeper (2 - 1 >= 1)
# SYM-145 verifies: SPEC-GOV-008
eqm("SYM-145", "SPEC-GOV-008: 3 keepers, keeperFloor 1, MAX_KEEPERS 32: freeze -> 2, remove -> 1; next freeze reverts (0 < 1); removing the last active one reverts; add -> 2; a 33rd keeper reverts",
    [a1, a2, int(a2 - 1 >= floor_k), int(a2 - 1 >= floor_k), a2 + 1, int(32 + 1 <= max_k)],
    [2, 1, 0, 0, 2, 0])
# SYM-146 verifies: SPEC-GOV-009, SPEC-GOV-011
eqm("SYM-146", "SPEC-GOV-009/011: twap 50 -> 30 ok, then 40 NotStricter, 8 LivenessBound; minOpeningHF 1.10 -> 1.07 ok, 1.06 too large; slippage 100 -> 125 ok, 126 too large",
    [int(10 <= 30 < 50), int(40 < 30), int(8 >= 10), int(110 - 107 <= 3), int(110 - 106 <= 3), int(125 - 100 <= 25), int(126 - 100 <= 25)],
    [1, 0, 0, 1, 0, 1, 0])
cap = 4_000_000 * 10 ** 8
# SYM-147 verifies: SPEC-GOV-011
eqm("SYM-147", "SPEC-GOV-011: cap 4e6 -> 6e6 passes (6e10 <= 6e10); next loosening refused until 1,780,864,000; slice from 0 capped at 600,000e8",
    [int(6_000_000 * 10 ** 8 * 10 ** 4 <= cap * 15_000), 1_780_432_000 + 432_000, int(1_780_700_000 >= 1_780_864_000),
     max(0, cap // 10) * 15_000 // 10 ** 4],
    [1, 1_780_864_000, 0, 600_000 * 10 ** 8])
# SYM-148 verifies: SPEC-GOV-012
eqm("SYM-148", "SPEC-GOV-012: grace HF 0.88 rejected; grace 7,200 ok and 7,201 rejected; twap 9 rejected",
    [int(88 >= 90), int(7_200 <= 7_200), int(7_201 <= 7_200), int(9 >= 10)],
    [0, 1, 0, 0])
r = 259_200
need = lambda k: r + 12 * (k + 1)
# SYM-149 verifies: SPEC-GOV-014, SPEC-GOV-015
eqm("SYM-149", "SPEC-GOV-014/015: k = 3 needs 259,248; k_max 14,399 at 432,000 and 7,199 at 345,600; k = 1 spare 86,376; k = 7,200 needs 345,612; 7,200 transactions at the floor; 43,200 < 3-day reaction",
    [need(3), (432_000 - r) // 12 - 1, (MIN_NORMAL - r) // 12 - 1, MIN_NORMAL - need(1), need(7_199), need(7_200),
     (MIN_NORMAL - r) // 12, int(r > SHORT)],
    [259_248, 14_399, 7_199, 86_376, 345_600, 345_612, 7_200, 1])

done()
