# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-53..58 — Circuit breakers (Q-399 final v1 table).

Spec: SPEC-BRK-001 (price drop: monitoring alert only), SPEC-BRK-002 (pool-share concentration gate,
merged with poolShareMaxBps), SPEC-BRK-003 (issuer probe), SPEC-BRK-004 (debt conditions: deficit
freeze at 10,000 GHO), SPEC-BRK-005 (seizure surge: monitoring alert only), SPEC-BRK-006 (route
failures: monitoring alert; a guardian freezes when routes cannot settle), REQ-MREG-026 (reopening:
30 minutes of healthy observations clear a temporary gate; deficit or security freezes need an
authorized reopening), REQ-RISK-065, REQ-PSTORE-016 (one 10% pool-share value).
Launch values (proposed defaults): pool share 1,000 bps, breakerDeficitMax 10,000 GHO, recovery
window 1,800 s. Alert thresholds: price drop 300 bps in 7,200 s, seizure 2,000 bps in 3,600 s,
3 route failures in 3,600 s. There is no on-chain latch or breakerCooldown.
"""
from z3 import Ints, Int, Reals, Bools, Bool, If, And, Or, Not, Implies
from _common import prove, witness, computed, finish, RAY, BPS

WINDOW, RECOVERY = 3600, 1800

# ---------------------------------------------------------------------------
# MATH-AR-53  SPEC-BRK-001 price drop (alert only, Q-399).
at, now = Ints('at now')
cp, p8, bd = Reals('cp price8 dropBps')      # integers in the contract; the identities below hold over the reals
trip1 = And(now - at <= 7200, p8 * BPS < cp * (BPS - bd))
b53 = [cp > 0, cp < 2**64, p8 > 0, p8 < 2**64, bd >= 100, bd <= 2000, at <= now]
# MATH-AR-53 verifies: SPEC-BRK-001, REQ-RISK-065
prove('MATH-AR-53a', 'fresh checkpoint: alert  <=>  the drop (cp - price8)/cp exceeds the 300 bps alert threshold exactly (strict)',
      b53 + [now - at <= 7200], trip1 == ((cp - p8) * BPS > bd * cp))
prove('MATH-AR-53b', 'a checkpoint older than 7,200 s never alerts (a stalled checkpoint cannot hold the alert on)',
      b53 + [now - at > 7200], Not(trip1))
prove('MATH-AR-53c', 'products below 2^78', b53, And(p8 * BPS < 2**78, cp * (BPS - bd) < 2**78))
computed('MATH-AR-53d', 'SPEC-BRK-001 alert examples (cp 200,000,000, 300 bps in 2 hours)',
         [('193,990,000 alerts (1.9399e12 < 1.94e12)', True, 193_990_000 * BPS < 200_000_000 * (BPS - 300)),
          ('194,000,000 does not (equality)', False, 194_000_000 * BPS < 200_000_000 * (BPS - 300))])

# ---------------------------------------------------------------------------
# MATH-AR-54  SPEC-BRK-002 pool-share concentration gate (10%, merged with poolShareMaxBps); REQ-PSTORE-016.
sup, L, lhm, lhm2, mb, bb = Reals('supply L liqHM liqHM2 poolShareMaxBps breakerPoolShareBps')
trip2 = sup * BPS > bb * lhm
b54 = [sup >= 0, L > 0, lhm >= 0, mb > 0, mb <= BPS, bb >= mb, bb <= 5000]
# MATH-AR-54 verifies: SPEC-BRK-002, SPEC-CAP-005, REQ-PSTORE-016
prove('MATH-AR-54a', 'a pledge admitted by the pool-share cap never trips the gate at the same liqHM (one value; >= also covers a per-pool lower cap)',
      b54 + [(sup + L) * BPS <= mb * lhm], Not((sup + L) * BPS > bb * lhm))
prove('MATH-AR-54b', 'a lower liqHM only trips earlier (monotone in the floored denominator)',
      b54 + [lhm2 <= lhm, lhm2 >= 0, trip2], sup * BPS > bb * lhm2)
witness('MATH-AR-54c', 'rescue top-ups are exempt from the pool-share cap, so they can raise the share past the breaker (design)',
        b54 + [sup * BPS <= mb * lhm, (sup + L) * BPS > bb * lhm])
computed('MATH-AR-54d', 'SPEC-BRK-002 example (liqHM 2e13, 1,000 bps)',
         [('supply 2.1e12 trips', True, 21 * 10**11 * BPS > 1000 * 2 * 10**13),
          ('supply 2e12 does not', False, 2 * 10**12 * BPS > 1000 * 2 * 10**13)])

# ---------------------------------------------------------------------------
# MATH-AR-55  SPEC-BRK-003 issuer probe decision.
kind = Int('probeKind')          # 0 None, 1 PausedFlag, 2 UsdtFeeRate
reverted, word32 = Bools('reverted returnIsOneWord')
val = Int('returnValue')
trip3 = If(kind == 0, False,
           Or(reverted, Not(word32),
              If(kind == 1, val != 0, val > 0)))
# MATH-AR-55 verifies: SPEC-BRK-003
prove('MATH-AR-55a', 'probe None never trips; a revert, out-of-gas or malformed return always trips a recorded probe',
      [Or(kind == 0, kind == 1, kind == 2), val >= 0],
      And(Implies(kind == 0, Not(trip3)), Implies(And(kind != 0, Or(reverted, Not(word32))), trip3)))
prove('MATH-AR-55b', 'UsdtFeeRate: a well-formed answer trips  <=>  basisPointsRate() > 0',
      [kind == 2, Not(reverted), word32, val >= 0], trip3 == (val > 0))
computed('MATH-AR-55c', 'SPEC-BRK-003 example (USDT basisPointsRate)',
         [('rate 0 at listing: clear', False, 0 > 0), ('rate 10: tripped', True, 10 > 0)])

# ---------------------------------------------------------------------------
# MATH-AR-56  SPEC-BRK-004 debt conditions.
dray, dmax = Ints('deficitRay breakerDeficitMax')
# MATH-AR-56 verifies: SPEC-BRK-004, DEF-018, Q-399
prove('MATH-AR-56a', 'DEFICIT: deficitRay > max x RAY  <=>  the deficit in base units, rounded up, exceeds max',
      [dray >= 0, dmax >= 0],
      (dray > dmax * RAY) == (dray + RAY - 1 >= (dmax + 1) * RAY))
prove('MATH-AR-56b', 'breakerDeficitMax = 0 trips on any deficit', [dray > 0, dmax == 0], dray > dmax * RAY)
computed('MATH-AR-56c', 'SPEC-BRK-004 and 3.2 Borrow examples (breakerDeficitMax 10,000 GHO, Q-399)',
         [('10,000.5e18 x RAY > 10,000e18 x RAY (DEFICIT)', True, 100_005 * 10**17 * RAY > 10_000 * 10**18 * RAY),
          ('exactly 10,000e18 x RAY does not trip', False, 10_000 * 10**18 * RAY > 10_000 * 10**18 * RAY)])

# ---------------------------------------------------------------------------
# MATH-AR-57  SPEC-BRK-005 seizure surge (alert only) and the reopening rule (Q-399).
cred_before, seized, cred_after, cs, bs = Ints('creditedBefore unitsSeized creditedAfter creditedAtStart seizureBps')
# MATH-AR-57 verifies: SPEC-BRK-005, REQ-MREG-026, EMG-089
prove('MATH-AR-57a', 'opening a window at a record: credited read after the debit + this seizure = credited before the window',
      [cred_before >= seized, seized >= 0, cred_after == cred_before - seized, cs == cred_after + seized], cs == cred_before)
lu, t, lu2 = Ints('lastBreach t clearAt')
prove('MATH-AR-57b', 'reopening: a temporary gate clears at lastBreach + 1,800 s, never before 30 minutes of healthy observations',
      [lu >= 0, t >= lu, lu2 == lu + RECOVERY, t >= lu2], t - lu >= RECOVERY)
# Two bursts straddling a fixed window boundary: a rolling-window reading would latch, the spec's fixed
# window (opened at the first record after expiry) does not. Deliberate wrong-reading check.
w0, t1, t2, s1, s2 = Ints('windowStart t1 t2 s1 s2')
C = 10**10
witness('MATH-AR-57c', 'wrong reading (rolling hour): 2 x (threshold) seized within 2 s across a window boundary alerts',
        [bs == 2000, t1 == w0 + WINDOW - 1, t2 == w0 + WINDOW + 1, s1 * BPS <= bs * C, s2 * BPS <= bs * C,
         (s1 + s2) * BPS > bs * C])


def surge(events, credited0, bps=2000):
    """events: list of (t, unitsSeized). Returns the alert time or None (SPEC-BRK-005 monitoring rule)."""
    ws, cas, sw, credited = None, 0, 0, credited0
    for tt, sz in events:
        credited -= sz                                        # Collateralization debit before the record
        if ws is None or tt >= ws + WINDOW:
            ws, cas, sw = tt, credited + sz, 0
        sw += sz
        if sw * BPS > bps * cas:
            return tt
    return None


computed('MATH-AR-57d', 'SPEC-BRK-005 and EMG-089 alert examples (2,000 bps)',
         [('1.2e9 + 0.8e9 of 1e10 credited in one hour: no alert', None,
           surge([(0, 1_200_000_000), (1800, 800_000_000)], 10**10)),
          ('one more unit alerts', 1801, surge([(0, 1_200_000_000), (1800, 800_000_000), (1801, 1)], 10**10)),
          ('EMG-089: 2,000,001 x 1e4 > 2,000 x 10,000,000', True,
           2_000_001 * BPS > 2000 * 10_000_000),
          ('recovery window 1,800 s (provisional launch setting)', 1_800, RECOVERY)])

# ---------------------------------------------------------------------------
# MATH-AR-58  SPEC-BRK-006 route failures (alert only; no on-chain counter, Q-399).
def route(events, n=3):
    ws, cnt = None, 0
    for tt, k in events:
        if ws is None or tt >= ws + WINDOW:
            ws, cnt = tt, 0
        cnt += k
        if cnt >= n:
            return tt, cnt
    return None, cnt


h = 3600
r1 = route([(10 * h + 5 * 60, 1), (10 * h + 31 * 60, 1), (10 * h + 52 * 60, 1)])
r2 = route([(10 * h + 5 * 60, 1), (10 * h + 31 * 60, 1), (11 * h + 7 * 60, 1)])
k1, k2, k3, cnt = Ints('k1 k2 k3 count')
# MATH-AR-58 verifies: SPEC-BRK-006, REQ-MREG-026
prove('MATH-AR-58a', 'each observation adds 0 or 1 per key; with the alert count N, a window alerts only after N failures',
      [And(k >= 0, k <= 1) for k in (k1, k2, k3)] + [cnt == k1 + k2 + k3, cnt >= 3], And(k1 == 1, k2 == 1, k3 == 1))
computed('MATH-AR-58b', 'SPEC-BRK-006 alert example (3 failures in 1 hour)',
         [('failures 10:05, 10:31, 10:52 alert at 10:52', 10 * h + 52 * 60, r1[0]),
          ('alert count at 10:52', 3, r1[1]),
          ('third failure at 11:07: window rolled at 11:05, count restarts at 1', (None, 1), r2)])

finish()
