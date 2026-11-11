# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-20..25, MATH-AR-41 — Hub riskPremiumThreshold check (Hub._applyPremiumDelta):
    require(threshold == MAX || spoke.premiumShares <= spoke.drawnShares.percentMulUp(threshold))
where spoke.premiumShares = sum_i percentMulUp(drawnShares_i, riskPremium_i) over the Spoke's users
(UserPositionUtils.calculatePremiumDelta) and spoke.drawnShares = sum_i drawnShares_i.
Spec: SPEC-HUB-004 (threshold >= highest collateralRisk + 1, the 9,999-share condition and its
aggregate form), Q-141, Q-178.
"""
from z3 import Ints, Int, If, And, Or, Sum, Implies
from _common import prove, witness, note, computed, finish, floor_div, ceil_div, RAY, BPS
import _v4ref as v4

# ---------------------------------------------------------------------------
# MATH-AR-20  Hub and Spoke drawn-share bookkeeping agree, so the Hub check really is
# over sum_i percentMulUp(d_i, r_i) vs percentMulUp(sum_i d_i, T).
s, i = Ints('s idx')
amt, h1 = ceil_div(s * i, RAY, 'drawnAmountToRestore')    # liquidation: rayMulUp(shares, idx)
hs, h2 = floor_div(amt * RAY, i, 'hubShares')              # Hub.restore: rayDivDown(amount, idx)
# MATH-AR-20 verifies: SPEC-HUB-004, SPEC-HUB-008
prove('MATH-AR-20a', 'liquidation restore: Hub removes exactly the Spoke-side drawn shares (idx >= RAY)',
      [s >= 0, s < 2**120, i >= RAY, i < 2**120] + h1 + h2, hs == s)
x = Int('x')
sk, h3 = floor_div(x * RAY, i, 'spokeShares')
hk, h4 = floor_div(x * RAY, i, 'hubShares2')
prove('MATH-AR-20b', 'repay restore: Spoke rayDivDown and Hub toDrawnSharesDown give the same shares',
      [x >= 0, i >= RAY] + h3 + h4, sk == hk)
a2, h5 = ceil_div(x * RAY, i, 'drawShares')
prove('MATH-AR-20c', 'draw: the shares the Spoke records are the shares the Hub returns (single value, ceil)',
      [x > 0, i >= RAY] + h5, a2 * i >= x * RAY)

# ---------------------------------------------------------------------------
# MATH-AR-21  A user's risk premium never exceeds the highest collateral risk it holds:
# rp = ceil(sum_j w_j * cr_j / sum_j w_j) (Spoke._processUserAccountData, divUp)
w = Ints('w0 w1 w2'); cr = Ints('cr0 cr1 cr2'); mx = Int('maxRisk')
num = Sum([w[j] * cr[j] for j in range(3)]); den = Sum(w)
rp, h6 = ceil_div(num, den, 'rp')
# MATH-AR-21 verifies: SPEC-HUB-004
prove('MATH-AR-21', 'user riskPremium <= max collateralRisk of its collateral (3 collaterals)',
      [And(w[j] >= 0, cr[j] >= 0, cr[j] <= mx) for j in range(3)] + [den > 0] + h6, rp <= mx)

# ---------------------------------------------------------------------------
# Helper: per-user premium shares and the Spoke-level check for N users.
def spoke_check(N, tag):
    d = Ints(' '.join(f'd{j}_{tag}' for j in range(N)))
    r = Ints(' '.join(f'r{j}_{tag}' for j in range(N)))
    T = Int(f'T_{tag}')
    hyps, ps = [], []
    for j in range(N):
        p, h = ceil_div(d[j] * r[j], BPS, f'p{j}_{tag}')
        hyps += h + [d[j] >= 0, d[j] < 2**120, r[j] >= 0, r[j] <= 100000]
        ps.append(p)
    allow, h = ceil_div(Sum(d) * T, BPS, f'allow_{tag}')
    hyps += h + [T >= 0, T < 2**24 - 1]
    return d, r, T, hyps, Sum(ps) <= allow


# MATH-AR-22  Wrong reading: threshold = highest collateral risk with no margin breaks with 2 users.
d, r, T, hy, ok = spoke_check(2, 'a')
# MATH-AR-22 verifies: SPEC-HUB-004
witness('MATH-AR-22', 'threshold == top risk: two users at the top risk make the Hub check revert',
        hy + [r[0] == T, r[1] == T, T == 5000, d[0] >= 10**18, d[1] >= 10**18, ok == False])

# MATH-AR-23  SPEC-HUB-004: threshold >= top risk + 1 bps. Per-user lemma, then explicit N-user proofs.
dd, rr, TT, Pdr, Qdt = Ints('d r T d_times_r d_times_T')
pu, h7 = ceil_div(Pdr, BPS, 'pu')
# MATH-AR-23 verifies: SPEC-HUB-004, Q-141
prove('MATH-AR-23a', 'per user: d*(T-r) >= 9999  =>  percentMulUp(d, r)*1e4 <= d*T (premium fits inside the user\'s own allowance)',
      [dd >= 0, rr >= 0, TT >= rr, Pdr == dd * rr, Qdt == dd * TT, Qdt - Pdr >= BPS - 1] + h7, pu * BPS <= Qdt)
for N in (2, 3, 4, 6):
    d, r, T, hy, ok = spoke_check(N, f'n{N}')
    prove(f'MATH-AR-23b-N{N}', f'{N} users, every r_i <= T-1 and every d_i >= 9,999 drawn shares  =>  Hub check passes',
          hy + [And(r[j] <= T - 1, d[j] >= BPS - 1) for j in range(N)], ok)
d, r, T, hy, ok = spoke_check(4, 'agg')
prove('MATH-AR-23c', 'aggregate form (4 users): sum_i d_i*(T-r_i) >= 9,999 * (#users with debt)  =>  Hub check passes',
      hy + [And(r[j] <= T) for j in range(4)] +
      [Sum([d[j] * (T - r[j]) for j in range(4)]) >= (BPS - 1) * Sum([If(d[j] > 0, 1, 0) for j in range(4)])], ok)

# MATH-AR-24  With +1 bps, only users holding < 9,999 drawn shares (1e-14 GHO) can break it.
d, r, T, hy, ok = spoke_check(3, 'b')
# MATH-AR-24 verifies: SPEC-HUB-004, Q-169
witness('MATH-AR-24a', 'threshold = top risk + 1 bps: three dust users (< 9,999 drawn shares each) still break the check',
        hy + [T == 5001, r[0] == 5000, r[1] == 5000, r[2] == 5000, ok == False])
d, r, T, hy, ok = spoke_check(3, 'c')
witness('MATH-AR-24b', 'search: + 1 bps with one user >= 1,000 GHO (index <= 10) and two dust users breaks the check',
        hy + [T == 5001, r[0] == 5000, r[1] == 5000, r[2] == 5000, d[0] >= 10**20, ok == False], expect='PROVED')
note('MATH-AR-24c', 'dust accounts needed to break the + 1 bps margin',
     "slack = sum_i d_i*(T - r_i)/1e4 - (#users)*0.9999 shares. One 1,000 GHO account at index <= 10 holds >= 1e20 shares,\n"
     "giving >= 1e16 shares of slack at 1 bps; each dust account consumes < 1 share, so > 1e16 dust accounts are needed.\n"
     "Avana has no minimum debt (Q-169), so one-share accounts can exist (MATH-AR-24d); breaking the check still needs\n"
     "more one-share accounts than the slack of every other account on the Spoke, > 1e16 against one 1,000 GHO account.")
# MATH-AR-24d: SPEC-HUB-004 example: there is no minimum debt (Q-169), so an account can hold a single
# drawn share. A borrow of 1 wei at any index in [RAY, 2^100) records exactly 1 drawn share (rayDivUp);
# the aggregate form (MATH-AR-23c) and the slack bound (MATH-AR-24b-c) carry the check past such accounts.
amt24, idx24 = Ints('amt24 idx24')
sh24, h24 = ceil_div(amt24 * RAY, idx24, 'sh24')
prove('MATH-AR-24d', 'SPEC-HUB-004 example: a 1 wei borrow (no minimum debt) records exactly one drawn share',
      [amt24 == 1, idx24 >= RAY, idx24 < 2**100] + h24, sh24 == 1)  # F-AR-2 resolved in the spec text

# MATH-AR-25  Raising a reserve's collateralRisk above the Hub threshold (Spoke-side change)
# makes every premium refresh revert, including the one at the end of Spoke.liquidationCall.
d, r, T, hy, ok = spoke_check(1, 'e')
# MATH-AR-25 verifies: SPEC-HUB-004, Q-178
witness('MATH-AR-25', 'collateralRisk raised to T + 2 bps: _notifyRiskPremiumUpdate after liquidation reverts (one 1,000 GHO user)',
        hy + [T == 5001, r[0] == 5003, d[0] == 10**21, ok == False])

# MATH-AR-41  SPEC-HUB-004 example (collateralRisk 1,000 and 1,500 -> threshold 1,501).
# MATH-AR-41 verifies: SPEC-HUB-004
computed('MATH-AR-41', 'risk premium threshold example',
         [('threshold = max collateralRisk + 1', 1501, max(1000, 1500) + 1),
          ('premium shares of 5,000e18 drawn shares at 1,500', 750 * 10**18, v4.percent_mul_up(5000 * 10**18, 1500)),
          ('threshold allowance at 1,501', 7505 * 10**17, v4.percent_mul_up(5000 * 10**18, 1501)),
          ('one 5,000 GHO user passes', True, v4.percent_mul_up(5000 * 10**18, 1500) <= v4.percent_mul_up(5000 * 10**18, 1501)),
          ('two one-share users hold 2 premium shares', 2, 2 * v4.percent_mul_up(1, 1500)),
          ('allowance ceil(2 x 1,501 / 1e4)', 1, v4.percent_mul_up(2, 1501)),
          ('two one-share users fail', False, 2 * v4.percent_mul_up(1, 1500) <= v4.percent_mul_up(2, 1501))])

finish()
