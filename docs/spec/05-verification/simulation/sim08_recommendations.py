# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-08 Launch values against the engine: thresholds, cap sizing, floor and slippage, keeper break-even.

A. Insolvency threshold: the single-token price at which an account opened at HF 1.10 has
   collateral worth less than its debt (full range: value = sqrt(p0*p1)), by poolRiskFactor
   (0.45 and 0.50 are above the 0.40 on-chain bound and shown for comparison).
B. Cap sizing (Q-192, Q-249): the incident term's loss factor over the 48h window for the LP drops
   of the simulated paths, and the tail term CF (debt can reach collateral x CF before liquidation); measured bad debt per $
   of USDT exposure when USDT -> 0.02 with working feeds and during a 48h fail-mode outage.
C. Minimum bonus x slippage allowance (effective s = min(s, 1 - (1 + costs)/(1 + bonus))):
   liquidations blocked by the recovery floor on the USDC March-2023 path (USDC GSM frozen, backup
   route, oracle lag up to the 0.25% deviation threshold), prf 0.40, no shortfall top-up, no in-kind.
D. Keeper break-even with a 2% minimum bonus: smallest debt whose full (dust-rule) and partial
   liquidation covers gas, by gas price.
"""
import math
import random
from dataclasses import replace

from _simcore import H, MARKETS, Checks, Params, make_accounts, run_many, table, token_exposure
from sim01_depeg import usdc_path
from sim02_oracle_outage import tail
from sim05_gas_dust import one_liq

PRF_GRID = (0.10, 0.20, 0.30, 0.40, 0.45, 0.50)
DROPS = (('USDC 0.87 (brief)', 1 - math.sqrt(0.87)), ('correlated 0.80', 0.20), ('correlated 0.60', 0.40),
         ('USDT 0.02 (tail)', 1 - math.sqrt(0.02)))


def loss_factor(cf, lb, d_lp, h0=0.95, g=0.0):
    """Q-192 pause-loss bound per unit of debt: max(0, (1 + g) - h0 (1 - dLP) / (CF x LB))."""
    return max(0.0, (1 + g) - h0 * (1 - d_lp) / (cf * lb))


def main():
    ck = Checks('sim08_recommendations')
    base = Params(step=600)
    rows, pstar = [], {}
    for prf in PRF_GRID:
        p = replace(base, prf=prf)
        ps = (p.cf / p.min_open_hf) ** 2
        pstar[prf] = ps
        rows.append([f'{prf:.2f}' + ('' if prf <= 0.40 else ' (above bound)'), f'{p.cf:.4f}',
                     f'{p.cf / p.min_open_hf:.4f}', f'{ps:.4f}', f'{1 - 1 / p.min_open_hf:.1%}',
                     f'{(1 / p.min_open_hf) ** 2:.3f}'])
    table(['prf', 'CF', 'max debt/value at open', 'insolvent if one token <', 'value drop to HF 1',
           'one token price at HF 1'], rows, '== A. thresholds for an account opened at HF 1.10')

    rows, lf = [], {}
    for prf in PRF_GRID[:4]:
        p = replace(base, prf=prf)
        lfs = [loss_factor(p.cf, 1 + p.max_bonus, d) for _, d in DROPS]
        lf[prf] = lfs
        tail_f = p.cf
        rows.append([f'{prf:.2f}', f'{p.cf:.4f}'] + [f'{x:.3f}' for x in lfs]
                    + [f'{tail_f:.4f}', f'{400_000 / tail_f:,.0f}'])
    table(['prf', 'CF'] + [f'incident loss factor, {n} (dLP {d:.1%})' for n, d in DROPS]
          + ['tail factor CF', 'token cap covered by 400k GHO'], rows,
          '== B1. cap-sizing terms (h0 0.95, LB 1.05, no debt-price rise)')

    rows, rate = [], {}
    for prf in PRF_GRID[:4]:
        p = replace(base, prf=prf)
        ex = token_exposure(make_accounts(p, random.Random(11)), p.cf, p.min_open_hf)['USDT']
        for label, out in (('feeds working', None),
                           ('48h outage', dict(start=2 * H, end=50 * H, mode='fail'))):
            a = run_many(p, tail(p, 2 + 48 + 48), outage=out)
            rate[(prf, label)] = a['bad_debt_max'] / ex
            rows.append([f'{prf:.2f}', label, f'{ex:,.0f}', f"{a['bad_debt']:,.0f}", f"{a['bad_debt_max']:,.0f}",
                         f"{rate[(prf, label)]:.4f}", f'{p.cf:.4f}'])
    table(['prf', 'feeds', 'USDT exposure', 'bad debt mean', 'bad debt worst', 'worst loss per $ exposure',
           'tail factor'], rows, '== B2. USDT -> 0.02: measured loss per $ of token exposure vs the tail factor (2M book)')

    rows, blk = [], {}
    for mb in (0.005, 0.01, 0.02):
        for s in (0.001, 0.0025, 0.005, 0.01):
            p = replace(base, prf=0.40, min_bonus=mb, slippage=s, keeper_topup=False, inkind_trigger=False,
                        inkind_manual_delay=None)
            a = run_many(p, usdc_path(p))
            eff = p.s_eff(mb)
            blk[(mb, s)] = a['blocked_n']['floor'] + a['blocked_n']['route']
            rows.append([f'{mb:.2%}', f'{s:.2%}', f'{eff:.2%}', f"{a['liq']:.1f}", f"{blk[(mb, s)]:.1f}",
                         f"{a['blocked_h']['floor'] + a['blocked_h']['route']:.1f}", f"{a['borrower_loss']:,.0f}"])
    table(['min_bonus', 's', 's_eff at min bonus', 'liq', 'floor_blocked_accts', 'floor_blocked_acct_h', 'borr_loss'],
          rows, '== C. recovery floor vs minimum bonus and slippage allowance (USDC path, prf 0.40, no top-up, '
                'no in-kind)')

    rows = []
    for g in (0.2, 1, 5, 20, 100):
        p = replace(base, prf=0.40, gwei=g, min_bonus=0.02)
        full = next((d for d in range(10, 1000, 10) if one_liq(p, d)[1] >= 0), None)
        part = next((d for d in (1500, 2500, 5000, 10_000, 25_000, 50_000, 100_000, 250_000, 1_000_000)
                     if one_liq(p, d)[1] >= 0), None)
        rows.append([f'{g:g}', f'{full:,}' if full else '> 1,000 (none)', f'{part:,}' if part else '> 1M'])
    table(['gwei', 'smallest profitable dust-rule (full) liquidation, GHO', 'smallest profitable partial, GHO'],
          rows, '== D. keeper break-even at HF 0.995 with a 2% minimum bonus, target HF 1.10 (USDC/USDT, GSM route)')

    # SIM-08A verifies: Q-020, Q-072, Q-186, Q-101
    ck.check('SIM-08A', 'at prf <= 0.40 a single token must fall below 0.10 before an account opened at HF 1.10 '
             'is insolvent', all(pstar[k] < 0.10 for k in PRF_GRID if k <= 0.40),
             detail=', '.join(f'{k}: {v:.4f}' for k, v in pstar.items()))
    ok = [k for k, v in blk.items() if v == 0]
    # SIM-08B verifies: Q-085, Q-159, Q-127, Q-179, Q-198
    ck.check('SIM-08B', 'a minimum bonus of at least 1% with s >= 0.5% leaves no liquidation blocked by the recovery '
             'floor on the USDC path', all(blk[(mb, s)] == 0 for mb in (0.01, 0.02) for s in (0.005, 0.01)),
             detail='zero-block (minimum bonus, s) pairs: ' + ', '.join(f'{a:.2%}/{b:.2%}' for a, b in ok))
    worst = {k: v for k, v in rate.items()}
    # SIM-08C verifies: Q-249, Q-186, SPEC-CAP-007, DEF-013
    ck.check('SIM-08C', 'the tail term CF bounds the measured loss per $ of token exposure '
             'when a pool token goes to 0.02, with or without a 48h outage (prf 0.20-0.40)',
             all(worst[(prf, l)] <= replace(base, prf=prf).cf
                 for prf in PRF_GRID[1:4] for l in ('feeds working', '48h outage')),
             detail=', '.join(f'{k[0]:.2f} {k[1]}: {v:.4f}' for k, v in worst.items() if k[0] >= 0.20))
    zero = all(x == 0 for prf in PRF_GRID[:4] for x in lf[prf][:3])
    # SIM-08D verifies: Q-192, Q-249, SPEC-CAP-007
    ck.check('SIM-08D', 'for stable pools the incident term is zero at every prf <= 0.40 for LP drops up to the '
             'correlated 0.60 path, so the tail term is the one that binds', zero,
             detail='incident loss factor at prf 0.40: ' + ', '.join(f'{n}: {x:.3f}' for (n, _), x in zip(DROPS, lf[0.40])))
    ck.finish()


if __name__ == '__main__':
    main()
