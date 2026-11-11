# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-01 Stablecoin depegs: USDC to 0.87 (March 2023 path), USDT to 0.95, GHO to 0.97 and 0.90.

Feeds work normally (hourly primaries, alternate TOKEN/X x X/USD routes). The GSM freezes when
its Chainlink price leaves 0.99-1.01 (unfreezes inside 0.995-1.005); outside arbitrage fills GSM
headroom while the underlying trades below 1 - fee. 72h event + 24h run-off, 5-minute steps,
seeds 11/22/33, 200 accounts (20% holding two markets), 2M GHO drawn. Sweeps poolRiskFactor
0.20-0.40 at GSM fee 0.10%, plus GSM fee 0% at 0.40; then the agreement tolerance from 0.25% up
to its on-chain lower bound (Q-184) on the USDC path.
"""
from dataclasses import replace

from _simcore import (Params, PRFS, USDC_MAR2023, Checks, dai_from_usdc, flat_paths, piecewise, run_many,
                      std_row, STD_HEAD, table)

HZ = 96


def usdc_path(p):
    def mk(rng):
        u = piecewise(USDC_MAR2023, HZ, p.step, rng, 0.02)
        d = flat_paths(HZ, p.step, rng)
        d['USDC'], d['DAI'] = u, dai_from_usdc(u)
        return d
    return mk


def single(p, tok, pts):
    def mk(rng):
        d = flat_paths(HZ, p.step, rng)
        d[tok] = piecewise(pts, HZ, p.step, rng, 0.02)
        return d
    return mk


def main():
    base = Params()
    paths = [
        ('USDC -> 0.87 (Mar-2023), DAI follows', usdc_path(base)),
        ('USDT -> 0.95', single(base, 'USDT', [(0, 1), (12, 0.95), (36, 0.95), (60, 0.99), (72, 1.0)])),
        ('GHO -> 0.97', single(base, 'GHO', [(0, 1), (6, 0.97)])),
        ('GHO -> 0.90', single(base, 'GHO', [(0, 1), (12, 0.90)])),
    ]
    ck = Checks('sim01_depeg')
    results = {}
    for name, fn in paths:
        rows = []
        for prf in PRFS:
            for fee in ((0.0, 0.001) if prf == 0.40 else (0.001,)):
                p = replace(base, prf=prf, gsm_fee=fee)
                a = run_many(p, fn)
                results[(name, prf, fee)] = a
                rows.append([f'{prf:.2f}', f'{p.cf:.4f}', f'{fee:.2%}'] + std_row(a)
                            + [f"{a['topup_calls']:.1f}", f"{a['avana_fee']:,.0f}",
                               ' '.join(f"{k}:{v:.0f}" for k, v in sorted(a['routes'].items()))])
        table(['prf', 'CF', 'gsm_fee'] + STD_HEAD + ['topup_calls', 'avana_fee', 'legs_by_route'], rows,
              f'== {name}')
    rows, dis = [], {}
    tols = (0.0025, 0.005, 0.01, None)
    for tol in tols:
        p = replace(base, tol_override=tol)
        a = run_many(p, usdc_path(p))
        dis[tol] = a
        rows.append(['lower bound (2.25%)' if tol is None else f'{tol:.2%}'] + std_row(a)
                    + [f"{a['blocked_h']['disagree']:.1f}", f"{a['dis_h']['DAI/USDC']:.1f}",
                       f"{a['dis_h']['USDC/USDT']:.1f}"])
    table(['tolerance'] + STD_HEAD + ['disagree_blk_acct_h', 'DAI/USDC dis_h', 'USDC/USDT dis_h'], rows,
          '== feed-agreement tolerance during the USDC path (prf 0.40); values below 2.25% are under the '
          'on-chain lower bound and shown for comparison')

    worst = max(a['bad_debt_max'] for a in results.values())
    # SIM-01A verifies: Q-020, Q-072, Q-177, Q-186
    ck.check('SIM-01A', 'no bad debt for any brief depeg path at poolRiskFactor 0.20-0.40 (both GSM fees)',
             worst == 0, detail=f'worst bad debt across seeds = {worst:,.2f} GHO')
    blk = {k: a['blocked_n'] for k, a in results.items()}
    nfloor = max(b['floor'] + b['route'] for b in blk.values())
    tops = max(a['topup_calls'] for a in results.values())
    # SIM-01B verifies: Q-085, Q-159, Q-198, Q-250, Q-251, SPEC-LIQ-005, SPEC-LIQ-018, LIQ-044
    ck.check('SIM-01B', 'no liquidation left unsettled by the recovery floor, a per-leg minimum or a route '
             'failure in the brief depeg paths (slippage allowance 1%, minimum bonus 2%)', nfloor == 0,
             detail=f'max accounts blocked per run = {nfloor:.1f}; calls needing a shortfall top-up = {tops:.1f}')
    usdc = [a for k, a in results.items() if k[0].startswith('USDC')]
    dex = sum(a['routes'].get('dex', 0) for a in usdc)
    unset = max(a['blocked_n']['route'] + a['blocked_n']['floor'] for a in usdc)
    # SIM-01C verifies: Q-062, Q-084, Q-187, Q-273, REQ-ROUTE-003, REQ-ROUTE-043
    ck.check('SIM-01C', 'when the USDC GSM freezes, every USDC and DAI leg settles on its independent backup '
             'route (none left without a route)', dex > 0 and unset == 0,
             detail=f'{dex:.0f} legs (sum over prf/fee, mean over seeds) settled on the backup DEX route; the DAI '
                    'primary (LitePSM -> USDC GSM) freezes with the USDC GSM, and its backup avoids both')
    g = results[('GHO -> 0.90', 0.40, 0.001)]
    # SIM-01D verifies: Q-177, Q-100
    ck.check('SIM-01D', 'GHO below peg liquidates no account that is solvent in GHO terms',
             g['liq'] == 0, expect='Counterexample',
             detail=f"prf 0.40: {g['liq']:.1f} liquidations, borrower loss {g['borrower_loss']:,.0f} USD; GHO "
                    'debt is fixed at $1 (Q-100) while the GHO leg follows Chainlink below $1 (Q-177)')
    lb = dis[None]['blocked_n']['disagree']
    below = {t: dis[t]['blocked_n']['disagree'] for t in tols if t is not None}
    # SIM-01E verifies: Q-162, Q-184, Q-199, SPEC-ORC-003, REQ-ORACLE-022, REQ-ORACLE-053
    ck.check('SIM-01E', 'at the on-chain tolerance lower bound (primary + alternate deviation thresholds + 50 bps) '
             'the disagreement pause blocks no liquidation during the USDC depeg', lb == 0,
             detail=f'accounts blocked at the lower bound: {lb:.1f}; below the bound: '
                    + ', '.join(f'{t:.2%}: {v:.1f}' for t, v in below.items()))
    ck.finish()


if __name__ == '__main__':
    main()
