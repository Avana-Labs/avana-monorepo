# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-05 Gas spikes vs small and dust positions (Q-098, Q-169, Q-277), target HF, and the budget sub-cap.

Part A - one liquidation, deterministic: debt 10 ... 25,000 GHO in USDC/USDT at HF 0.995 (bonus =
  minimum bonus), GSM route, gas 0.2 / 20 / 100 gwei, ETH $3,000, 1.15M gas (650k base + 2 GSM
  legs). Keeper P&L after Avana's fee from oracle value (Q-256) and the break-even minimum bonus.
Part B - populations under stress, prf 0.40, 10-minute steps, seeds 11/22:
  default    - 200 accounts, 25% of them 100-1,500 GHO;
  dust-heavy - 600 accounts, 80% of them 10-1,000 GHO (no minimum debt; $10 minimum pledge).
  Paths: 'stress' USDC and USDT fall together to 0.93 over 6h and recover by 48h; 'tail'
  USDT -> 0.02 over 48h. Approved keepers 'obliged' (keeper agreement: liquidate every HF < 1
  account, reimbursed) or 'rational' (skip loss-making calls); the permissionless fallback acts
  only when paid.
Part C - aaveTargetHealthFactor vs repeated partial liquidations on the tail path (20 gwei).
Part D - SettlementBudget per-market sub-cap (Q-267): dust-heavy book on the tail path with the
  USDT backup route 6% below market, so dust calls need the caller's shortfall top-up and the
  rounding gap of each such call is drawn from the budget.
"""
import random
from dataclasses import replace

from _simcore import (H, Account, Checks, Params, Sim, flat_paths, piecewise, run_many, std_row, STD_HEAD,
                      table, MARKETS, TOKENS)

HZ = 74


def one_liq(p, debt, hf=0.995):
    paths = {k: [1.0] * 8 for k in TOKENS}
    acct = Account(0, {'USDC/USDT': debt * hf / p.cf}, {'GHO': debt}, debt, False, 0)
    sim = Sim(p, paths, 1, accounts=[acct])
    m = {k: 1.0 for k in TOKENS}
    sim._update_market(0, m)
    sim.tpx = {k: 1.0 for k in MARKETS}
    sim.liquidate(acct, 'USDC/USDT', 'GHO', 0, 0, m)
    repay = sim.r['liq_repay'][0] if sim.r['liq_repay'] else 0.0
    return repay, sim.r['keeper_pnl'], sim.r['gas']


def breakeven(p, debt):
    lo, hi = 0.0, 6.0
    for _ in range(40):
        mid = (lo + hi) / 2
        q = replace(p, min_bonus=mid, max_bonus=max(p.max_bonus, mid))
        if one_liq(q, debt)[1] >= 0:
            hi = mid
        else:
            lo = mid
    return hi


def stress(p):
    def mk(rng):
        d = flat_paths(HZ, p.step, rng)
        c = piecewise([(0, 1), (2, 1), (8, 0.93), (32, 0.93), (50, 1.0)], HZ, p.step, rng, 0.01)
        d['USDC'] = list(c)
        d['USDT'] = [x * (1 + rng.gauss(0, 0.0003)) for x in c]
        d['DAI'] = list(c)
        return d
    return mk


def tail(p):
    def mk(rng):
        d = flat_paths(HZ, p.step, rng)
        d['USDT'] = piecewise([(0, 1), (2, 1), (8, 0.90), (26, 0.40), (50, 0.02)], HZ, p.step, rng, 0.02)
        return d
    return mk


def main():
    ck = Checks('sim05_gas_dust')
    base = Params(step=600, prf=0.40)
    rows, be = [], {}
    for debt in (10, 100, 500, 1000, 2500, 5000, 25000):
        for g in (0.2, 20, 100):
            cells = [f'{debt:,}', f'{g:g}']
            for mb in (0.01, 0.02, 0.03):
                p = replace(base, gwei=g, min_bonus=mb)
                cells.append(f'{one_liq(p, debt)[1]:,.2f}')
            p = replace(base, gwei=g)
            repay, _, gas = one_liq(p, debt)
            b = breakeven(p, debt)
            be[(debt, g)] = b
            rows.append(cells + [f'{repay:,.0f}', f'{gas:,.2f}', f'{b:.2%}' if b < 5.99 else '> 600%'])
    table(['debt', 'gwei', 'pnl@1%', 'pnl@2%', 'pnl@3%', 'repay', 'gas_usd', 'breakeven_min_bonus'], rows,
          '== A. one liquidation at HF 0.995 (bonus = minimum bonus), keeper P&L in USD')

    pops = {
        'default': dict(),
        'dust-heavy': dict(n_accounts=600, small_share=0.8, small_range=(10.0, 1000.0)),
    }
    res = {}
    rows = []
    for pname, pfn in (('stress', stress), ('tail', tail)):
        for popn, kw in pops.items():
            for g in (0.2, 20, 100):
                for mode in ('obliged', 'rational'):
                    p = replace(base, gwei=g, keeper_mode=mode, **kw)
                    a = run_many(p, pfn(p), seeds=(11, 22))
                    res[(pname, popn, g, mode)] = a
                    rows.append([pname, popn, f'{g:g}', mode] + std_row(a)
                                + [f"{a['gas']:,.0f}", f"{a['blocked_h']['unprofitable']:.0f}"])
    table(['path', 'population', 'gwei', 'keepers'] + STD_HEAD + ['gas_usd', 'unprof_acct_h'], rows,
          '== B. populations, prf 0.40, minimum bonus 2%, target HF 1.10')

    rows, tre = [], {}
    for thf in (1.02, 1.05, 1.10, 1.20):
        p = replace(base, target_hf=thf, gwei=20)
        a = run_many(p, tail(p))
        tre[thf] = a
        rows.append([f'{thf:.2f}'] + std_row(a) + [f"{a['gas']:,.0f}"])
    table(['target_hf'] + STD_HEAD + ['gas_usd'], rows,
          '== C. target HF vs repeated partial liquidations, tail path, 20 gwei')

    rows, bud = [], {}
    for label, kw in (('caps 25 / 500 / sub-cap 125', {}),
                      ('no per-market sub-cap', dict(min_market_cap=500.0))):
        p = replace(base, gwei=20, dex_discount={'USDT': 0.06}, n_accounts=600, small_share=0.8,
                    small_range=(10.0, 1000.0), **kw)
        a = run_many(p, tail(p), seeds=(11, 22))
        bud[label] = a
        rows.append([label] + std_row(a) + [f"{a['topup_calls']:.0f}", f"{a['budget_draws_n']:.0f}",
                                            f"{a['budget_by_mkt_max']:.2f}", f"{a['budget_refused']:.0f}"])
    table(['budget'] + STD_HEAD + ['topup_calls', 'draws', 'max_market_draw', 'caller_covered'], rows,
          '== D. SettlementBudget draws, dust-heavy tail with the USDT backup route 6% below market (prf 0.40)')

    ok = {g: be[(1000, g)] <= base.max_bonus for g in (0.2, 20, 100)}
    # SIM-05A verifies: Q-098, Q-169, Q-179, Q-256, Q-277, ATTACK-064
    ck.check('SIM-05A', 'a minimum bonus within the 5% maximum bonus covers keeper gas, GSM fee and Avana fee for a '
             '1,000 GHO liquidation at 0.2, 20 and 100 gwei', all(ok.values()), expect='Counterexample',
             detail='break-even minimum bonus at 1,000 GHO: ' + ', '.join(f'{g:g} gwei {be[(1000, g)]:.2%}' for g in ok)
                    + f"; at 100 GHO: {be[(100, 0.2)]:.2%} / {be[(100, 20)]:.1%} / "
                    + (f"{be[(100, 100)]:.0%}" if be[(100, 100)] < 5.99 else '> 600%'))
    dh = res[('stress', 'dust-heavy', 100, 'obliged')]
    df = res[('stress', 'default', 100, 'obliged')]
    # SIM-05B verifies: Q-169, Q-098, Q-277, Q-249
    ck.check('SIM-05B', 'with obliged keepers, dust loans add no bad debt in the stress and tail paths (any gas)',
             max(res[(pn, 'dust-heavy', g, 'obliged')]['bad_debt_max'] for pn in ('stress', 'tail') for g in (0.2, 20, 100)) == 0,
             detail=f"cost is reimbursement instead: stress path at 100 gwei, dust-heavy reimbursement "
                    f"{dh['reimburse']:,.0f} USD vs default {df['reimburse']:,.0f} USD")
    rt = res[('tail', 'dust-heavy', 100, 'rational')]
    # SIM-05C verifies: Q-169, Q-098, Q-101, Q-213, Q-277, ATTACK-064
    ck.check('SIM-05C', 'if approved keepers skip loss-making calls (reimbursement late or capped), dust loans create '
             'no bad debt in the tail path at 100 gwei', rt['bad_debt_max'] == 0, expect='Counterexample',
             detail=f"dust-heavy, rational keepers, 100 gwei: bad debt {rt['bad_debt']:,.0f} GHO mean, "
                    f"{rt['blocked_n']['unprofitable']:.0f} accounts skipped")
    r = [tre[t]['reimburse'] for t in (1.02, 1.05, 1.10, 1.20)]
    # SIM-05D verifies: Q-185, Q-098, Q-072
    ck.check('SIM-05D', 'raising the target health factor reduces keeper reimbursement in a slow collapse (fewer '
             'repeat calls)', all(r[i] >= r[i + 1] for i in range(3)),
             detail='reimbursement by target 1.02/1.05/1.10/1.20: ' + ' / '.join(f'{x:,.0f}' for x in r)
                    + '; liquidations: ' + ' / '.join(f"{tre[t]['liq']:.0f}" for t in (1.02, 1.05, 1.10, 1.20)))
    bc, bn = bud['caps 25 / 500 / sub-cap 125'], bud['no per-market sub-cap']
    sub = max(base.min_market_cap, base.budget_per_day // 4)
    # SIM-05E verifies: Q-267, Q-251, SPEC-SET-001, SPEC-SET-006, LIQ-041, LIQ-042
    ck.check('SIM-05E', 'in a dust wave whose calls need shortfall top-ups, every market stays within its 24h '
             'sub-cap, no liquidation is lost to the budget caps and bad debt is unchanged',
             bc['max_mkt_window'] <= sub + 1e-6 and abs(bc['bad_debt'] - bn['bad_debt']) <= 1
             and bc['blocked_n']['floor'] + bc['blocked_n']['route'] == 0,
             detail=f"top-up calls {bc['topup_calls']:.0f}, draws {bc['budget_draws_n']:.0f} totalling "
                    f"{bc['budget_draw']:,.2f} GHO, largest market draw in any 24h {bc['max_mkt_window']:,.2f} GHO "
                    f"(sub-cap {sub:.0f} GHO), {bc['budget_refused']:.0f} calls where the caller covered the gap "
                    f"with its own GHO; bad debt {bc['bad_debt']:,.0f} vs {bn['bad_debt']:,.0f} without a sub-cap")
    ck.finish()


if __name__ == '__main__':
    main()
