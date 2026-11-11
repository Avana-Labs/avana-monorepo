# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-29..31, MATH-AR-43..44 — Cap sizing guidance (SPEC-CAP-007): the incident term
(loss while liquidation is stopped for the 48-hour incident window) and the single-token tail term.

Model of the incident term (one LP collateral reserve per account, Aave V4 semantics):
  at the start     C0 x CF >= h0 x D0          (h0 = pauseLossStartHealthFactor, 0.95)
  after the window C1 >= C0 x (1 - dLP)        (dLP = worst LP value drop over the window + margin)
                   D1 <= D0 x (1 + g)(1 + delta) (g = interest growth, delta = debt-asset price rise)
  liquidation      repays x, seizes x x LB     (LB <= maxLiquidationBonus)
Loss factor lambda = max(0, (1 + g)(1 + delta) - h0 (1 - dLP) / (CF x LB)).
"""
import math
from fractions import Fraction as Fr
from z3 import Reals, And, If
from _common import prove, witness, note, computed, finish

C1, D1, LB, dl, sz = Reals('C1 D1 LB x seized')

# MATH-AR-29 verifies: SPEC-CAP-007, Q-192
prove('MATH-AR-29a', 'collateral >= debt x LB after the window  =>  the debt can be cleared with no deficit (full seizure fits)',
      [C1 > 0, D1 > 0, LB >= 1, C1 >= D1 * LB], D1 * LB <= C1)
prove('MATH-AR-29b', 'any liquidation sequence repays at most C1/LB, so deficit >= D1 - C1/LB',
      [C1 > 0, D1 > 0, LB >= 1, dl >= 0, dl <= D1, sz == dl * LB, sz <= C1], D1 - dl >= D1 - C1 / LB)

C0, D0, cf, h0, dLP, g, dlt, defi = Reals('C0 D0 cf h0 dLP g delta deficit')
hyp = [C0 > 0, D0 > 0, cf > 0, cf < 1, LB >= 1, LB * cf < 1, h0 > 0, C0 * cf >= h0 * D0,
       dLP >= 0, dLP < 1, g >= 0, dlt >= 0, C1 >= C0 * (1 - dLP), C1 > 0, D1 <= D0 * (1 + g) * (1 + dlt), D1 > 0,
       defi == If(D1 - C1 / LB > 0, D1 - C1 / LB, 0)]
lam = (1 + g) * (1 + dlt) - h0 * (1 - dLP) / (cf * LB)
# MATH-AR-30 verifies: SPEC-CAP-007, Q-192, Q-234
prove('MATH-AR-30a', 'deficit per account <= D0 x lambda, lambda = max(0, (1+g)(1+delta) - h0(1-dLP)/(CF x LB))',
      hyp, defi <= D0 * If(lam > 0, lam, 0))
prove('MATH-AR-30b', 'no deficit if h0 (1 - dLP) >= (1+g)(1+delta) x CF x LB',
      hyp + [(1 - dLP) * h0 >= (1 + g) * (1 + dlt) * cf * LB], defi == 0)
stable = [cf == 0.312, LB == 1.05, h0 == 0.95, g == 0.00055, dlt == 0,
          C0 * cf == h0 * D0, C1 == C0 * (1 - dLP), D1 == D0 * (1 + g)]
prove('MATH-AR-30c', 'SPEC-CAP-007 Why: CF 0.312, LB 1.05, h0 0.95, g 0.00055: no deficit for any LP drop up to 65.4%',
      hyp + stable + [dLP <= 0.654], defi == 0)
witness('MATH-AR-30d', 'same parameters: an LP drop of 65.6% creates a deficit (the incident term alone is silent below it)',
        hyp + stable + [dLP == 0.656, defi > 0])


def loss(cf_, lb_, h0_, hours, apr, dlp, delta=0.0):
    g_ = math.exp(apr * hours / 8760) - 1
    return max(0.0, (1 + g_) * (1 + delta) - h0_ * (1 - dlp) / (cf_ * lb_))


lines = ["CF    LB    h0    delta | loss % of debt at LP drop 50%   60%   70%   80%   90% | largest LP drop with no loss"]
for cf_, lb_ in ((0.30, 1.05), (0.312, 1.05), (0.312, 1.10)):
    for delta in (0.0, 0.05):
        cells = ' '.join(f"{100*loss(cf_, lb_, 0.95, 48, 0.0675, d, delta):5.1f}" for d in (0.5, 0.6, 0.7, 0.8, 0.9))
        g_ = math.exp(0.0675 * 48 / 8760) - 1
        keep = (1 + g_) * (1 + delta) * cf_ * lb_ / 0.95
        lines.append(f"{cf_:.3f} {lb_:.2f} 0.95  {delta:.2f}  | {cells} | {100*(1-keep):5.1f}%")
# MATH-AR-31 verifies: SPEC-CAP-007, Q-192
note('MATH-AR-31', 'incident-term loss table (48-hour window, 6.75% rate, h0 0.95; GHO delta 0, USDC delta 0.05)',
     '\n'.join(lines) +
     "\nThe window enters through interest (48 h at 6.75% adds 0.04% of debt) and through the LP drop and debt-price\n"
     "rise it allows; the LP-drop bound and delta decide the loss, so caps need an approved worst-case drop per pool.")

# ---------------------------------------------------------------------------
# MATH-AR-43  SPEC-CAP-007 worked figures (exact rationals).
q = Fr(95, 100) * (1 - Fr(70, 100)) / (Fr(30, 100) * Fr(105, 100))
lam_gho = Fr(1001, 1000) - q
lam_usdc = Fr(1001, 1000) * Fr(105, 100) - q
tail_f = Fr(312, 1000)   # SPEC-CAP-007 (ii): booked value x CF_t (health factor 1)
# MATH-AR-43 verifies: SPEC-CAP-007, Q-249
computed('MATH-AR-43', 'cap sizing examples (6 decimals for factors, dollars for amounts)',
         [('h0(1-dLP)/(CF x LB) = 0.904762', 904762, round(q * 10**6)),
          ('lambda GHO = 0.096238', 96238, round(lam_gho * 10**6)),
          ('GHO: 600,000 x lambda = $57,743 (up)', 57743, math.ceil(600_000 * lam_gho)),
          ('57,743 <= 400,000', True, math.ceil(600_000 * lam_gho) <= 400_000),
          ('lambda USDC (delta 0.05) = 0.146288', 146288, round(lam_usdc * 10**6)),
          ('USDC: 300,000 x lambda = $43,887 (up)', 43887, math.ceil(300_000 * lam_usdc)),
          ('collateral budget 1,100,000 x 0.30 <= 900,000 x 1.10', True,
           Fr(1_100_000) * Fr(30, 100) <= Fr(900_000) * Fr(110, 100)),
          ('65.5% = 1 - 1.00055 x 0.312 x 1.05 / 0.95 (0.1%)', 655,
           round((1 - Fr(100055, 100000) * Fr(312, 1000) * Fr(105, 100) / Fr(95, 100)) * 1000)),
          ('tail factor CF_t = 0.312', 3120, round(tail_f * 10**4)),
          ('400,000 GHO covers $1,282,051 of token cap plus slices', 1_282_051, math.floor(400_000 / tail_f)),
          ('token cap up to $1,232,051 with $50,000 of slices', 1_232_051, math.floor(400_000 / tail_f) - 50_000)])

# ---------------------------------------------------------------------------
# MATH-AR-44  Basis of the debt bounds in SPEC-CAP-007.
K, Z, cfm, ho, dc, Dop, Bk, V0, V1, Dn, gr = Reals('K Z CF h_o debtCapSum Dopen booked V0 V1 Dnow growth')
# MATH-AR-44 verifies: SPEC-CAP-007, SPEC-CAP-008
prove('MATH-AR-44a', 'collateral budget (K+Z) x CF <= sum debtCap x h_o  =>  debt opened at h_o against booked K+Z <= sum debtCap',
      [K >= 0, Z >= 0, cfm > 0, cfm < 1, ho >= 1, dc >= 0, (K + Z) * cfm <= dc * ho, Dop >= 0, Dop * ho <= (K + Z) * cfm],
      Dop <= dc)
prove('MATH-AR-44b', 'tail term: debt carried by positions that are not yet liquidatable <= booked value x CF_t '
      '(launch CF 0.312, h_o 1.10, opened at h_o, at most 6% interest since, LP value at most the booked value)',
      [cfm == 0.312, ho == 1.10, Bk >= V0, V0 > 0, V1 == V0, Dop >= 0, Dop * ho <= V0 * cfm,
       gr >= 0, gr <= 0.06, Dn == Dop * (1 + gr), Dn <= V1 * cfm],
      Dn <= Bk * cfm)   # F-AR-4 resolved: the tail term no longer divides by minOpeningHealthFactor

finish()
