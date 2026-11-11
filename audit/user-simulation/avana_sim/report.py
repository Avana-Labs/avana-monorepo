"""Aggregate a finished run into plain numbers and markdown tables."""
import statistics
from collections import Counter, defaultdict

from . import params as P
from .metrics import FRUSTRATIONS

D = P.DAY


def _med(xs):
    return statistics.median(xs) if xs else 0.0


class _Person:
    """One person over the per-market (or per-Spoke) parts the engine split it into."""

    def __init__(self, parts):
        u0 = parts[0]
        self.uid, self.persona = u0.uid, u0.persona
        self.wallets = [w for u in parts for w in u.wallets]
        self.nfts = [n for u in parts for n in u.nfts]
        self.ledger = Counter()
        for u in parts:
            self.ledger.update(u.ledger)
        self.size = sum(u.size for u in parts)
        self.gave_up = all(u.gave_up for u in parts)
        wanted = [u for u in parts if u.exit_t is not None]
        self.exit_t = min(u.exit_t for u in wanted) if wanted else None
        self.exited = bool(wanted) and all(u.exited for u in wanted)
        self.stuck_exit = any(u.stuck_exit and not u.exited for u in parts)


def _persons(users):
    groups = defaultdict(list)
    for u in users:
        groups[u.uid].append(u)
    return [_Person(g) for g in groups.values()]


def summarise(sim):
    p, m = sim.p, sim.m
    end = sim.T
    people = [u for u in sim.users if not u.persona.startswith('attacker')]
    by_persona = defaultdict(list)
    for u in _persons(people):
        by_persona[u.persona].append(u)

    # final per-NFT liquidity conservation (user funds): live = initial + donated - seized
    for n in p.nfts.values():
        if n.alive:
            m.check('LP liquidity conservation per NFT', abs(n.liq - (n.liq_initial + n.donated - n.seized - n.removed)) < 1e-6 * max(1, n.liq_initial), str(n.id))

    liq_users = defaultdict(set)
    for L in m.liquidations:
        liq_users[L['persona']].add(L['wallet'])

    persona_rows = []
    for persona, us in by_persona.items():
        onboard = [u for u in us if any(p.acct(w) for w in u.wallets)]
        borrowers = [u for u in onboard if any(p.acct(w) and (sum(p.acct(w).borrowed.values()) > 0) for w in u.wallets)]
        nets, gas, bonus, interest, fees, foregone = [], [], [], [], [], []
        for u in onboard:
            itot = sum(sum(p.acct(w).interest.values()) for w in u.wallets if p.acct(w))
            ftot = sum(n.accrued for n in u.nfts if n.alive)
            g = u.ledger['gas']
            b = u.ledger['liq_bonus']
            cost = g + b + u.ledger['swap_cost']
            nets.append(cost / max(u.size, 1.0))
            gas.append(g)
            bonus.append(b)
            interest.append(itot)
            fees.append(ftot)
            foregone.append(u.ledger['fee_foregone'])
        sizes = [u.size for u in onboard]
        persona_rows.append(dict(
            persona=persona, users=len(us), onboarded=len(onboard), gave_up=sum(1 for u in us if u.gave_up),
            borrowers=len(borrowers), liquidated=len(liq_users[persona]),
            median_size=_med(sizes), median_fees=_med(fees), median_interest=_med(interest), median_gas=_med(gas),
            total_bonus=sum(bonus), median_cost_pct=_med(nets), share_cost_over_fees=(sum(1 for u, c in zip(onboard, nets) if c * max(u.size, 1.0) > sum(n.accrued for n in u.nfts if n.alive)) / len(nets)) if nets else 0.0,
            fee_foregone=sum(foregone),
            exits_wanted=sum(1 for u in us if u.exit_t is not None and u.exit_t < end and any(p.acct(w) for w in u.wallets)),
            exits_done=sum(1 for u in us if u.exited),
            stuck_exit=sum(1 for u in us if u.stuck_exit and not u.exited),
        ))

    # liquidations
    liq = m.liquidations
    by_ep = Counter(L['episode'] for L in liq)
    by_mode = Counter('%s/%s' % (L['caller'], L['mode']) for L in liq)
    by_asset = Counter(L['asset'] for L in liq)
    by_market = Counter(L['market'] for L in liq)
    accounts_liq = len({L['wallet'] for L in liq})
    dust_liq = [L for L in liq if L['repay'] < 100]
    reg_liq = [L for L in liq if not L['wallet'].startswith('dust')]

    # stuck funds at end
    stuck = Counter()
    stuck_users = defaultdict(set)
    for u in people:
        for w in u.wallets:
            a = p.acct(w)
            if not a:
                continue
            for mk in P.MARKET_IDS:
                for r in a.records[mk]:
                    if r.credited <= 1e-12:
                        stuck['zero-credit NFT never released (USD of fees + donations)'] += r.nft.owed + r.nft.donated * p.price(mk, end)
                        stuck_users['zero-credit NFT never released (USD of fees + donations)'].add(u.uid)
                    elif u.stuck_exit and not u.exited:
                        stuck['collateral of users who wanted to exit but lacked funds to repay'] += r.credited * p.price(mk, end)
                        stuck_users['collateral of users who wanted to exit but lacked funds to repay'].add(u.uid)
            if u.persona == 'forgetful' and a.has_debt():
                stuck_users['forgetful accounts still open with debt (not stuck, idle)'].add(u.uid)
        for w in u.wallets:
            a = p.acct(w)
            if not a:
                continue
            for mk in P.MARKET_IDS:
                for r in a.records[mk]:
                    unc = r.nft.liq - r.credited
                    if r.nft.alive and unc > 1e-9:
                        stuck['added liquidity sitting uncredited in pledged NFTs (USD)'] += unc * p.served(mk, end)
                        stuck_users['added liquidity sitting uncredited in pledged NFTs (USD)'].add(u.uid)
        unc = sum(n.owed for n in u.nfts if n.alive and n.in_vault)
        if unc > 0:
            stuck['uncollected fees in the vault (claimable at any time)'] += unc
            stuck_users['uncollected fees in the vault (claimable at any time)'].add(u.uid)

    # frustrations
    frs = []
    for code, us in m.frust.items():
        say, cause, fix, where = FRUSTRATIONS[code]
        frs.append(dict(code=code, users=len(us), events=m.frust_events[code], say=say, cause=cause, fix=fix, where=where))
    frs.sort(key=lambda x: (-x['users'], -x['events']))

    reverts = sorted(([a, e, n, len(m.revert_users[(a, e)]), m.revert_gas[(a, e)]] for (a, e), n in m.reverts.items()), key=lambda r: -r[2])
    refusals = sorted(([a, e, n, len(m.app_refusal_users[(a, e)])] for (a, e), n in m.app_refusals.items()), key=lambda r: -r[2])

    avail = {}
    for k, c in sim.borrow_avail.items():
        tot = sum(c.values())
        avail[k] = dict(ok=c['ok'] / tot, state=c['state'] / tot, age=c['age'] / tot, breaker=c['breaker'] / tot)

    slice_atk = p.slice_by_wallet.get('w%d' % next(u.uid for u in sim.users if u.persona == 'attacker_slice'), 0.0)
    total_slice = {mk: p.mk[mk]['slice'] for mk in P.MARKET_IDS}
    slice_users = {w: v for w, v in p.slice_by_wallet.items()}

    blocked_hours = {k: v * 600 / 3600 for k, v in m.liq_blocked.items()}
    atk = next(u for u in sim.users if u.persona == 'attacker_slice')
    atk_w = atk.wallet

    inv_viol = Counter(n for n, _ in m.invariant_violations)
    res = dict(
        seed=sim.seed, profile=sim.profile, repay_quote=sim.repay_quote, days=sim.days,
        people=sim.n_people, regular_users=len(people),
        personas=persona_rows,
        liquidations=dict(calls=len(liq), accounts=accounts_liq, by_episode=dict(by_ep), by_mode=dict(by_mode),
                          by_asset=dict(by_asset), by_market=dict(by_market),
                          bonus_paid=sum(L['bonus'] for L in liq), debt_repaid=sum(L['repay'] for L in liq),
                          deficit=sum(L['deficit'] for L in liq),
                          keeper_reimbursement=sim.reimbursement, keeper_pnl=sim.keeper_pnl,
                          searcher_profit=sum(sim.searcher_profit.values()), sandwich_extracted=sim.sandwich_extracted,
                          dust_calls=len(dust_liq), dust_keeper_loss=sum(-L['keeper_pnl'] for L in dust_liq if L['keeper_pnl'] < 0),
                          dust_attack_calls=len(liq) - len(reg_liq), regular_calls=len(reg_liq),
                          regular_calls_under_100=sum(1 for L in reg_liq if L['repay'] < 100),
                          regular_gas=sum(L['gas'] for L in reg_liq), regular_debt_repaid=sum(L['repay'] for L in reg_liq),
                          regular_reimbursement=sum(L['reimb'] for L in reg_liq),
                          max_calls_one_account=max([sum(1 for y in reg_liq if y['wallet'] == w) for w in {x['wallet'] for x in reg_liq}] or [0]),
                          cross_market_on_failed_market=sum(1 for L in liq if L.get('other_market_failed')),
                          blocked_account_hours=blocked_hours,
                          blocked_accounts={k: len(v) for k, v in m.liq_blocked_accounts.items()},
                          max_gas_usd=max([L['gas'] for L in liq] or [0]),
                          total_gas=sum(L['gas'] for L in liq), dust_attack_gas=sum(L['gas'] for L in liq) - sum(L['gas'] for L in reg_liq),
                          shortfall_calls=sim.liq_stats['shortfall_calls'], shortfall_gho=sim.liq_stats['shortfall_gho'],
                          shortfall_reports=sim.liq_stats['shortfall_reports'], avana_fee=sum(L.get('avana_fee', 0.0) for L in liq),
                          keeper_reward=sum(L.get('keeper_reward', 0.0) for L in liq),
                          borrower_surplus=sum(L.get('borrower_surplus', 0.0) for L in liq),
                          flash_calls=sim.liq_stats['flash_calls'], caller_funded_calls=sim.liq_stats['caller_funded_calls'],
                          flash_premium=sim.liq_stats['flash_premium'],
                          ),
        protocol=dict(deficit=dict(p.deficit), drawn=dict(p.drawn), slice_used=total_slice, slice_by_wallet=slice_users,
                      slice_used_by_attacker=slice_atk, market_regular=dict((mk, p.mk[mk]['regular']) for mk in P.MARKET_IDS),
                      supply=dict((mk, p.mk[mk]['supply']) for mk in P.MARKET_IDS)),
        stuck=dict((k, dict(usd=stuck[k], users=len(stuck_users[k]))) for k in set(stuck) | set(stuck_users)),
        frustrations=frs,
        reverts=reverts, refusals=refusals, successes=dict(m.successes),
        borrow_availability=avail,
        invariants=dict(checks=sum(m.invariant_checks.values()), kinds=dict(m.invariant_checks), violations=dict(inv_viol),
                        examples=m.invariant_violations[:10]),
        attacks=m.attacks, governance=m.governance, third_party=dict(sim.third_party),
        probes=getattr(m, 'probes', []),
        oracle=oracle_stats(sim),
        breakers=dict(alerts=p.latch_log, borrow_blocked_hours=dict(sim.breaker_time)),
        rescue=dict(stats=dict(sim.rescue_stats), rescue_units_booked=sum(p.rescue_by_wallet.values()),
                    rescue_excluded_borrow_refusals=len(p.rescue_excluded_refusals),
                    rescue_excluded_refusals_attacker=sum(1 for _, w in p.rescue_excluded_refusals if w == atk_w),
                    attacker_slice_used=p.slice_by_wallet.get(atk_w, 0.0),
                    attacker_borrowed_after_first_slice=p.borrowed_after_slice.get(atk_w, 0.0),
                    borrowed_after_slice_all=sum(p.borrowed_after_slice.values())),
        deleverage=dict(sim.deleverage_stats), recredit=dict(sim.recredit_stats), removal=dict(sim.removal_stats),
        exits=dict(sim.exit_stats), address_freeze=sim.freeze_results,
    )
    return res


def oracle_stats(sim):
    """Minutes of each oracle condition that the gaps of the report measure."""
    w = sim.w
    n = min(w.n_min, int(sim.T // 60))
    out = dict(standby_events=w.standby_events, listable=w.listable)
    for mk in P.MARKET_IDS:
        st, rs, lq = w.ostate[mk][:n], w.oreason[mk][:n], w.oliq[mk][:n]
        out[mk] = dict(drifting_band_min=sum(1 for x in rs if x & 2), drifting_twap_min=sum(1 for x in rs if x & 4),
                       disagree_min=sum(1 for x in rs if x & 1), cached_min=sum(1 for x in st if x == 2),
                       expired_min=sum(1 for x in st if x == 3),
                       alt_past_borrow_age_min=sum(1 for x in lq if x == 'alt_past_borrow_age'))
    a, b = (int(x * 1440) for x in EP_RANGE('gho_premium'))
    out['gho_premium_band_hours'] = sum(1 for x in w.oreason['GHO/USDC'][a:b] if x & 2) / 60.0
    # USDT joint stall: minutes in which a USDT market could be seized while USDT's leg in use was
    # older than its borrowPriceMaxAge (the frozen-price window of gap 5)
    a, b = (int(x * 1440) for x in EP_RANGE('usdt_feed_outage'))
    frozen = 0
    for m_ in range(a, b + 720):
        leg = w.leg['USDT'][m_]
        if leg is None or m_ * 60.0 - leg[1] <= P.borrow_max_age(leg[3]):
            continue
        if any(w.ostate[mk][m_] < 2 and w.oliq[mk][m_] == 'ok' for mk in ('USDC/USDT', 'USDe/USDT')):
            frozen += 1
    out['usdt_stall_seizable_on_stale_leg_min'] = frozen
    a, b = (int(x * 1440) for x in EP_RANGE('usdc_primary_stall'))
    rows = w.debt_rows[a:b + 120]
    out['usdc_stall_debt_borrow_blocked_min'] = sum(1 for r in rows if not r[2])
    out['usdc_stall_debt_liquidation_blocked_min'] = sum(1 for r in rows if not r[3])
    return out


def EP_RANGE(name):
    from .world import EP
    return EP[name]


def fmt_usd(x):
    return '${:,.0f}'.format(x)


def tables(res):
    out = []
    out.append('### Personas (seed %s, feed profile `%s`, repay quote `%s`)\n' % (res['seed'], res['profile'], res['repay_quote']))
    out.append('| Persona | Users | Onboarded | Gave up | Borrowed | Liquidated | Median size | Median LP fees earned | Median interest | Median gas | Liquidation bonus paid (total) | Median Avana cost (gas + bonus + swaps) as % of size | Avana cost > LP fees | Exits wanted / done / stuck |')
    out.append('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
    for r in res['personas']:
        out.append('| %s | %d | %d | %d | %d | %d | %s | %s | %s | %s | %s | %s | %s | %d / %d / %d |' % (
            r['persona'], r['users'], r['onboarded'], r['gave_up'], r['borrowers'], r['liquidated'], fmt_usd(r['median_size']),
            fmt_usd(r['median_fees']), fmt_usd(r['median_interest']), fmt_usd(r['median_gas']), fmt_usd(r['total_bonus']),
            '%.2f%%' % (100 * r['median_cost_pct']), '%.0f%%' % (100 * r['share_cost_over_fees']), r['exits_wanted'], r['exits_done'], r['stuck_exit']))
    L = res['liquidations']
    out.append('\n### Liquidations\n')
    out.append('| Measure | Value |\n|---|---|')
    for k in ('calls', 'accounts'):
        out.append('| %s | %d |' % (k, L[k]))
    for k in ('bonus_paid', 'debt_repaid', 'deficit', 'keeper_reimbursement', 'keeper_pnl', 'searcher_profit', 'sandwich_extracted', 'dust_keeper_loss', 'max_gas_usd'):
        out.append('| %s | %s |' % (k, fmt_usd(L[k])))
    out.append('| dust calls (repay < $100) | %d |' % L['dust_calls'])
    out.append('| calls on the dust attacker\'s accounts / on other accounts | %d / %d |' % (L['dust_attack_calls'], L['regular_calls']))
    out.append('| other accounts: calls repaying under $100 / gas / debt repaid / reimbursed / most calls on one account | %d / %s / %s / %s / %d |' % (
        L['regular_calls_under_100'], fmt_usd(L['regular_gas']), fmt_usd(L['regular_debt_repaid']), fmt_usd(L['regular_reimbursement']), L['max_calls_one_account']))
    out.append('| liquidations seizing a fresh market while another market of the account was Cached, Expired or disagreeing (Q-247) | %d |' % L['cross_market_on_failed_market'])
    out.append('| by episode | %s |' % ', '.join('%s %d' % kv for kv in sorted(L['by_episode'].items(), key=lambda x: -x[1])))
    out.append('| by caller/mode | %s |' % ', '.join('%s %d' % kv for kv in L['by_mode'].items()))
    out.append('| by debt asset | %s |' % ', '.join('%s %d' % kv for kv in L['by_asset'].items()))
    out.append('| by market | %s |' % ', '.join('%s %d' % kv for kv in L['by_market'].items()))
    out.append('| liquidation blocked (account-hours by reason) | %s |' % ', '.join('%s %.1f h (%d accounts)' % (k, v, L['blocked_accounts'].get(k, 0)) for k, v in L['blocked_account_hours'].items()))
    out.append('\n### Failed transactions on-chain (reverted, gas paid)\n')
    out.append('| Action | Error | Count | Users | Gas lost |\n|---|---|---|---|---|')
    for a, e, n, nu, g in res['reverts'][:30]:
        out.append('| %s | `%s` | %d | %d | %s |' % (a, e, n, nu, fmt_usd(g)))
    out.append('\n### Refused by the app pre-check (no gas)\n')
    out.append('| Action | Reason | Count | Users |\n|---|---|---|---|')
    for a, e, n, nu in res['refusals'][:30]:
        out.append('| %s | `%s` | %d | %d |' % (a, e, n, nu))
    out.append('\n### Frustrations (unique users)\n')
    out.append('| # | Code | Users | Events | Where the fix belongs |\n|---|---|---|---|---|')
    for i, f in enumerate(res['frustrations'], 1):
        out.append('| %d | %s | %d | %d | %s |' % (i, f['code'], f['users'], f['events'], f['where']))
    out.append('\n### Stuck or idle funds at day %d\n' % res['days'])
    out.append('| Kind | USD | Users |\n|---|---|---|')
    for k, v in sorted(res['stuck'].items()):
        out.append('| %s | %s | %d |' % (k, fmt_usd(v['usd']), v['users']))
    out.append('\n### Borrow availability (share of 10-minute samples where the price gates of BOR-006 pass)\n')
    out.append('| Market / feed | Allowed | Blocked by state | Blocked by price age | Blocked by a market breaker |\n|---|---|---|---|---|')
    for k, v in res['borrow_availability'].items():
        out.append('| %s | %.1f%% | %.1f%% | %.1f%% | %.1f%% |' % (k, 100 * v['ok'], 100 * v['state'], 100 * v['age'], 100 * v['breaker']))
    inv = res['invariants']
    out.append('\n### Invariants\n')
    out.append('%d checks over %d kinds; violations: %s\n' % (inv['checks'], len(inv['kinds']), inv['violations'] or 'none'))
    out.append('| Invariant | Checks |\n|---|---|')
    for k, v in sorted(inv['kinds'].items()):
        out.append('| %s | %d |' % (k, v))
    out.append('\n### Protocol state at the end\n')
    pr = res['protocol']
    out.append('| Measure | Value |\n|---|---|')
    out.append('| deficit (bad debt) | %s |' % pr['deficit'])
    out.append('| slice used per market (USD) | %s |' % ', '.join('%s %s' % (k, fmt_usd(v)) for k, v in pr['slice_used'].items()))
    out.append('| slice used by the re-leverage attacker | %s |' % fmt_usd(pr['slice_used_by_attacker']))
    out.append('| regular cap used | %s |' % ', '.join('%s %s' % (k, fmt_usd(v)) for k, v in pr['market_regular'].items()))
    out.append('| third-party repay service | %s |' % res['third_party'])
    out.append('\n### Rule probes vs the 3.6 emergency matrix (observed / expected)\n')
    cols = ['new', 'topup', 'rescue', 'borrow', 'repay', 'collect', 'wd_free', 'wd_debt', 'remove_debt', 'rwc', 'repay_all_wd', 'liq']
    out.append('| State (market, day) | ' + ' | '.join(cols) + ' |')
    out.append('|---|' + '---|' * len(cols))
    for pr in res.get('probes', []):
        if not pr['observed']:
            out.append('| %s (%s, %.2f) | %s |' % (pr['label'], pr['market'], pr['day'], ' | '.join('-' for _ in cols)))
            continue
        cells = []
        for c in cols:
            o, e = pr['observed'][c], pr['expected'][c]
            if o[0] == e[0]:
                cells.append(o)
            elif any(x in o for x in ('CapExceeded', 'SliceNotAvailable', 'PoolShareExceeded')):
                cells.append('*%s* (state allows; refused by a cap)' % o)
            else:
                cells.append('**%s** (expected %s)' % (o, e))
        out.append('| %s (%s, %.2f) | %s |' % (pr['label'], pr['market'], pr['day'], ' | '.join(cells)))
    out.append('\n### Final-spec features\n')
    out.append('| Measure | Value |\n|---|---|')
    o = res['oracle']
    out.append('| standby switches (day, token, slot, call) | %s |' % '; '.join('%.2f %s %s %s' % e for e in o['standby_events']))
    out.append('| tokens listable (every primary leg heartbeat <= 3,600 s) | %s |' % ', '.join('%s %s' % kv for kv in o['listable'].items()))
    out.append('| GHO/USDC Drifting(USD band) during the GHO premium | %.1f h |' % o['gho_premium_band_hours'])
    out.append('| USDT stall: minutes a USDT market was seizable on a leg older than borrowPriceMaxAge | %d |' % o['usdt_stall_seizable_on_stale_leg_min'])
    out.append('| USDC primary stall: USDC debt borrow gate / repayment gate closed | %d / %d min |' % (o['usdc_stall_debt_borrow_blocked_min'], o['usdc_stall_debt_liquidation_blocked_min']))
    for mk in P.MARKET_IDS:
        out.append('| %s oracle minutes | %s |' % (mk, ', '.join('%s %d' % kv for kv in o[mk].items())))
    out.append('| monitoring alerts, seizure and route failures (day, market, reason) | %s |' % ('; '.join('%.2f %s %s' % x for x in res['breakers']['alerts']) or 'none'))
    out.append('| borrowing blocked by a market breaker (hours, from 10-minute samples) | %s |' % ('; '.join('%s %.1f' % kv for kv in sorted(res['breakers']['borrow_blocked_hours'].items())) or 'none'))
    L = res['liquidations']
    out.append('| caller shortfall top-ups: calls / USD in the debt asset | %d / %s |' % (L['shortfall_calls'], fmt_usd(L['shortfall_gho'])))
    out.append('| flash-funded / caller-funded liquidations; flash premium paid | %d / %d; %s |' % (
        L['flash_calls'], L['caller_funded_calls'], fmt_usd(L['flash_premium'])))
    out.append('| keeper reward / borrower surplus (debt asset) | %s / %s |' % (fmt_usd(L['keeper_reward']), fmt_usd(L['borrower_surplus'])))
    out.append('| failed keeper attempts (RecoveryBelowFloor or MinOutNotMet) | %d |' % L['shortfall_reports'])
    out.append('| Avana fee (oracle value) | %s |' % fmt_usd(L['avana_fee']))
    rz = res['rescue']
    for k, v in sorted(rz.items()):
        out.append('| rescue: %s | %s |' % (k, v))
    for name in ('deleverage', 'recredit', 'removal', 'exits'):
        out.append('| %s | %s |' % (name, ', '.join('%s %s' % (k, round(v, 2) if isinstance(v, float) else v) for k, v in sorted(res[name].items())) or 'none'))
    for fr in res['address_freeze']:
        out.append('| address freeze gates (EMG-070) | %s |' % '; '.join('%s: %s' % kv for kv in fr.items()))
    out.append('\n### Governance and attacks\n')
    for d, g in res['governance']:
        out.append('- day %.2f: %s' % (d, g))
    for a in res['attacks']:
        out.append('- day %.2f: **%s** (%s): %s' % (a['t'], a['attack'], a['step'], a['result']))
    return '\n'.join(out) + '\n'


def topology_summary(sim):
    """Numbers of one topology run (design review): bad debt, liquidations, contagion, keeper
    load per block, Hub supplier loss, capital efficiency and blocked collateral."""
    p, m = sim.p, sim.m
    hub_reserve = sum(P.CREDIT_LINE.values())
    liqs = m.liquidations
    stable = [L for L in liqs if not L['spoke'].startswith('V:')]
    by_block = defaultdict(lambda: [0, 0.0])
    for L in liqs:
        b = by_block[L['t_sec']]
        b[0] += 1
        b[1] += L['seize']
    peak = max(by_block.values(), key=lambda x: x[1]) if by_block else [0, 0.0]
    by_spoke = defaultdict(lambda: dict(calls=0, accounts=set(), seized=0.0, contagion=0))
    for L in liqs:
        s = by_spoke[L['spoke']]
        s['calls'] += 1
        s['accounts'].add(L['wallet'])
        s['seized'] += L['seize']
        s['contagion'] += 1 if L['contagion'] else 0
    deficit = {k: p.deficit[k] for k in P.DEBT_ASSETS}
    # debt not yet written off whose account is underwater at the end (dust collateral left on a market)
    underwater = 0.0
    for a in p.accounts.values():
        if a.has_debt():
            underwater += max(0.0, p.debt_value(a, sim.T) - p.coll_usd(a, sim.T))
    bad_usd = sum(deficit.values()) + underwater
    loss = {k: max(0.0, deficit[k] - P.FIRST_LOSS_RESERVE[k]) for k in P.DEBT_ASSETS}
    loss['underwater'] = max(0.0, underwater - sum(max(0.0, P.FIRST_LOSS_RESERVE[k] - deficit[k]) for k in P.DEBT_ASSETS))
    people = [u for u in sim.users]
    return dict(
        topology=sim.topology, scenario=sim.scenario, seed=sim.seed, days=sim.days,
        spokes=sorted(set(p.spokes.values())), accounts=len([a for a in p.accounts.values()]),
        persons=len({u.pid for u in people if any(p.acct(w) for w in u.wallets)}),
        liquidations=dict(
            calls=len(liqs), accounts=len({L['wallet'] for L in liqs}), persons=len({L['pid'] for L in liqs}),
            stable_calls=len(stable), stable_accounts=len({L['wallet'] for L in stable}),
            contagion_calls=sum(1 for L in liqs if L['contagion']),
            contagion_accounts=len({L['wallet'] for L in liqs if L['contagion']}),
            seized_usd=sum(L['seize'] for L in liqs), bonus_usd=sum(L['bonus'] for L in liqs),
            blocked=dict(m.liq_blocked), blocked_accounts={k: len(v) for k, v in m.liq_blocked_accounts.items()},
            by_spoke={k: dict(calls=v['calls'], accounts=len(v['accounts']), seized=v['seized'], contagion=v['contagion'])
                      for k, v in by_spoke.items()},
        ),
        keeper=dict(peak_block_calls=peak[0], peak_block_usd=peak[1], blocks_with_liquidations=len(by_block),
                    reimbursement=sim.reimbursement, keeper_pnl=sim.keeper_pnl),
        bad_debt=dict(by_asset=deficit, underwater_usd=underwater, usd=bad_usd, pct_hub_reserve=bad_usd / hub_reserve,
                      by_spoke={k: dict(v) for k, v in p.spoke_deficit.items()}),
        supplier_loss=dict(by_asset=loss, usd=sum(loss.values()), first_loss_used=sum(min(deficit[k], P.FIRST_LOSS_RESERVE[k]) for k in P.DEBT_ASSETS)),
        capital=sim.topo_snap,
        blocked=dict(own_usd_h=sim.topo['blocked_own_usd_h'], other_usd_h=sim.topo['blocked_other_usd_h'],
                     deficit_breaker_usd_h=sim.topo['deficit_blocked_usd_h']),
        drawcap_refusals=dict(pre_shock=sim.topo['drawcap_refusals_pre_shock'], after=sim.topo['drawcap_refusals_after']),
        user_gas_usd=sum(u.ledger['gas'] for u in people),
        rescues=dict(sim.rescue_stats), deleverage=dict(sim.deleverage_stats),
        invariants=dict(checks=sum(m.invariant_checks.values()),
                        violations=dict(Counter(n for n, _ in m.invariant_violations))),
    )


TOPO_METRICS = [
    # (key, label, getter, format)
    ('accounts', 'Accounts (proxies)', lambda r: r['accounts'], '%.0f'),
    ('liq_accounts', 'Accounts liquidated', lambda r: r['liquidations']['accounts'], '%.1f'),
    ('liq_persons', 'People liquidated', lambda r: r['liquidations']['persons'], '%.1f'),
    ('contagion', 'Accounts liquidated through a market healthy on its own', lambda r: r['liquidations']['contagion_accounts'], '%.1f'),
    ('liq_calls', 'Liquidation calls', lambda r: r['liquidations']['calls'], '%.1f'),
    ('seized', 'Collateral seized (USD)', lambda r: r['liquidations']['seized_usd'], '%.0f'),
    ('bonus', 'Liquidation bonus paid by users (USD)', lambda r: r['liquidations']['bonus_usd'], '%.0f'),
    ('bad_debt', 'Bad debt (USD)', lambda r: r['bad_debt']['usd'], '%.0f'),
    ('bad_debt_pct', 'Bad debt (% of Hub reserve)', lambda r: 100 * r['bad_debt']['pct_hub_reserve'], '%.3f'),
    ('bad_debt_vol', 'Bad debt of the Volatile Spoke (USD)', lambda r: sum(r['bad_debt']['by_spoke'].get('V:Volatile', {}).values()), '%.0f'),
    ('supplier_loss', 'Hub supplier loss beyond the First-Loss Reserve (USD)', lambda r: r['supplier_loss']['usd'], '%.0f'),
    ('peak_block_usd', 'Peak keeper settlement in one block (USD)', lambda r: r['keeper']['peak_block_usd'], '%.0f'),
    ('peak_block_calls', 'Peak liquidation calls in one block', lambda r: r['keeper']['peak_block_calls'], '%.1f'),
    ('used', 'Borrow capacity used before the shock (%)', lambda r: 100 * r['capital']['used'], '%.1f'),
    ('safe', 'Shock-safe debt / capacity (%)', lambda r: 100 * r['capital']['shock_safe_over_capacity'], '%.1f'),
    ('cap_bound', 'Unused capacity beyond Spoke draw caps before the shock (USD)', lambda r: r['capital']['headroom_beyond_draw_caps_usd'], '%.0f'),
    ('drawcap_pre', 'DrawCapExceeded refusals before the shock', lambda r: r['drawcap_refusals']['pre_shock'], '%.0f'),
    ('blocked_other', 'Healthy collateral blocked by another market (USD-hours, millions)', lambda r: r['blocked']['other_usd_h'] / 1e6, '%.1f'),
    ('blocked_own', 'Collateral blocked by its own market (USD-hours, millions)', lambda r: r['blocked']['own_usd_h'] / 1e6, '%.1f'),
    ('blocked_deficit', 'Collateral of indebted accounts on a Spoke whose deficit breaker tripped (USD-hours, millions)', lambda r: r['blocked']['deficit_breaker_usd_h'] / 1e6, '%.1f'),
    ('gas', 'User gas (USD)', lambda r: r['user_gas_usd'], '%.0f'),
]


def topology_tables(results):
    """Mean and range over seeds per (scenario, topology)."""
    groups = defaultdict(list)
    for r in results:
        groups[(r['scenario'], r['topology'])].append(r)
    agg = {}
    for (sc, topo), rs in groups.items():
        row = dict(seeds=sorted(r['seed'] for r in rs))
        for key, _, get, _ in TOPO_METRICS:
            xs = [get(r) for r in rs]
            row[key] = dict(mean=sum(xs) / len(xs), min=min(xs), max=max(xs))
        row['violations'] = sum(sum(r['invariants']['violations'].values()) for r in rs)
        row['checks'] = sum(r['invariants']['checks'] for r in rs)
        agg['%s|%s' % (sc, topo)] = row
    scenarios = []
    for r in results:
        if r['scenario'] not in scenarios:
            scenarios.append(r['scenario'])
    order = [s for s in ('calm', 'dai-depeg', 'usdt-depeg', 'pool-crunch', 'two-pool', 'oracle-stale', 'dai-crash', 'dai-failure', 'eth-crash') if s in scenarios]
    out = ['# Topology comparison: mean over seeds (min-max)\n']
    for sc in order:
        topos = [t for t in ('T1', 'T2', 'T3') if '%s|%s' % (sc, t) in agg]
        out.append('\n## %s (%d seeds)\n' % (sc, len(agg['%s|%s' % (sc, topos[0])]['seeds'])))
        out.append('| Metric | ' + ' | '.join(topos) + ' |')
        out.append('|---|' + '---|' * len(topos))
        for key, label, _, fmt in TOPO_METRICS:
            cells = []
            for t in topos:
                v = agg['%s|%s' % (sc, t)][key]
                cells.append((fmt % v['mean']) + ((' (' + fmt % v['min'] + '-' + fmt % v['max'] + ')') if v['max'] != v['min'] else ''))
            out.append('| %s | %s |' % (label, ' | '.join(cells)))
        out.append('| Invariant violations | ' + ' | '.join(str(agg['%s|%s' % (sc, t)]['violations']) for t in topos) + ' |')
    return '\n'.join(out) + '\n', agg
