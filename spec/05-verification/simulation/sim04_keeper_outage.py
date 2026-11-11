# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SIM-04 Keeper outage, the standby keeper, the permissionless fallback, and the pause during an incident.

Both primary keepers stall at t = 2h for 48h; the independent standby keeper acts after
`standby_keeper_delay` (an operating agreement plus monitoring, Q-147), or never. The
permissionless fallback (Q-213) is either present (rational searchers who liquidate whenever the
routed call pays them, with no SettlementBudget, no in-kind and no reimbursement) or absent.
Feeds work. Paths start at t = 2h:
  brief - USDC March-2023 path (to 0.87), DAI follows;
  tail  - USDT -> 0.02 over 48h (issuer failure).
Part B: during the tail incident the Emergency Guardian pauses the application (reason General
or MintPathSuspect, Q-252) and trips every market breaker (Q-241) from 2h to 50h; keepers work.
Horizon 98h, 10-minute steps, seeds 11/22/33, 2M drawn; 30% active borrowers (60% reacting within
0.5-4h in Part B), of whom half add collateral instead of repaying.
"""
from dataclasses import replace

from _simcore import H, Checks, Params, run_many, std_row, STD_HEAD, table
from sim02_oracle_outage import brief, tail

DELAYS = ((0, '0'), (15 * 60, '15m'), (H, '1h'), (4 * H, '4h'), (12 * H, '12h'), (24 * H, '24h'), (None, 'none'))
HZ = 98


def main():
    base = Params(step=600, primary_down=(2 * H, 50 * H))
    ck = Checks('sim04_keeper_outage')
    res = {}
    for pname, pfn in (('brief', brief), ('tail', tail)):
        rows = []
        for prf in (0.20, 0.40):
            for perm in ((False, True) if prf == 0.40 else (False,)):
                for d, label in DELAYS:
                    if perm and label not in ('1h', '24h', 'none'):
                        continue
                    p = replace(base, prf=prf, standby_keeper_delay=d, permissionless=perm)
                    a = run_many(p, pfn(p, HZ))
                    res[(pname, prf, perm, label)] = a
                    rows.append([f'{prf:.2f}', 'yes' if perm else 'no', label] + std_row(a)
                                + [f"{a['blocked_h']['keeper_down']:.0f}", f"{a['max_true_underwater_h']:.1f}"])
        table(['prf', 'permissionless', 'standby'] + STD_HEAD + ['kd_acct_h', 'max_uw_h'], rows,
              f'== primaries down 48h, {pname} path')

    rows, pz = [], {}
    for label, kw in (('none', {}),
                      ('Paused(General) + breakers', dict(pause=(2 * H, 50 * H, 'General'), breaker_trip=(2 * H, 50 * H))),
                      ('Paused(MintPathSuspect)', dict(pause=(2 * H, 50 * H, 'MintPathSuspect')))):
        p = replace(base, prf=0.40, primary_down=None, active_share=0.6, react_delay=(0.5 * H, 4 * H), **kw)
        a = run_many(p, tail(p, HZ))
        pz[label] = a
        rows.append([label] + std_row(a) + [f"{a['topups']:.1f}", f"{a['topups_refused']:.1f}"])
    table(['incident controls'] + STD_HEAD + ['topups', 'topups_refused'], rows,
          '== B. pause reasons and breakers during the tail incident (keepers working, prf 0.40)')

    wb = max(a['bad_debt_max'] for k, a in res.items() if k[0] == 'brief')
    # SIM-04A verifies: Q-082, Q-147, ATTACK-083
    ck.check('SIM-04A', 'brief path: no bad debt with the primaries down for 48h, with or without a standby keeper or '
             'a permissionless liquidator (prf 0.20-0.40)', wb == 0, detail=f'worst = {wb:,.0f} GHO')
    ok = {}
    for prf in (0.20, 0.40):
        ok[prf] = [label for d, label in DELAYS if res[('tail', prf, False, label)]['bad_debt_max'] == 0]
    # SIM-04B verifies: Q-082, Q-147, Q-098, ATTACK-083, EMG-059
    ck.check('SIM-04B', 'tail path: a standby keeper that acts within 24h keeps bad debt at 0 (prf 0.20-0.40)',
             all(l in ok[prf] for prf in ok for l in ('0', '15m', '1h', '4h', '12h', '24h')),
             detail='delays with zero bad debt by prf (no permissionless): '
                    + '; '.join(f'{k}: {v}' for k, v in ok.items())
                    + f"; no standby, no permissionless at prf 0.40: {res[('tail', 0.40, False, 'none')]['bad_debt']:,.0f} GHO mean")
    pn = res[('tail', 0.40, True, 'none')]
    nn = res[('tail', 0.40, False, 'none')]
    # SIM-04C verifies: Q-213, Q-082, LIQ-061, LIQ-062, ATTACK-083
    ck.check('SIM-04C', 'tail path with no approved keeper for 48h: the permissionless fallback alone keeps bad debt '
             'no higher than with a standby keeper acting at once', pn['bad_debt_max'] <= res[('tail', 0.40, False, '0')]['bad_debt_max'] + 1,
             expect='Counterexample',
             detail=f"prf 0.40: permissionless only {pn['bad_debt']:,.0f} GHO mean (worst {pn['bad_debt_max']:,.0f}), "
                    f"{pn['perm_liq']:.0f} permissionless calls, {pn['blocked_n']['keeper_down']:.0f} accounts left "
                    f"because no call paid; nobody {nn['bad_debt']:,.0f}; standby at once "
                    f"{res[('tail', 0.40, False, '0')]['bad_debt']:,.0f}")
    n0, g0, m0 = pz['none'], pz['Paused(General) + breakers'], pz['Paused(MintPathSuspect)']
    same_liq = abs(g0['bad_debt'] - n0['bad_debt']) <= 1 and g0['topups_refused'] == 0 and \
        set(k for k, v in g0['blocked_n'].items() if v) <= set(k for k, v in n0['blocked_n'].items() if v)
    # SIM-04D verifies: Q-241, Q-252, Q-227, LIQ-002, EMG-077
    ck.check('SIM-04D', 'Paused(General) with every market breaker tripped blocks no liquidation, refuses no rescue '
             'top-up and adds no bad debt during the tail incident', same_liq,
             detail=f"bad debt {g0['bad_debt']:,.0f} vs {n0['bad_debt']:,.0f} without controls; liquidations "
                    f"{g0['liq']:.0f} vs {n0['liq']:.0f}; top-ups {g0['topups']:.1f} (refused {g0['topups_refused']:.0f}); "
                    f"under MintPathSuspect {m0['topups_refused']:.0f} top-up attempts were refused and borrower loss was "
                    f"{m0['borrower_loss']:,.0f} vs {n0['borrower_loss']:,.0f} USD")
    ck.finish()


if __name__ == '__main__':
    main()
