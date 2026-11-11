# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-07 Interest accrual pushing idle accounts across HF 1 (Q-096, Q-145, Q-098, Q-169).

All accounts open at t = 0 with HF >= 1.10 (no drifted accounts); 70% are idle and never
react. Prices stay at peg with small noise; feeds and keepers work. The GHO rate (base plus
risk premium, Q-096) is a flat APR of 6% / 9% / 12%. Two years, 12-hour steps, seeds 11/22,
gas 20 gwei (also 0.2 gwei at prf 0.40), minimum bonus 2%, target HF 1.10.
"""
from dataclasses import replace

from _simcore import PRFS, Checks, Params, flat_paths, run_many, std_row, STD_HEAD, table

HZ = 2 * 365 * 24


def main():
    base = Params(step=12 * 3600, drifted_share=0.0)
    ck = Checks('sim07_interest_accrual')
    res = {}
    rows = []
    for apr in (0.06, 0.09, 0.12):
        for prf in PRFS:
            for g in ((20, 0.2) if prf == 0.40 else (20,)):
                p = replace(base, apr=apr, prf=prf, gwei=g)
                a = run_many(p, lambda rng, p=p: flat_paths(HZ, p.step, rng), seeds=(11, 22))
                res[(apr, prf, g)] = a
                rows.append([f'{apr:.0%}', f'{prf:.2f}', f'{g:g}', f"{a['first_liq_days']:.0f}"] + std_row(a)
                            + [f"{a['keeper_pnl_min']:,.0f}"])
    table(['apr', 'prf', 'gwei', 'first_liq_day'] + STD_HEAD + ['worst_call_pnl'], rows,
          '== idle accounts under interest accrual (2 years)')
    fl = min(a['first_liq_days'] for a in res.values() if a['first_liq_days'] == a['first_liq_days'])
    # SIM-07A verifies: Q-018, Q-096, Q-145
    ck.check('SIM-07A', 'no account opened at HF >= 1.10 reaches liquidation within 6 months at APR <= 12%',
             fl >= 182, detail=f'earliest interest-driven liquidation: day {fl:.0f} (ln(1.10)/APR years for an '
                                'account opened at exactly 1.10)')
    bd = max(a['bad_debt_max'] for a in res.values())
    # SIM-07B verifies: Q-096, Q-098, Q-101
    ck.check('SIM-07B', 'interest-driven liquidations create no bad debt (prf 0.20-0.40)', bd == 0,
             detail=f'worst = {bd:,.0f} GHO')
    a20 = res[(0.12, 0.40, 20)]
    # SIM-07C verifies: Q-098, Q-169, Q-179, Q-249, ATTACK-064
    ck.check('SIM-07C', 'every interest-driven liquidation is keeper-profitable at 20 gwei with a 2% minimum bonus',
             a20['keeper_pnl_min'] >= 0, expect='Counterexample',
             detail=f"APR 12%, prf 0.40: {a20['liq']:.0f} liquidations, keeper P&L {a20['keeper_pnl']:,.0f} USD, "
                    f"worst call {a20['keeper_pnl_min']:,.0f} USD, Avana reimbursement {a20['reimburse']:,.0f} USD; at "
                    f"0.2 gwei reimbursement {res[(0.12, 0.40, 0.2)]['reimburse']:,.0f} USD")
    ck.finish()


if __name__ == '__main__':
    main()
