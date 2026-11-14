# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-02 Chainlink outages, stalls, a wrong primary and the DebtOracle.

Provider-wide outage: every leg of every route (primary, alternate with its X/USD leg, standby)
fails together at t = 2h. Modes:
  fail   - reads revert: the market is Cached from the first failed read for cachedWindow
           (1h, Q-183), then Expired (served price 1, Q-247);
  silent - feeds keep returning the last round: a leg fails once older than feedMaxAge
           (heartbeat + 600 s); while a token is served by its alternate, seizure also needs every
           alternate leg within borrowPriceMaxAge (Q-274).
Token-specific failures: only some routes of some tokens fail; a guardian can switch in the
token's standby route (useStandbyRoute, Q-248).
Paths start with the outage:
  brief - USDC March-2023 path (to 0.87), DAI follows;
  tail  - USDT issuer failure: USDT -> 0.02 over 48h, no recovery (a pool token going to zero,
          the tail term of the cap-sizing guidance, Q-249).
10-minute steps, seeds 11/22/33, 200 accounts (20% holding two markets), 2M GHO drawn.
"""
import random
from dataclasses import replace

from _simcore import (H, PRFS, USDC_MAR2023, TOKENS, MARKETS, Checks, Params, Sim, dai_from_usdc, flat_paths,
                      make_accounts, piecewise, run_many, std_row, STD_HEAD, table, token_exposure)

T0 = 2


def shift(pts, h0):
    return [(0, pts[0][1])] + [(h + h0, v) for h, v in pts]


def brief(p, hz, t0=T0):
    def mk(rng):
        u = piecewise(shift(USDC_MAR2023, t0), hz, p.step, rng, 0.02)
        d = flat_paths(hz, p.step, rng)
        d['USDC'], d['DAI'] = u, dai_from_usdc(u)
        return d
    return mk


TAIL_PTS = [(0, 1.0), (6, 0.90), (24, 0.40), (48, 0.02)]


def tail(p, hz, t0=T0, pts=TAIL_PTS):
    def mk(rng):
        d = flat_paths(hz, p.step, rng)
        d['USDT'] = piecewise(shift(pts, t0), hz, p.step, rng, 0.02)
        return d
    return mk


def tail_reserve(p, seed=11):
    """Tail term of the cap-sizing guidance (Q-249): the reserve that covers the largest single-token
    exposure x CF / minOpeningHealthFactor."""
    ex = token_exposure(make_accounts(p, random.Random(seed)), p.cf, p.min_open_hf)
    worst = max((v, t) for t, v in ex.items() if t != 'GHO')
    return worst[0] * p.cf / p.min_open_hf, worst[1], ex


def timeline(p, seed, outage, hz=30):
    """Oracle-only run: per market, Cached spells (start, end) and the first time after the outage start
    at which the market is neither seizable nor open for borrowing."""
    paths = flat_paths(hz, p.step, random.Random(seed))
    s = Sim(p, paths, seed, accounts=[], outage=outage)
    spells = {k: [] for k in MARKETS}
    cur = {k: None for k in MARKETS}
    closed = {k: None for k in MARKETS}
    for i in range(s.n):
        t = i * p.step
        s._update_market(t, {k: paths[k][i] for k in TOKENS})
        for k in MARKETS:
            st = s.o[k]['st']
            if st == 'Cached' and cur[k] is None:
                cur[k] = t
            elif st != 'Cached' and cur[k] is not None:
                spells[k].append((cur[k], t, st))
                cur[k] = None
            if t >= outage['start'] and closed[k] is None and not s.liq_ok[k] and not s.borrow_open(k, t):
                closed[k] = t - outage['start']
    return spells, closed, s.r['skipped_cached']


def main():
    base = Params(step=600)
    ck = Checks('sim02_oracle_outage')
    res = {}
    durs = (1, 6, 24, 48, 72)
    for pname, pfn in (('brief', brief), ('tail', tail)):
        rows = []
        for d in durs:
            hz = T0 + d + 48
            out = dict(start=T0 * H, end=(T0 + d) * H, mode='fail')
            for prf in PRFS:
                p = replace(base, prf=prf)
                a = run_many(p, pfn(p, hz), outage=out)
                res[(pname, d, prf)] = a
                rows.append([f'{d}h', f'{prf:.2f}', f'{p.cf:.4f}'] + std_row(a)
                            + [f"{a['max_true_underwater_h']:.1f}", f"{a['grace_starts']:.0f}"])
        table(['outage', 'prf', 'CF'] + STD_HEAD + ['max_uw_h', 'grace_starts'], rows,
              f'== provider-wide fail-mode outage, {pname} path (cachedWindow 1h, grace 30 min below HF 0.95)')

    rows, tr = [], {}
    for prf in PRFS:
        p = replace(base, prf=prf)
        need, tok, ex = tail_reserve(p)
        tr[prf] = (need, tok, ex)
        a = res[('tail', 48, prf)]
        rows.append([f'{prf:.2f}', f"{ex['USDC']:,.0f}", f"{ex['USDT']:,.0f}", f"{ex['DAI']:,.0f}", tok,
                     f'{need:,.0f}', f"{a['bad_debt_max']:,.0f}", f"{400_000 / (p.cf / p.min_open_hf):,.0f}"])
    table(['prf', 'USDC exposure', 'USDT exposure', 'DAI exposure', 'largest', 'tail-term reserve',
           'tail+48h outage bad debt (worst seed)', 'token cap covered by 400k'], rows,
          '== tail term (Q-249) for the 2M book vs the simulated tail with a 48h outage')

    # Grace sweep (fail mode, 24h outage, prf 0.40), within the liveness bounds (graceDuration <= 2h, HF >= 0.90)
    rows, gr = [], {}
    for pname, pfn in (('brief', brief), ('tail', tail)):
        for g, ghf in ((0, 0.95), (1800, 0.95), (7200, 0.95), (1800, 0.90), (7200, 0.90)):
            p = replace(base, grace=g, grace_hf=ghf)
            hz = T0 + 24 + 48
            a = run_many(p, pfn(p, hz), outage=dict(start=T0 * H, end=(T0 + 24) * H, mode='fail'))
            gr[(pname, g, ghf)] = a
            rows.append([pname, f'{g // 60}m', f'{ghf:.2f}'] + std_row(a) + [f"{a['blocked_n']['grace']:.1f}",
                                                                            f"{a['grace_starts']:.0f}"])
    table(['path', 'grace', 'grace_hf'] + STD_HEAD + ['grace_blk_accts', 'grace_starts'], rows,
          '== grace sweep (fail mode, 24h provider-wide outage, prf 0.40)')

    # Cached spells and closing time, oracle only, 40 seeds x {fail, silent}
    rows, worst_close, min_spell, skipped, spells_n = [], {}, {}, {}, {}
    for mode in ('fail', 'silent'):
        wc, ms, sk, nsp = 0.0, float('inf'), 0, 0
        for sd in range(40):
            start = (2 + random.Random(sd).uniform(0, 3)) * H
            sp, cl, skp = timeline(base, sd, dict(start=start, end=start + 12 * H, mode=mode))
            sk += skp
            for k in MARKETS:
                wc = max(wc, cl[k] if cl[k] is not None else float('inf'))
                for a_, b_, nxt in sp[k]:
                    nsp += 1
                    if nxt == 'Expired':
                        ms = min(ms, b_ - a_)
        worst_close[mode], min_spell[mode], skipped[mode], spells_n[mode] = wc, ms, sk, nsp
        rows.append([mode, nsp, f'{ms / 60:.0f} min', sk, f'{wc / 60:.0f} min'])
    table(['mode', 'Cached spells', 'shortest spell before Expired', 'failures straight to Expired',
           'latest stop of seizure and borrowing after the stall'], rows,
          '== provider-wide outage, 40 random heartbeat phases and start times (oracle only)')

    # Token-specific stall of USDT (primary, USDT/BTC leg and standby; BTC/USD keeps updating) during a collapse
    rows, ts = [], {}
    pm = replace(base, multi_share=0.6)
    for mode in ('fail', 'silent'):
        out = dict(start=T0 * H, end=(T0 + 48) * H, mode=mode, tokens=('USDT',))
        hz = T0 + 48 + 24
        a = run_many(pm, tail(pm, hz, pts=[(0, 1.0), (24, 0.02)]), outage=out)
        ts[mode] = a
        st = a['state_steps']['USDT/GHO']
        fl = a['first_liq_mkt_h']
        rows.append([mode] + std_row(a) + [f"{st['Live']}/{st['Drifting']}/{st['Cached']}/{st['Expired']}",
                                           f"{fl['USDC/GHO']:.1f}", f"{fl['DAI/USDC']:.1f}"])
    table(['USDT feeds'] + STD_HEAD + ['USDT/GHO L/D/C/E steps', 'first USDC/GHO liq h', 'first DAI/USDC liq h'],
          rows, '== USDT-only stall during USDT -> 0.02 in 24h from t = 2h, 60% two-market accounts, prf 0.40, '
                'no standby switch')

    # Fresh-but-wrong USDC primary (stuck at $1 with fresh timestamps) during the USDC depeg; standby switch
    rows, wr = [], {}
    for sd_label, sd in (('15m', 900), ('1h', H), ('4h', 4 * H), ('never', None)):
        p = replace(base, standby_route_delay=sd)
        a = run_many(p, brief(p, 96), outage=dict(start=T0 * H, end=80 * H, mode='wrong', wrong=1.0,
                                                  tokens=('USDC',), routes=('primary',)))
        wr[sd_label] = a
        rows.append([sd_label] + std_row(a) + [f"{a['blocked_h']['disagree']:.1f}", f"{a['standby_switches']:.0f}",
                                               f"{a['dis_h']['USDC/USDT']:.1f}"])
    table(['standby switch'] + STD_HEAD + ['disagree_blk_acct_h', 'switches', 'USDC/USDT dis_h'], rows,
          '== USDC primary stuck at $1 (fresh timestamps) during the USDC depeg, prf 0.40')

    # DebtOracle: both USDC routes fail for 24h during the USDC depeg; 30% of accounts owe half in USDC
    rows, dbt = [], {}
    pd_ = replace(base, usdc_debt_share=0.3, multi_share=0.4)
    for sd_label, sd in (('no outage', None), ('30m', 1800), ('never', None)):
        p = replace(pd_, standby_route_delay=sd)
        out = None if sd_label == 'no outage' else dict(start=6 * H, end=30 * H, mode='fail', tokens=('USDC',),
                                                        routes=('primary', 'alternate'))
        a = run_many(p, brief(p, 96), outage=out)
        dbt[sd_label] = a
        ds = a['debt_states']
        rows.append([sd_label] + std_row(a) + [f"{a['forced_healthy']:.1f}", f"{a['forced_healthy_loss']:,.0f}",
                                               f"{a['blocked_n']['debt_stale']:.1f}",
                                               f"{ds['Live']}/{ds['Drifting']}/{ds['Cached']}/{ds['Expired']}"])
    table(['standby switch'] + STD_HEAD + ['forced_healthy', 'forced_loss', 'debt_stale_accts', 'USDC debt L/D/C/E'],
          rows, '== USDC routes fail 6h-30h during the USDC depeg; USDC markets and USDC debt (DebtOracle), prf 0.40')

    worst_brief = max(a['bad_debt_max'] for k, a in res.items() if k[0] == 'brief')
    # SIM-02A verifies: Q-079, Q-128, Q-183, Q-247, SPEC-ORC-013, SPEC-ORC-017
    ck.check('SIM-02A', 'brief path (USDC 0.87) during a provider-wide fail-mode outage of up to 72h creates no '
             'bad debt (prf 0.20-0.40)', worst_brief == 0, detail=f'worst bad debt = {worst_brief:,.0f} GHO')
    ok = {prf: res[('tail', 48, prf)]['bad_debt_max'] <= tr[prf][0] for prf in PRFS}
    # SIM-02B verifies: Q-079, Q-101, Q-186, Q-192, Q-249, SPEC-CAP-007
    ck.check('SIM-02B', 'tail path (USDT -> 0.02) during a 48h outage keeps bad debt within a First-Loss Reserve '
             'sized by the tail term (largest token exposure x CF / 1.10) at every prf 0.20-0.40', all(ok.values()),
             detail='bad debt vs tail-term reserve by prf: ' + ', '.join(
                 f"{k}: {res[('tail', 48, k)]['bad_debt_max']:,.0f} <= {tr[k][0]:,.0f}" for k in PRFS))
    # SIM-02C verifies: Q-182, Q-274, REQ-ORACLE-090, SPEC-ORC-015, ATTACK-056
    lim = 4200 + base.step
    ck.check('SIM-02C', 'a silent stall of every feed stops seizure and borrowing of every market within '
             'borrowPriceMaxAge (4,200 s) of the stall', worst_close['silent'] <= lim and worst_close['fail'] <= lim,
             detail=f"latest stop after the stall: silent {worst_close['silent'] / 60:.0f} min, fail "
                    f"{worst_close['fail'] / 60:.0f} min (bound {lim / 60:.0f} min with 10-minute steps)")
    # SIM-02D verifies: Q-079, Q-183, Q-154, SPEC-ORC-013
    ck.check('SIM-02D', 'every failure spends the Cached window in Cached before Expired',
             skipped['fail'] + skipped['silent'] == 0 and min(min_spell.values()) >= base.cached_window - base.step,
             detail=f"failures straight to Expired: {skipped['fail'] + skipped['silent']}; shortest Cached spell "
                    f"{min(min_spell.values()) / 60:.0f} min over {sum(spells_n.values())} spells (window measured "
                    'from the first failed read)')
    gb = max(gr[('brief', g, h)]['bad_debt_max'] for g, h in ((0, .95), (1800, .95), (7200, .95), (1800, .9),
                                                               (7200, .9)))
    gs = min(gr[('brief', 1800, .95)]['grace_starts'], gr[('tail', 1800, .95)]['grace_starts'])
    # SIM-02E verifies: Q-088, Q-129, Q-154, Q-264, SPEC-ORC-014, REQ-ORACLE-034, LIQ-007
    ck.check('SIM-02E', 'grace windows of 0-2h at grace HF 0.90-0.95 add no bad debt on the brief path, and every '
             'outage that reached Expired starts one', gb == 0 and gs >= 5,
             detail=f'brief worst bad debt = {gb:,.0f}; grace windows started per run at 30 min = {gs:.0f} '
                    f"(4 markets + the DebtOracle); tail bad debt grace 0 / 30 min / 2h: "
                    f"{gr[('tail', 0, .95)]['bad_debt']:,.0f} / {gr[('tail', 1800, .95)]['bad_debt']:,.0f} / "
                    f"{gr[('tail', 7200, .95)]['bad_debt']:,.0f}")
    s0, f0 = ts['silent'], ts['fail']
    # SIM-02F verifies: Q-247, Q-274, REQ-ORACLE-090, SPEC-ORC-013, SPEC-ORC-017, INV-075
    ck.check('SIM-02F', 'a token-specific silent stall (primary and TOKEN/X leg frozen, X/USD live) adds no bad debt '
             'over a reverting outage of the same feeds', s0['bad_debt_max'] <= f0['bad_debt_max'] + 1,
             detail=f"USDT stall during USDT -> 0.02: bad debt silent {s0['bad_debt']:,.0f} vs fail {f0['bad_debt']:,.0f}; "
                    f"earliest liquidation in the fresh USDC/GHO market {s0['first_liq_mkt_h']['USDC/GHO']:.1f}h (silent) vs "
                    f"{f0['first_liq_mkt_h']['USDC/GHO']:.1f}h (fail); USDT/GHO Expired steps (seed 11) "
                    f"{s0['state_steps']['USDT/GHO']['Expired']} vs {f0['state_steps']['USDT/GHO']['Expired']}: while the "
                    'serving alternate is past its borrow age the market is Drifting, not failed, and counts at no more '
                    'than its accepted price until the frozen leg passes feedMaxAge')
    w1, wn = wr['1h'], wr['never']
    # SIM-02G verifies: Q-208, Q-248, REQ-ORACLE-094, REQ-ORACLE-095, SPEC-ORC-016
    ck.check('SIM-02G', 'with a guardian standby switch within 1h, a fresh-but-wrong USDC primary during the USDC '
             'depeg creates no bad debt and blocks seizure for less than the switch delay plus one hour per account',
             w1['bad_debt_max'] == 0 and w1['blocked_h']['disagree'] <= 2.0 * max(1.0, w1['blocked_n']['disagree']),
             detail=f"1h switch: blocked {w1['blocked_n']['disagree']:.1f} accounts for {w1['blocked_h']['disagree']:.1f} "
                    f"account-hours; never: {wn['blocked_n']['disagree']:.1f} accounts, "
                    f"{wn['blocked_h']['disagree']:.1f} account-hours, bad debt {wn['bad_debt']:,.0f}")
    dn, d30, d0 = dbt['never'], dbt['30m'], dbt['no outage']
    # SIM-02H verifies: Q-247, Q-248, SPEC-ORC-017, SPEC-ORC-018, LIQ-006, LIQ-073
    ck.check('SIM-02H', 'stress valuation during a 24h outage of both USDC routes (USDC markets at 1, USDC debt at '
             'accepted x 1.05) liquidates no account that is healthy at market prices beyond the no-outage run',
             dn['forced_healthy'] <= d0['forced_healthy'],
             expect='Counterexample',
             detail=f"no standby: {dn['forced_healthy']:.1f} liquidations of accounts healthy at market prices "
                    f"(no outage: {d0['forced_healthy']:.1f}), "
                    f"borrower loss {dn['forced_healthy_loss']:,.0f} USD (bonus on what is seized), bad debt "
                    f"{dn['bad_debt']:,.0f}; USDC repayments blocked for {dn['blocked_n']['debt_stale']:.1f} accounts")
    # SIM-02I verifies: Q-248, Q-130, REQ-ORACLE-092, REQ-ORACLE-094
    ck.check('SIM-02I', 'a guardian standby switch within 30 minutes ends the USDC outage before any '
             'stress-valuation liquidation and adds no bad debt',
             d30['forced_healthy'] <= d0['forced_healthy'] and d30['bad_debt_max'] == 0,
             detail=f"30-minute switch: {d30['forced_healthy']:.1f} liquidations of accounts healthy at market prices "
                    f"(no outage: {d0['forced_healthy']:.1f}), bad debt {d30['bad_debt']:,.0f}, "
                    f"switches {d30['standby_switches']:.0f}")
    ck.finish()


if __name__ == '__main__':
    main()
