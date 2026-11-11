# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-34..38 — the one-sided backing check, reconciliation shortfall, pending settlement and
the seizure list ([2.3] SPEC-BACK-006, SPEC-BACK-009, SPEC-BACK-011, SPEC-BACK-012; [2.4] REQ-VTOKEN-016).

Market state (vault-token base units, unbounded integers; bit widths are covered in MATH-UO-29/30):
  TC   totalCredited[vt]       P    pending[vt].units       Y    vt.totalSupply()
  gap = TC + P - Y  (SPEC-BACK-009), required >= 0 at the end of every transaction
Operations
  Adapter call (pledge, re-credit, withdrawal, partial removal, repay with collateral): moves TC and Y
      by the same amount m (mint +m / burn -m), and may reconcile s units (TC -= s, P += s);
      the Adapter requires Y <= TC + P and gapAfter == gapBefore
  orphan burnSeized u: Y -= u with no settlement (a non-conforming LPVaultSwap)
  settleSeizure u: requires supplyBefore - supplyAfter == u (the Adapter burned u), then TC -= u
  settlePending x (0 < x <= P): any burn b by the caller, then require Y + x <= TC + P; P -= x
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, Int, And, Or, If, Not, Implies
from _common import prove, witness, finish

TC, P, Y, m, s, u, b, x = Ints('totalCredited pendingUnits totalSupply moved reconciled u burned x')
gap = TC + P - Y
st = [TC >= 0, P >= 0, Y >= 0, gap >= 0]

# ---------------------------------------------------------------------------
# MATH-UO-34  gap >= 0 is preserved by every operation; Adapter calls leave it unchanged.
TC1, P1, Y1 = TC + m - s, P + s, Y + m           # m > 0 mint, m < 0 burn
# MATH-UO-34 verifies: SPEC-BACK-009, REQ-VTOKEN-016
prove('MATH-UO-34a', 'Adapter call (mint or burn m with the matching credit change, reconcile s): gap unchanged and Y <= TC + P holds after',
      st + [s >= 0, s <= TC, TC + m >= s, Y + m >= 0],
      And(TC1 + P1 - Y1 == gap, Y1 <= TC1 + P1))
# MATH-UO-34 verifies: SPEC-BACK-009, REQ-VTOKEN-016
prove('MATH-UO-34b', 'orphan burnSeized of u units never settled: gap grows by u and stays >= 0 (more backing than units)',
      st + [u >= 0, u <= Y], And(TC + P - (Y - u) == gap + u, TC + P - (Y - u) >= 0))
# MATH-UO-34 verifies: SPEC-BACK-007, SPEC-BACK-009
prove('MATH-UO-34c', 'settleSeizure u after the measured burn of u: gap unchanged',
      st + [u >= 0, u <= TC, u <= Y], (TC - u) + P - (Y - u) == gap)
Y2 = Y - b
# MATH-UO-34 verifies: SPEC-BACK-012, SPEC-BACK-009
prove('MATH-UO-34d', 'settlePending x with any burn b that passes Y + x <= TC + P: gap after >= 0, so pool tokens never leave for units still in circulation',
      st + [x >= 1, x <= P, b >= 0, b <= Y, Y2 + x <= TC + P], TC + (P - x) - Y2 >= 0)
# MATH-UO-34 verifies: SPEC-BACK-012
prove('MATH-UO-34e', 'with a conforming LPVaultSwap (gap 0) the check proves the call burned at least x units',
      st + [gap == 0, x >= 1, x <= P, b >= 0, b <= Y, Y2 + x <= TC + P], b >= x)
# MATH-UO-34 verifies: SPEC-BACK-012, SPEC-BACK-009
prove('MATH-UO-34f', 'after an orphan burn (gap = g > 0) a settlement of x <= g with no burn passes and leaves gap - x >= 0',
      st + [gap >= 1, x >= 1, x <= P, x <= gap], And(Y + x <= TC + P, TC + (P - x) - Y >= 0))
# MATH-UO-34 verifies: SPEC-BACK-009
prove('MATH-UO-34g', 'with no orphan burn the gap stays 0: a sequence Adapter call, settleSeizure u, settlePending x with burn x keeps gap == 0',
      st + [gap == 0, s >= 0, s <= TC, TC + m >= s, Y + m >= 0, u >= 0, u <= TC1, u <= Y1,
            x >= 1, x <= P1, Y1 - u - x >= 0],
      (TC1 - u) + (P1 - x) - (Y1 - u - x) == 0)

# ---------------------------------------------------------------------------
# MATH-UO-35  Why the check is one-sided.
# MATH-UO-35 verifies: SPEC-BACK-009, REQ-VTOKEN-016
witness('MATH-UO-35',
        'wrong reading (Adapter requires Y == TC + P): after one orphan burn every later pledge in the market reverts',
        st + [u >= 1, u <= Y, m >= 1, s == 0,
              Not(TC + m + P == (Y - u) + m)])

# ---------------------------------------------------------------------------
# MATH-UO-36  Reconciliation shortfall equals the units Aave seized and nobody settled.
AC, sig, units, sh, sf = Ints('accountCredited unsettledSeized units sharesNow shortfall')
acct = [AC >= 0, sig >= 0, sig <= AC, units >= 0]
short = lambda S_: If(AC > S_, AC - S_, 0)
# MATH-UO-36 verifies: SPEC-BACK-011
prove('MATH-UO-36a', 'release / releasePartial / releaseForDeleverage: S = shares after the withdrawal + units gives shortfall == unsettled seized units',
      acct + [units <= AC - sig, sh == AC - sig - units], short(sh + units) == sig)
# MATH-UO-36 verifies: SPEC-BACK-011
prove('MATH-UO-36b', 'releaseZeroCredit / recredit: S = current shares gives shortfall == unsettled seized units',
      acct + [sh == AC - sig], short(sh) == sig)
k_ = Int('seizedNow')
# MATH-UO-36 verifies: SPEC-BACK-011, SPEC-BACK-007
prove('MATH-UO-36c', 'settleSeizure: S = sharesBefore gives the earlier unsettled units, reconciled before the current seizure k is debited',
      acct + [k_ >= 0, k_ <= AC - sig, sh == AC - sig], And(short(sh) == sig, short(sh) <= AC))
# MATH-UO-36 verifies: SPEC-BACK-011
prove('MATH-UO-36d', 'a proxy supply above its credited units (unreachable) gives shortfall 0: the max(., 0) form is a no-op',
      acct + [sh >= AC], short(sh) == 0)

# ---------------------------------------------------------------------------
# MATH-UO-37  Pending payout: floor pro-rata, exact remainder on the final settlement.
A, n, x1, x2, o1, o2 = Ints('amount pUnits x1 x2 out1 out2')
pay = [A >= 0, A < 2 ** 128, n >= 2, x1 >= 1, x1 < n,
       o1 * n <= A * x1, A * x1 < o1 * n + n]               # out1 = floor(A * x1 / n), x1 < n
# MATH-UO-37 verifies: SPEC-BACK-012
prove('MATH-UO-37a', 'partial settlement pays out <= its pro-rata share and leaves the remaining units backed by at least their share',
      pay, And(o1 >= 0, o1 <= A, (A - o1) * n >= A * (n - x1)))
# MATH-UO-37 verifies: SPEC-BACK-012
prove('MATH-UO-37b', 'two settlements (x1 then the rest) pay exactly the pending amount: no pool token is stranded',
      pay + [x2 == n - x1, o2 == A - o1], And(o1 + o2 == A, o2 >= 0))
x3, o3, n2, A2 = Ints('x3 out3 pUnits2 amount2')
# MATH-UO-37 verifies: SPEC-BACK-012
prove('MATH-UO-37c', 'three settlements: the second floor payout also stays within the remainder; the final pays exactly what is left',
      pay + [n2 == n - x1, A2 == A - o1, x2 >= 1, x2 < n2, o2 * n2 <= A2 * x2, A2 * x2 < o2 * n2 + n2,
             o3 == A2 - o2],
      And(o2 >= 0, o2 <= A2, o3 >= 0, o1 + o2 + o3 == A))

# ---------------------------------------------------------------------------
# MATH-UO-38  Seizure list debit over three records (largest first at insertion).
c1, c2, c3, dv = Ints('credited1 credited2 credited3 debit')
t1 = If(dv < c1, dv, c1)
r1 = dv - t1
t2 = If(r1 < c2, r1, c2)
r2 = r1 - t2
t3 = If(r2 < c3, r2, c3)
r3 = r2 - t3
lst = [c1 >= 1, c2 >= 1, c3 >= 1, c1 >= c2, c2 >= c3, dv >= 1]
# MATH-UO-38 verifies: SPEC-BACK-006
prove('MATH-UO-38a', 'debit u <= sum credited: takes sum to u (rem == 0) and each take <= its credited units',
      lst + [dv <= c1 + c2 + c3],
      And(r3 == 0, t1 + t2 + t3 == dv, t1 <= c1, t2 <= c2, t3 <= c3, t1 >= 0, t2 >= 0, t3 >= 0))
# MATH-UO-38 verifies: SPEC-BACK-006
prove('MATH-UO-38b', 'only the last record touched is partially debited: an earlier record is either untouched or emptied',
      lst + [dv <= c1 + c2 + c3],
      And(Implies(t2 > 0, t1 == c1), Implies(t3 > 0, And(t1 == c1, t2 == c2))))
# MATH-UO-38 verifies: SPEC-BACK-006
prove('MATH-UO-38c', 'a debit above the account-market\'s credited units leaves rem > 0, so the call reverts',
      lst + [dv > c1 + c2 + c3], r3 > 0)

finish()
