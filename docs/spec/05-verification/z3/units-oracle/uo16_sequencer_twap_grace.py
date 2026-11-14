# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-73..74 — the sequencer grace period covers every TWAP window ([2.9] REQ-PSTORE-034, [2.10] SPEC-ORC-021).

  an L2 sequencer restarts at t0 (startedAt of the restart round); borrowing reopens at t >= t0 + G, G = gracePeriod
  a time-weighted price read at t over a window W averages [t - W, t]
  windows governed by the store: Wm (the market's consistency check), Ws (recorded pool-TWAP second source),
  Wb (standby pool-TWAP second source); an oracle-network source has no window (0)
  rule:  G >= max(Wm, Ws, Wb), checked after the write of setSequencer (G), setTwapWindow and setInitialMarketParams
  (Wm), setSecondSource (Ws, Wb); useStandbySecondSource and restoreSecondSource move no window
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, And, Or, Not, If
from _common import prove, witness, note, finish

t0, t, G, Wm, Ws, Wb = Ints('t0 t G Wm Ws Wb')
G2, Wm2, Ws2, Wb2 = Ints('G2 Wm2 Ws2 Wb2')
dom = [t0 >= 1, t >= 0, G >= 0, Wm >= 0, Ws >= 0, Wb >= 0, G <= 7200]


def mx(*xs):
    out = xs[0]
    for x in xs[1:]:
        out = If(x > out, x, out)
    return out


def rule(g, wm, ws, wb):
    return g >= mx(wm, ws, wb)


reopened = t >= t0 + G

# ---------------------------------------------------------------------------
# MATH-UO-73 verifies: REQ-PSTORE-034, SPEC-ORC-021
prove('MATH-UO-73a',
      'with G >= max(Wm, Ws, Wb), every window read once borrowing reopens (t >= t0 + G) starts at or after the '
      'restart: no consistency check and no pool-TWAP second source (recorded or standby) averages the outage',
      dom + [rule(G, Wm, Ws, Wb), reopened],
      And(t - Wm >= t0, t - Ws >= t0, t - Wb >= t0))
# MATH-UO-73 verifies: REQ-PSTORE-034
witness('MATH-UO-73b',
        'wrong reading (grace checked against the market window only): G = 1,800 >= Wm = 1,800, a standby over '
        'Wb = 2,400 switched in reads 600 s of the outage at the first borrow after the restart',
        dom + [G >= Wm, Wb > G, G == 1800, Wm == 1800, Wb == 2400, t == t0 + G, t - Wb < t0])
# MATH-UO-73 verifies: REQ-PSTORE-034
prove('MATH-UO-73c',
      'the rule is inductive over the setters: from a state that satisfies it, each setter that writes one side and '
      'checks the rule after its write (setSequencer: G; setTwapWindow, setInitialMarketParams: Wm; setSecondSource: '
      'Ws and Wb; a guardian switch or restore: nothing) leaves a state that satisfies it or reverts',
      dom + [G2 >= 0, Wm2 >= 0, Ws2 >= 0, Wb2 >= 0, rule(G, Wm, Ws, Wb),
             Or(And(Wm2 == Wm, Ws2 == Ws, Wb2 == Wb, rule(G2, Wm, Ws, Wb)),
                And(G2 == G, Ws2 == Ws, Wb2 == Wb, Wm2 <= G2),
                And(G2 == G, Wm2 == Wm, Ws2 <= G2, Wb2 <= G2),
                And(G2 == G, Wm2 == Wm, Ws2 == Ws, Wb2 == Wb))],
      rule(G2, Wm2, Ws2, Wb2))
# MATH-UO-73 verifies: REQ-PSTORE-034
witness('MATH-UO-73d',
        'wrong reading (setSecondSource checks only the recorded window): a standby over 3,601 s is recorded under a '
        '3,600 s grace and breaks the rule without any setter reverting',
        dom + [G2 >= 0, Wm2 >= 0, Ws2 >= 0, Wb2 >= 0, rule(G, Wm, Ws, Wb), G2 == G, Wm2 == Wm, Ws2 <= G2,
               G == 3600, Wb2 == 3601, Not(rule(G2, Wm2, Ws2, Wb2))])
# MATH-UO-73 verifies: REQ-PSTORE-034, REQ-PSTORE-023
prove('MATH-UO-73e',
      'the rule never makes a valid window unlistable: every window W <= 7,200 s (the largest grace) has a grace in '
      '[600, 7,200] covering it, max(600, W)',
      [Wm >= 0, Wm <= 7200],
      And(mx(600, Wm) >= 600, mx(600, Wm) <= 7200, rule(mx(600, Wm), Wm, 0, 0)))

# ---------------------------------------------------------------------------
# MATH-UO-74 verifies: REQ-PSTORE-034
def ok(g, wm, ws, wb):
    return g >= max(wm, ws, wb)


note('MATH-UO-74', 'REQ-PSTORE-034 example (Base, market window 1,800 s, USDC standby pool TWAP 2,400 s)',
     f'setSequencer 2,399: {"passes" if ok(2399, 1800, 0, 2400) else "OutOfBounds"}; '
     f'setSequencer 2,400: {"passes" if ok(2400, 1800, 0, 2400) else "OutOfBounds"}; '
     f'then setTwapWindow 2,401: {"passes" if ok(2400, 2401, 0, 2400) else "OutOfBounds"}; '
     f'launch (grace 3,600, window 1,800, no pool-TWAP source): {"passes" if ok(3600, 1800, 0, 0) else "OutOfBounds"}')

finish()
