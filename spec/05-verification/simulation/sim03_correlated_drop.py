# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-03 Correlated drop of both legs (the pool TWAP cannot see it; the USD band can, Q-176, Q-275).

USDC, USDT and DAI fall together to `depth` over 6h from t = 2h, hold 24h, recover by 48h (GHO
stays at $1). USDC/USDT and DAI/USDC keep their ratio, so the TWAP guard is blind; the USD band
(LP level per $1 at peg below usdBandLow 0.90 on uncapped quotes) moves the market to Drifting,
which blocks borrowing while liquidation continues. Feeds either update normally (fresh) or stall
silently for 12h from t = 2h across the provider. An opportunistic borrower (up to $5M of LP
bought at market) borrows at HF 1.10 on the served price wherever borrowing is open (Live, every
leg within borrowPriceMaxAge, no breaker, no pause) and that borrow exceeds the LP's market
value, and never repays. 60% of the 2M line is drawn so there is headroom.
Horizon 72h, 10-minute steps, seeds 11/22/33.
"""
from dataclasses import replace

from _simcore import H, PRFS, Checks, Params, flat_paths, piecewise, run_many, std_row, STD_HEAD, table

HZ = 72
DEPTHS = (0.95, 0.90, 0.80, 0.60, 0.45)


def corr(p, depth):
    def mk(rng):
        d = flat_paths(HZ, p.step, rng)
        pts = [(0, 1.0), (2, 1.0), (8, depth), (32, depth), (50, 1.0)]
        common = piecewise(pts, HZ, p.step, rng, 0.01)
        for t in ('USDC', 'USDT', 'DAI'):
            d[t] = [c * (1 + rng.gauss(0, 0.0003)) for c in common]
        return d
    return mk


def main():
    base = Params(step=600, drawn=0.6, attack=dict(start=2 * H, usd=5e6))
    ck = Checks('sim03_correlated_drop')
    res = {}
    rows = []
    for depth in DEPTHS:
        for feeds in ('fresh', 'silent 12h'):
            out = None if feeds == 'fresh' else dict(start=2 * H, end=14 * H, mode='silent')
            for prf in PRFS:
                p = replace(base, prf=prf)
                a = run_many(p, corr(p, depth), outage=out)
                res[(depth, feeds, prf)] = a
                st = a['state_steps']['USDC/USDT']
                rows.append([f'{depth:.2f}', feeds, f'{prf:.2f}'] + std_row(a)
                            + [f"{st['Live']}/{st['Drifting']}/{st['Cached']}/{st['Expired']}",
                               f"{a['borrow_stale_h']['USDC/USDT']:.2f}", f"{a['borrow_below_band_h']['USDC/USDT']:.2f}",
                               f"{a['attack_borrow']:,.0f}", f"{a['attack_borrow'] - a['attack_cost']:,.0f}"])
    table(['depth', 'feeds', 'prf'] + STD_HEAD + ['USDC/USDT L/D/C/E', 'borrow_stale_h', 'borrow_below_band_h',
                                                  'atk_borrow', 'atk_profit'],
          rows, '== correlated drop of USDC, USDT, DAI (GHO at $1)')

    bb = max(res[(d, 'fresh', prf)]['borrow_below_band_h'][m] for d in DEPTHS for prf in PRFS
             for m in ('USDC/USDT', 'DAI/USDC'))
    dr = {d: res[(d, 'fresh', 0.40)]['state_steps']['USDC/USDT']['Drifting'] for d in DEPTHS}
    # SIM-03A verifies: Q-176, Q-195, Q-275, SPEC-ORC-010, SPEC-ORC-011, REQ-ORACLE-015
    ck.check('SIM-03A', 'with fresh feeds, borrowing is never open on USDC/USDT or DAI/USDC while the true LP level '
             'is more than 1% below the 0.90 USD band (the TWAP cannot see a correlated drop; the band does)',
             bb == 0, detail=f'max hours borrowable below the band = {bb:.2f}; USDC/USDT Drifting steps by depth (seed 11): '
                             + ', '.join(f'{d:.2f}: {v}' for d, v in dr.items()))
    w = max(res[(d, 'fresh', prf)]['bad_debt_max'] for d in (0.95, 0.90, 0.80) for prf in PRFS)
    # SIM-03B verifies: Q-112, Q-020, Q-186, Q-195
    ck.check('SIM-03B', 'with fresh feeds a correlated drop to 0.80 creates no bad debt (prf 0.20-0.40)', w == 0,
             detail=f'worst = {w:,.0f} GHO')
    ls = max(res[(d, 'silent 12h', prf)]['borrow_stale_h'][m] for d in DEPTHS for prf in PRFS
             for m in ('USDC/USDT', 'DAI/USDC', 'USDC/GHO', 'USDT/GHO'))
    lim = (4200 + base.step) / H
    # SIM-03C verifies: Q-182, Q-274, Q-241, ATTACK-056, INV-023
    ck.check('SIM-03C', 'during a silent 12h stall, borrowing is open on a served price more than 1% above market '
             'for at most borrowPriceMaxAge (70 minutes) plus one step', ls <= lim,
             detail=f'max hours open on a served price > 1% above market = {ls:.2f} (bound {lim:.2f}); under a 24h '
                    'heartbeat and a 1h margin this was 9.4h')
    prof = {prf: res[(0.45, 'silent 12h', prf)]['attack_borrow'] - res[(0.45, 'silent 12h', prf)]['attack_cost']
            for prf in PRFS}
    bd = {prf: res[(0.45, 'silent 12h', prf)]['bad_debt'] for prf in PRFS}
    # SIM-03D verifies: Q-182, Q-274, Q-020, Q-186, ATTACK-056
    ck.check('SIM-03D', 'stale-price borrowing during a silent stall is unprofitable to default on at every prf '
             '(drop to 0.45)', all(v <= 0 for v in prof.values()),
             detail='attacker borrow - LP cost by prf: ' + ', '.join(f'{k}: {v:,.0f}' for k, v in prof.items())
                    + '; mean bad debt: ' + ', '.join(f'{k}: {v:,.0f}' for k, v in bd.items())
                    + '. Profitable only when market/served < CF/1.10 (0.28 at prf 0.40) within 70 minutes of the '
                      'last round')
    ck.finish()


if __name__ == '__main__':
    main()
