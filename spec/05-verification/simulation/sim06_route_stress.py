# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-06 Route stress: frozen GSM, thin or dislocated backup route, shortfall top-up, in-kind settlement.

USDT depegs from t = 2h; the USDT GSM freezes below 0.99 (outside arbitrage drains its headroom
before that), so every USDT leg needs the backup DEX route, which never trades through the
market's own pool (Q-273). The backup is drained to 100% / 10% / 1% of its normal $3M-per-1%
depth (x0.25 while USDT is off peg), runs a fixed discount below market (a dislocated venue), or
reverts outright. Every leg must meet its oracle minimum (Q-250); a keeper answers a floor failure
with a shortfall top-up of up to maxShortfallBps (10%) of the seized value (Q-251), else reports
the shortfall; reports persisting 6h with no gap over 1h open in-kind settlement on a market whose
trigger is approved (inKindAutoDelay), and governance can open it at the 12h short delay; each
opening lasts 24h (inKindExpiry). In kind, the keeper repays its own GHO and takes tokens worth at
most debt x (1 + bonus) at oracle prices; the rest goes to the borrower (Q-133).
Paths: 'USDT 0.80' (to 0.80 over 12h, holds) and 'collapse' (USDT -> 0.02 over 24h).
prf 0.40, 10-minute steps, seeds 11/22/33, 74h.
Part B: manipulation of the market's own pool skews the unwound token mix; effect on the recovery
floor and the per-leg minimums.
"""
import math
from dataclasses import replace

from _simcore import H, Checks, Params, Sim, flat_paths, piecewise, run_many, std_row, STD_HEAD, table

HZ = 74


def usdt(p, pts):
    def mk(rng):
        d = flat_paths(HZ, p.step, rng)
        d['USDT'] = piecewise(pts, HZ, p.step, rng, 0.02)
        return d
    return mk


PATHS = {'USDT 0.80': [(0, 1), (2, 1), (14, 0.80)],
         'collapse': [(0, 1), (2, 1), (26, 0.02)]}


def manipulation_table():
    """USDC at 0.87 (USDC GSM frozen, USDT GSM open). Seize $50k of USDC/USDT LP at oracle; skew the pool."""
    p = Params(prf=0.40)
    n = 40
    paths = {k: [1.0] * n for k in ('USDC', 'USDT', 'DAI', 'GHO')}
    paths['USDC'] = [0.87] * n
    sim = Sim(p, paths, 1, accounts=[])
    m = {'USDC': 0.87, 'USDT': 1.0, 'DAI': 1.0, 'GHO': 1.0}
    for i in range(n):
        sim._update_market(i * p.step, m)
    vu, vt = min(sim.tev['USDC'].q, 1.0), min(sim.tev['USDT'].q, 1.0)
    seize_units = 50_000 / math.sqrt(vu * vt)
    s = p.s_eff(p.max_bonus)
    rows, out, legs_ok = [], {}, True
    for delta in (0.0, 0.02, 0.05, 0.10, 0.20):
        for sign in (+1, -1):
            if delta == 0 and sign < 0:
                continue
            P = (vu / vt) * (1 + sign * delta)
            x, y = seize_units / 2 / math.sqrt(P), seize_units / 2 * math.sqrt(P)
            head = dict(sim.gsm_head)
            mx = max(1e-18, x * vu * (1 - s) - p.floor_rounding / 2)
            my = max(1e-18, y * vt * (1 - s) - p.floor_rounding / 2)
            ox, _, rx, _ = sim._leg('USDC', x, m, head, mx)
            oy, _, ry, _ = sim._leg('USDT', y, m, head, my)
            legs_ok = legs_ok and ox is not None and oy is not None
            R = (ox or 0) + (oy or 0)
            floor = 50_000 * (1 - s) - p.floor_rounding
            r_ = 1 + sign * delta
            cost = {T: (T / 2) * (math.sqrt(r_) - 1) ** 2 / math.sqrt(r_) for T in (50e6, 5e6, 1e6)}
            out[(delta, sign)] = R / floor
            rows.append([f'{sign * delta:+.0%}', f'{x:,.0f} ({rx})', f'{y:,.0f} ({ry})', f'{R:,.0f}', f'{R / floor:.4f}']
                        + [f'{cost[T]:,.0f}' for T in (50e6, 5e6, 1e6)])
    table(['pool skew', 'USDC out', 'USDT out', 'GHO recovered', 'R/floor', 'cost/blk TVL50M', 'TVL5M', 'TVL1M'],
          rows, '== B. pool-price skew during USDC 0.87 (seize $50k at oracle, max bonus, s = 1%); '
                'cost = loss to the manipulator per block the skew is held')
    return out, legs_ok


def main():
    base = Params(step=600, prf=0.40)
    ck = Checks('sim06_route_stress')
    res = {}
    rows = []
    cases = [('depth 100%', dict()), ('depth 10%', dict(dex_drain={'USDT': 0.1})),
             ('depth 1%', dict(dex_drain={'USDT': 0.01})),
             ('discount 3%', dict(dex_discount={'USDT': 0.03})), ('discount 8%', dict(dex_discount={'USDT': 0.08})),
             ('depth 10%, s 0.5%', dict(dex_drain={'USDT': 0.1}, slippage=0.005)),
             ('depth 10%, s 2%', dict(dex_drain={'USDT': 0.1}, slippage=0.02)),
             ('discount 8%, no top-up', dict(dex_discount={'USDT': 0.08}, keeper_topup=False)),
             ('discount 15%, auto + manual', dict(dex_discount={'USDT': 0.15})),
             ('discount 15%, manual only', dict(dex_discount={'USDT': 0.15}, inkind_trigger=False)),
             ('discount 15%, none', dict(dex_discount={'USDT': 0.15}, inkind_trigger=False, inkind_manual_delay=None)),
             ('reverts, auto + manual', dict(dex_revert={'USDT': True})),
             ('reverts, none', dict(dex_revert={'USDT': True}, inkind_trigger=False, inkind_manual_delay=None))]
    for pname, pts in PATHS.items():
        for label, kw in cases:
            p = replace(base, **kw)
            a = run_many(p, usdt(p, pts))
            res[(pname, label)] = a
            rows.append([pname, label] + std_row(a)
                        + [f"{a['topup_calls']:.0f}", f"{a['shortfall_paid']:,.0f}", f"{a['reports']:.0f}",
                           f"{a['reports_failed']:.0f}", f"{a['auto_inkind']:.1f}/{a['manual_inkind']:.1f}",
                           f"{a['first_inkind_h']:.1f}",
                           ' '.join(f"{k}:{v:.0f}" for k, v in sorted(a['routes'].items()))])
    table(['path', 'USDT backup route'] + STD_HEAD + ['topups', 'topup_gho', 'reports', 'reports_fail',
                                                      'inkind auto/manual', 'first_inkind_h', 'legs_by_route'],
          rows, '== A. USDT GSM frozen; backup route drained, dislocated or reverting; top-up and in-kind (prf 0.40)')
    man, legs_ok = manipulation_table()

    keys = [(pn, l) for pn in PATHS for l in ('depth 100%', 'depth 10%', 'depth 1%', 'discount 3%', 'discount 8%',
                                             'depth 10%, s 0.5%', 'depth 10%, s 2%')]
    nb = {k: res[k]['blocked_n']['route'] + res[k]['blocked_n']['floor'] for k in keys}
    tops = sum(res[k]['topup_calls'] for k in keys)
    # SIM-06A verifies: Q-084, Q-085, Q-159, Q-250, Q-251, Q-273, LIQ-044, LIQ-076
    ck.check('SIM-06A', 'USDT GSM frozen, backup route drained to 1% of depth or 3-8% below market, slippage '
             'allowance 0.5%-2%: no liquidation left unsettled by a route, a leg minimum or the floor (both paths)',
             max(nb.values()) == 0,
             detail=f'max accounts blocked = {max(nb.values()):.1f}; {tops:.0f} calls closed the gap with a shortfall top-up')
    base_c = res[('collapse', 'depth 100%')]
    rv = res[('collapse', 'reverts, auto + manual')]
    rn = res[('collapse', 'reverts, none')]
    # SIM-06B verifies: Q-084, Q-133, Q-228, Q-251, LIQ-045, SPEC-LIQ-013, REQ-SWAP-102
    ck.check('SIM-06B', 'with both USDT routes reverting on the collapse path, in-kind settlement opened at the 12h '
             'short delay keeps bad debt at the routes-working level', rv['bad_debt_max'] <= base_c['bad_debt_max'] + 1,
             detail=f"bad debt: routes working {base_c['bad_debt']:,.0f}, reverting with in-kind "
                    f"{rv['bad_debt']:,.0f} (first opening at {rv['first_inkind_h']:.1f}h; {rv['reports_failed']:.0f} "
                    f"reports failed because a reverting route proves no shortfall), never {rn['bad_debt']:,.0f}")
    mn = min(man.values())
    # SIM-06C verifies: Q-085, Q-131, Q-159, Q-250, SPEC-LIQ-005, SPEC-LIQ-018, ATTACK-065
    ck.check('SIM-06C', 'a pool-price skew of up to +/-20% never pushes recovery below the floor or a leg below its '
             'oracle minimum (USDC 0.87, $50k seize)', mn >= 1.0 and legs_ok,
             detail=f'min R/floor = {mn:.4f}; skew raises the share of the frozen-GSM token sent to the backup, '
                    'but the LP value at oracle prices rises with any skew (the manipulator pays)')
    au, mo = res[('collapse', 'discount 15%, auto + manual')], res[('collapse', 'discount 15%, manual only')]
    nn = res[('collapse', 'discount 15%, none')]
    start_fail = 2 + (1 - 0.99) / (1 - 0.02) * 24      # USDT leaves the GSM band
    # SIM-06D verifies: Q-251, REQ-SWAP-102, REQ-SWAP-103, LIQ-078
    ck.check('SIM-06D', 'when the backup route runs more than the top-up allowance below the oracle, shortfall '
             'reports open in-kind settlement within inKindAutoDelay plus one hour of the first failure, with bad debt '
             'no higher than manual opening at the short delay',
             au['first_inkind_h'] <= start_fail + 6 + 1 + 1 and au['bad_debt_max'] <= mo['bad_debt_max'] + 1,
             detail=f"collapse, route 15% below market: first opening {au['first_inkind_h']:.1f}h (auto) vs "
                    f"{mo['first_inkind_h']:.1f}h (manual only); bad debt {au['bad_debt']:,.0f} vs {mo['bad_debt']:,.0f}, "
                    f"none {nn['bad_debt']:,.0f}; reports {au['reports']:.0f}")
    t8, n8 = res[('collapse', 'discount 8%')], res[('collapse', 'discount 8%, no top-up')]
    # SIM-06E verifies: Q-251, SPEC-LIQ-019, LIQ-076, LIQ-077, LIQ-POST-004
    ck.check('SIM-06E', 'the caller shortfall top-up keeps liquidations running at full size when the backup route '
             'is 8% below market; without it the same route blocks liquidation until in-kind opens',
             t8['blocked_n']['floor'] + t8['blocked_n']['route'] == 0 and
             n8['blocked_n']['floor'] + n8['blocked_n']['route'] > 0,
             detail=f"with top-up: {t8['topup_calls']:.0f} top-up calls paying {t8['shortfall_paid']:,.0f} GHO, bad debt "
                    f"{t8['bad_debt']:,.0f}, reimbursement {t8['reimburse']:,.0f}; without: "
                    f"{n8['blocked_n']['floor'] + n8['blocked_n']['route']:.0f} accounts blocked, bad debt "
                    f"{n8['bad_debt']:,.0f}, in-kind calls {n8['inkind']:.0f}")
    ck.finish()


if __name__ == '__main__':
    main()
