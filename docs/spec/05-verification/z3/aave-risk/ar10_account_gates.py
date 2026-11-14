# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-AR-59..65 — Account-level gates of the AaveAdapter and RiskModule.

Spec: SPEC-PROXY-002 (account price check, borrowPriceMaxAge), SPEC-PROXY-004 (borrow forwarding),
SPEC-PROXY-008 (one-sided backing check with the gap form), SPEC-PROXY-009 (repay with collateral:
health factor direction), SPEC-CF-004 / SPEC-HUB-006 (listing margin), and the address freeze
(REQ-ADAPTER-082, REQ-MREG-023, REQ-PROXY-099, INV-081), and the MarketRegistry / ParameterStore
figures of the risk pages.
"""
from fractions import Fraction as Fr
from z3 import Ints, Int, Reals, Bools, Bool, If, And, Or, Not, Implies
from _common import prove, witness, computed, finish, floor_div, BPS

# ---------------------------------------------------------------------------
# MATH-AR-59  SPEC-PROXY-002 freshness test on source timestamps.
now, ti, hb, mage = Ints('now t_i heartbeat maxAge')
age_ok = And(ti <= now, now - ti <= mage)
b59 = [now >= 0, ti >= 0, hb > 0, mage == If(hb + 600 < 4200, hb + 600, 4200)]
# MATH-AR-59 verifies: SPEC-PROXY-002, REQ-PROXY-064
prove('MATH-AR-59a', 'pass  =>  the price is at most borrowPriceMaxAge = min(heartbeat + 600, 4,200) old and not in the future',
      b59 + [age_ok], And(now - ti >= 0, now - ti <= 4200, now - ti <= hb + 600))
prove('MATH-AR-59b', 'the subtraction runs only after t_i <= now (no uint underflow on a future timestamp)',
      b59 + [ti <= now], now - ti >= 0)
prove('MATH-AR-59c', 'borrowPriceMaxAge 0 admits only a same-block price', [now >= 0, ti >= 0, ti <= now, now - ti <= 0], ti == now)
computed('MATH-AR-59d', 'SPEC-PROXY-002 and 3.2 Borrow examples',
         [('borrowPriceMaxAge for a 3,600 s heartbeat', 4200, min(3600 + 600, 4200)),
          ('age 1,762,700,000 - 1,762,695,700', 4300, 1_762_700_000 - 1_762_695_700),
          ('4,300 s fails (DebtPriceTooOld)', False, 4300 <= 4200),
          ('3,900 s passes', True, 3900 <= 4200)])

# ---------------------------------------------------------------------------
# MATH-AR-60  SPEC-PROXY-004 borrow forwarding by balance delta.
b0, amt, drawn, fwd = Ints('balanceBefore amount drawn forwarded')
# MATH-AR-60 verifies: SPEC-PROXY-004, BOR-POST-001
prove('MATH-AR-60a', 'drawn = after - before = amount, forwarded = drawn  =>  the proxy ends at its start balance (donations untouched)',
      [b0 >= 0, amt > 0, drawn == (b0 + amt) - b0, drawn == amt, fwd == drawn], (b0 + amt) - fwd == b0)
computed('MATH-AR-60b', 'SPEC-PROXY-004 example (370,000 units of donated USDC)',
         [('drawn', 5_000_000_000, 5_000_370_000 - 370_000), ('end balance', 370_000, 5_000_370_000 - 5_000_000_000)])

# ---------------------------------------------------------------------------
# MATH-AR-61  SPEC-PROXY-008 backing gap.
T, Cr, Pn, dT, dC, dP = Ints('totalSupply credited pendingUnits dSupply dCredited dPending')
G0 = Cr + Pn - T
G1 = (Cr + dC) + (Pn + dP) - (T + dT)
passes = And(T + dT <= Cr + dC + Pn + dP, G1 == G0)
b61 = [T >= 0, Cr >= 0, Pn >= 0, T <= Cr + Pn, T + dT >= 0, Cr + dC >= 0, Pn + dP >= 0]
# MATH-AR-61 verifies: SPEC-PROXY-008, INV-080
prove('MATH-AR-61a', 'a conforming call (supply and credited move by the same units, pending unchanged) passes with any existing gap',
      b61 + [dT == dC, dP == 0], passes)
prove('MATH-AR-61b', 'pass  =>  one-sided backing after the call: totalSupply <= credited + pending (INV-080)',
      b61 + [passes], T + dT <= Cr + dC + Pn + dP)
prove('MATH-AR-61c', 'a mint one unit above the credit, or a credit without its mint, fails',
      b61 + [dP == 0, Or(dT == dC + 1, dT == dC - 1)], Not(passes))
computed('MATH-AR-61d', 'SPEC-PROXY-008 example (gap 1,575,000,000)',
         [('gap after a matched pledge of 5e10', 1_575_000_000, 1_575_000_000 + 50_000_000_000 - 50_000_000_000),
          ('gap after minting 50,000,000,001 (BackingMismatch)', 1_574_999_999,
           1_575_000_000 + 50_000_000_000 - 50_000_000_001)])

# ---------------------------------------------------------------------------
# MATH-AR-62  SPEC-PROXY-009 repay with collateral.
A, D, a, y, V, cf, s, U, f = Reals('A D a y V CF s U f')
b62 = [A > 0, D > 0, y >= 0, y < D, a >= 0, a < A]
# MATH-AR-62 verifies: SPEC-PROXY-009, INV-089, REP-POST-008
prove('MATH-AR-62a', 'lemma: (A - a)/(D - y) >= A/D  <=>  y x A >= a x D', b62,
      ((A - a) * D >= A * (D - y)) == (y * A >= a * D))
siz = [V > 0, cf > 0, cf < 1, s >= 0, s < 1, U >= 0, f >= 0, V * (1 - s) > U,
       a == cf * V, y * (1 + f) == V * (1 - s) - U]
prove('MATH-AR-62b', 'y at the LPVaultSwap bound and HF >= CF x V (1+f) / (V(1-s) - U)  =>  HF\' >= HF',
      b62 + siz + [A * (V * (1 - s) - U) >= D * cf * V * (1 + f)], (A - a) * D >= A * (D - y))
witness('MATH-AR-62c', 'search: below the critical health factor the sized repayment lowers HF (the after-check then refuses the call)',
        b62 + siz + [A * (V * (1 - s) - U) < D * cf * V * (1 + f), (A - a) * D < A * (D - y)])
h0, h1, hf0, hf1 = Ints('exact0 exact1 hf0 hf1')
fh0, q0 = floor_div(h0, 10**18, 'fl0')
fh1, q1 = floor_div(h1, 10**18, 'fl1')
prove('MATH-AR-62d', 'exact HF\' >= exact HF  =>  Aave\'s floored values compare the same way (inclusive check never refuses it)',
      q0 + q1 + [h1 >= h0], fh1 >= fh0)
Vg = 3000 * 10**18
y_e = (Vg * 9900 // BPS - 10**16) * BPS // 10_009
phi = -(-(y_e * 9) // BPS)
crit = Fr(312, 1000) * Fr(10009, 10000) / Fr(99, 100)
computed('MATH-AR-62e', 'SPEC-PROXY-009 and 3.3 Repay examples (A $12,000, debt 10,000 GHO, $3,000 released at CF 0.312)',
         [('x = floor((floor(3,000 x 9,900/1e4) - 0.01) x 1e4 / 10,009)', 2_967_319_412_528_724_148_266, y_e),
          ('GHO debt after', 7_032_680_587_471_275_851_734, 10_000 * 10**18 - y_e),
          ('flash fee 2.6706 GHO (4 decimals)', 26706, round(Fr(phi, 10**14))),
          ('F + fee = 2,969.99 GHO (cents)', 296_999, round(Fr(y_e + phi, 10**16))),
          ('ghoToWallet = 2,985 - x - fee = 15.01', 15_010_000_000_000_000_000, 2985 * 10**18 - y_e - phi),
          ('CF-weighted collateral after $11,064', 11_064, 12_000 - 3_000 * Fr(312, 1000)),
          ('HF after 1.5732', 15732, round(Fr(11_064) / Fr(10_000 * 10**18 - y_e, 10**18) * 10**4)),
          ('lemma bound y >= 936 / 1.20 = 780', 780, Fr(936) / Fr(12, 10)),
          ('critical HF 0.3154', 3154, round(crit * 10**4)),
          ('x >= minDebtRepaid 2,950', True, y_e >= 2950 * 10**18),
          ('minDebtRepaid 3,000 fails (DeleverageTooSmall)', True, y_e < 3000 * 10**18)])

# ---------------------------------------------------------------------------
# MATH-AR-63  SPEC-CF-004 / SPEC-HUB-006 listing margin.
cfb, dev, drift = Ints('CF_bps dev drift')
Vr, Vt, Dd = Reals('Vreported Vtrue Debt')
# MATH-AR-63 verifies: SPEC-CF-004, SPEC-HUB-006
prove('MATH-AR-63a', 'margin 1e4 - CF > dev + drift, true value >= reported x (1 - (dev+drift)/1e4), reported hf >= 1  =>  true collateral > debt',
      [cfb > 0, cfb < BPS, dev >= 0, drift >= 0, BPS - cfb > dev + drift, Dd > 0,
       Vr * cfb >= Dd * BPS, Vt * BPS >= Vr * (BPS - dev - drift)], Vt > Dd)
computed('MATH-AR-63b', 'SPEC-CF-004 / SPEC-HUB-006 examples',
         [('USDC primary 25 + 25', 50, 25 + 25), ('USDC/ETH x ETH/USD (100+50) + (100+100)', 350, 100 + 50 + 100 + 100),
          ('CF 3,000: 7,000 > 350', True, BPS - 3000 > 350),
          ('CF 2,812 headroom', 7188, BPS - 2812), ('USDC primary 25 + 50', 75, 25 + 50),
          ('CF 2,812: 7,188 > 350', True, BPS - 2812 > 350)])

# ---------------------------------------------------------------------------
# MATH-AR-64  Address freeze: read only on new-activity paths (REQ-ADAPTER-082, REQ-MREG-023).
fz, deb, resc, other = Bools('frozen hasDebt rescueEligible otherChecksPass')
borrow_ok = And(other, Not(fz))
wd_debt_ok = And(other, Not(fz))
rwc_ok = And(other, Not(fz))
pledge_ok = And(other, Or(Not(fz), resc))
exit_ok = other                 # repay, debt-free withdrawal and removal, repayAllAndWithdraw, liquidation
deploy_ok = And(other, Not(fz))
# MATH-AR-64 verifies: REQ-ADAPTER-082, REQ-MREG-023, REQ-PROXY-099, INV-081
prove('MATH-AR-64a', 'exits and liquidation succeed for a frozen wallet exactly when they would for an unfrozen one',
      [], exit_ok == other)
prove('MATH-AR-64b', 'a frozen wallet opens no new exposure: no borrow, no withdraw-with-debt, no repay with collateral, no proxy, pledge only as rescue',
      [fz], And(Not(borrow_ok), Not(wd_debt_ok), Not(rwc_ok), Not(deploy_ok), Implies(pledge_ok, resc)))
prove('MATH-AR-64c', 'unfrozen wallets are unaffected by the freeze check', [Not(fz)],
      And(borrow_ok == other, pledge_ok == other, deploy_ok == other))

# MATH-AR-65  MarketRegistry and ParameterStore figures on the risk pages.
active_keepers = 4 - 1
# MATH-AR-65 verifies: REQ-MREG-021, REQ-MREG-031, REQ-PSTORE-022, REQ-PSTORE-016, Q-399, Q-400
computed('MATH-AR-65', 'registry and parameter-store examples',
         [('REQ-MREG-021 (Q-400): 4 approved, 1 frozen, keeperFloor 1: freezing one more leaves 2 >= 1 (allowed)',
           (False, 3, 1), (active_keepers - 1 < 1, active_keepers, 1)),
          ('Q-400: with 1 unfrozen keeper, freezing it succeeds (no floor on a freeze) and leaves 0, so new borrowing halts',
           0, 1 - 1),
          ('Q-400: MAX_KEEPERS 32', 32, 32),
          ('REQ-MREG-031: 3 Active + 1 Offboarding markets', 4, 3 + 1),
          ('REQ-PSTORE-022: target 1e18 is not > 1e18 (OutOfBounds)', False, 10**18 > 10**18),
          ('REQ-PSTORE-022: launch 1.10e18 and 200 bps within bounds', True, 110 * 10**16 > 10**18 and 200 <= 200 < BPS),
          ('REQ-PSTORE-016 (Q-399): one pool-share value, poolShareMaxBps 1,000 (the gate and the cap)', True,
           1000 >= 1000),
          ('launch breakerDeficitMax 10,000 GHO inside its bound', True, 0 <= 10_000 <= 100_000)])

finish()
