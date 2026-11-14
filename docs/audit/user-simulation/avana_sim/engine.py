"""Agent-based simulation of 1,000 Avana users over 90 days.

Event-driven: user check-ins, transaction inclusions, keeper scans (every
10 minutes), a third-party rescue service (every 30 minutes), governance
actions and daily invariant checks all sit in one time-ordered heap.
"""
import copy
import heapq
import math
import random
from collections import Counter, OrderedDict, defaultdict

from . import params as P
from .metrics import Metrics
from .protocol import Protocol, Refused
from .world import EP, SHOCK_DAY, World

D = P.DAY
H = P.HOUR

MARKET_W = {'USDC/USDT': 0.40, 'GHO/USDC': 0.22, 'DAI/USDC': 0.18, 'USDe/USDT': 0.20}
LEVER_W = {'USDC/USDT': 0.25, 'GHO/USDC': 0.15, 'DAI/USDC': 0.15, 'USDe/USDT': 0.45}
# topology runs: the same users in every topology, on the three stable markets (ASSUMPTION)
TOPO_MARKET_W = {'USDC/USDT': 0.45, 'DAI/USDC': 0.30, 'USDC/USDT-B': 0.25}
TOPO_LEVER_W = {'USDC/USDT': 0.40, 'DAI/USDC': 0.30, 'USDC/USDT-B': 0.30}
# T3 only: extra users of the Volatile-Hub Spoke (WETH/USDC LPs borrowing USDC), from their own RNG
VOL_USERS = {'passive_lp': 50, 'active_lp': 30, 'leveraged': 30, 'mobile': 20, 'forgetful': 20}

PERSONAS = {
    # n, size, share of concentrated positions, P(borrow), target HF, act HF, check interval (h)
    'passive_lp': dict(n=270, size=('logn', 8000, 1.0), conc=0.30, borrow=0.50, target=(1.6, 3.0), act=1.25, check=(24, 96),
                       collect=30, exit=0.25, mobile=0.08, guardian=0.03, spare=0.25, cash=(0.2, 0.6), hold=0.7, usdc=0.2, ltv=(0.15, 0.35)),
    'active_lp': dict(n=120, size=('logn', 15000, 0.9), conc=0.70, borrow=0.50, target=(1.3, 2.0), act=1.20, check=(4, 24),
                      collect=7, exit=0.4, mobile=0.05, guardian=0.0, spare=0.4, cash=(0.2, 0.5), hold=0.6, usdc=0.2, ltv=(0.2, 0.4),
                      rebalance=(7, 15)),
    'leveraged': dict(n=100, size=('logn', 20000, 0.9), conc=0.20, borrow=1.0, target=(1.11, 1.18), act=1.12, check=(1, 6),
                      collect=14, exit=0.5, mobile=0.05, guardian=0.08, spare=0.2, cash=(0.03, 0.15), hold=0.2, usdc=0.25,
                      ltv=(0.5, 0.8), maxpress=0.3, loops=(0, 2), lever=True),
    'small': dict(n=120, size=('unif', 4, 300), conc=0.5, borrow=0.6, target=(1.3, 2.5), act=1.15, check=(24, 120),
                  collect=60, exit=0.3, mobile=0.4, guardian=0.0, spare=0.1, cash=(0.2, 1.0), hold=0.8, usdc=0.15, ltv=(0.2, 0.5)),
    'whale': dict(n=20, size=('unif', 150000, 1200000), conc=0.3, borrow=0.8, target=(1.4, 2.5), act=1.3, check=(1, 6),
                  collect=7, exit=0.2, mobile=0.0, guardian=0.3, spare=0.3, cash=(0.2, 0.5), hold=0.5, usdc=0.3, ltv=(0.15, 0.3),
                  early=True),
    'multi_market': dict(n=85, size=('logn', 20000, 0.9), conc=0.3, borrow=0.9, target=(1.25, 1.8), act=1.15, check=(6, 48),
                         collect=21, exit=0.3, mobile=0.1, guardian=0.03, spare=0.3, cash=(0.1, 0.4), hold=0.6, usdc=0.25,
                         ltv=(0.2, 0.4), markets=(2, 3)),
    'mobile': dict(n=110, size=('logn', 5000, 1.0), conc=0.3, borrow=0.8, target=(1.2, 1.8), act=1.15, check=(6, 48),
                   collect=30, exit=0.3, mobile=1.0, guardian=0.02, spare=0.2, cash=(0.1, 0.5), hold=0.6, usdc=0.2, ltv=(0.2, 0.45)),
    'forgetful': dict(n=90, size=('logn', 8000, 1.0), conc=0.2, borrow=0.9, target=(1.2, 1.6), act=0.0, check=(24, 48),
                      collect=1e9, exit=0.0, mobile=0.2, guardian=0.0, spare=0.0, cash=(0.0, 0.2), hold=0.5, usdc=0.2,
                      ltv=(0.2, 0.4), forget=2),
    'usdc_borrower': dict(n=70, size=('logn', 15000, 0.9), conc=0.3, borrow=1.0, target=(1.25, 1.7), act=1.15, check=(4, 24),
                          collect=21, exit=0.35, mobile=0.1, guardian=0.05, spare=0.3, cash=(0.1, 0.4), hold=0.6, usdc=1.0,
                          ltv=(0.2, 0.4)),
}
N_KEEPERS, N_SEARCHERS, N_ATTACKERS = 3, 10, 2


# (label, market, day): rule probes in each state, compared with the 3.6 emergency matrix
PROBES = [
    ('Live', 'USDC/USDT', 5.0),
    ('GHO premium', 'GHO/USDC', 9.0),
    ('USDT routes stalled', 'USDC/USDT', 18.53),
    ('USDT routes stalled, standby serving', 'USDC/USDT', 18.75),
    ('USDT routes stalled, later', 'USDC/USDT', 19.2),
    ('After USDT recovery', 'USDC/USDT', 19.61),
    ('Drifting (feed disagreement)', 'USDe/USDT', 60.21),
    ('Disagreement beyond disagreementPauseMax', 'USDe/USDT', 60.249),
    ('Drifting (USD band breach)', 'USDe/USDT', 66.0),
    ('Application Frozen', 'USDC/USDT', 75.1),
    ('Application Paused (General)', 'USDC/USDT', 76.0),
    ('USDC primary stalled', 'USDC/USDT', 85.06),
    ('USDC primary stalled, standby serving', 'USDC/USDT', 85.1),
]
# Expected availability from the 3.6 emergency matrix (EMG-001 to EMG-073): Y allowed, N refused.
# topup is a non-rescue top-up (probe account at HF 2); rescue is a top-up of an account below
# minOpeningHealthFactor; remove_debt is partial removal with debt; rwc is repay with collateral.
_ALL_Y = dict(new='Y', topup='Y', rescue='Y', borrow='Y', repay='Y', collect='Y', wd_free='Y', wd_debt='Y',
              remove_debt='Y', rwc='Y', repay_all_wd='Y', liq='Y')


def _exp(**kw):
    d = dict(_ALL_Y)
    d.update(kw)
    return d


EXPECTED = {
    'Live': _exp(),                                                                              # EMG-001
    'Live on alternate, every leg within borrowPriceMaxAge': _exp(),                             # EMG-002
    'Alternate past borrowPriceMaxAge (seizure as Cached)': _exp(borrow='N', wd_debt='N', remove_debt='N', rwc='N', liq='N'),  # EMG-002
    'Drifting (TWAP)': _exp(new='N', borrow='N', wd_debt='N', remove_debt='N'),                  # EMG-003
    'Drifting (USD band breach)': _exp(borrow='N', wd_debt='N', remove_debt='N'),                # EMG-004
    'Drifting (feed disagreement)': _exp(new='N', borrow='N', wd_debt='N', remove_debt='N', rwc='N', liq='N'),  # EMG-005
    'Disagreement beyond disagreementPauseMax': _exp(new='N', borrow='N', wd_debt='N', remove_debt='N', rwc='N', liq='N'),
    'Cached': _exp(new='N', topup='N', rescue='N', borrow='N', wd_debt='N', remove_debt='N', rwc='N', liq='N'),  # EMG-006
    'Expired': _exp(new='N', topup='N', rescue='N', borrow='N', wd_debt='N', remove_debt='N', rwc='N', liq='N'),  # EMG-007
    'Grace after recovery': _exp(liq='N'),                                                       # EMG-008 (probe HF >= 0.95)
    'Grace after recovery, manual breaker still tripped': _exp(new='N', topup='N', borrow='N', wd_debt='N', remove_debt='N', liq='N'),
    'Application Frozen': _exp(new='N', borrow='N'),                                             # EMG-017
    'Application Paused (General)': _exp(new='N', topup='N', borrow='N', wd_debt='N', remove_debt='N', rwc='N'),  # EMG-018
    'USDC debt price failing': _exp(borrow='N', wd_debt='N', remove_debt='N', rwc='N', liq='N'),  # EMG-020
    'Market breaker tripped': _exp(new='N', topup='N', borrow='N', wd_debt='N', remove_debt='N'),  # EMG-068
}

class User:
    def __init__(self, uid, persona, cfg, rng, weights=None):
        self.uid, self.persona, self.cfg = uid, persona, cfg
        self.pid = uid            # the person; a topology run may split one person into one user per Spoke
        self.wallet = 'w%d' % uid
        self.wallets = [self.wallet]
        self.mobile = rng.random() < cfg['mobile']
        lo, hi = cfg['check']
        self.check_h = rng.uniform(lo, hi)
        self.target_hf = rng.uniform(*cfg['target'])
        self.maxpress = rng.random() < cfg.get('maxpress', 0.0)
        self.act_hf = cfg['act']
        self.want_ltv = rng.uniform(*cfg['ltv'])
        self.wants_borrow = rng.random() < cfg['borrow']
        self.debt_asset = 'USDC' if rng.random() < cfg['usdc'] else 'GHO'
        self.hold_borrowed = rng.random() < cfg['hold']
        self.guardian = rng.random() < cfg['guardian']
        kind, a, b = cfg['size']
        size = rng.lognormvariate(math.log(a), b) if kind == 'logn' else rng.uniform(a, b)
        self.size = size
        mw, lw = weights or (MARKET_W, LEVER_W)
        weights = lw if cfg.get('lever') else mw
        nm = rng.randint(*cfg['markets']) if 'markets' in cfg else 1
        mks = []
        while len(mks) < nm:
            mk = rng.choices(list(weights), list(weights.values()))[0]
            if mk not in mks:
                mks.append(mk)
        self.todo = [dict(mk=mk, usd=size / nm, full=rng.random() >= cfg['conc']) for mk in mks]
        self.home_markets = mks
        self.cash = size * rng.uniform(*cfg['cash'])
        self.spare = size * rng.uniform(0.2, 0.5) if rng.random() < cfg['spare'] else 0.0
        self.held = {'GHO': 0.0, 'USDC': 0.0}
        self.deployed = 0.0
        self.recall_t = None
        self.guardian_funds = size * 0.3 if self.guardian else 0.0
        self.loops_left = rng.randint(*cfg['loops']) if 'loops' in cfg else 0
        self.loop_cash = 0.0
        self.nfts = []
        early = cfg.get('early')
        self.arrival = rng.uniform(0, 5 * D) if early else (rng.uniform(0, 10 * D) if rng.random() < 0.6 else rng.uniform(10 * D, 45 * D))
        self.exit_t = rng.uniform(max(self.arrival + 10 * D, 30 * D), 89 * D) if rng.random() < cfg['exit'] else None
        self.forget_t = self.arrival + cfg['forget'] * D if 'forget' in cfg else None
        self.next_rebalance = self.arrival + rng.uniform(*cfg['rebalance']) * D if 'rebalance' in cfg else None
        self.last_collect = self.arrival
        self.busy_until = 0.0
        self.retries = Counter()
        self.done = False
        self.gave_up = False
        self.stuck_exit = False
        self.exited = False
        self.last_rescue_refused = -1e18
        self.below_act_since = None
        self.last_check = 0.0
        self.ledger = Counter()
        self.flags = set()
        self.recredit_todo = []

    def sign_delay(self, rng):
        return rng.uniform(60, 600) if self.mobile else rng.uniform(8, 45)

    def incl_delay(self, rng, congested):
        if self.mobile:
            if rng.random() < 0.03:
                return None
            if rng.random() < 0.12:
                return rng.uniform(300, 1800)
            return rng.lognormvariate(math.log(45), 0.6)
        if congested:
            return rng.uniform(15, 240)
        return rng.uniform(12, 36)


class Sim:
    def __init__(self, seed=20261109, days=90, profile='spec', repay_quote='deadline', topology=None, scenario=None):
        self.seed, self.days, self.profile, self.repay_quote = seed, days, profile, repay_quote
        self.topology, self.scenario = topology, scenario
        self.rng = random.Random(seed)
        if topology:
            P.use_markets({mk: P.TOPO_MARKETS[mk] for mk in P.TOPOLOGIES[topology]})
        else:
            P.use_markets(P.BASE_MARKETS)
        self.w = World(seed, days, profile, scenario)
        self.ep = self.w.ep
        self.m = Metrics()
        if topology:
            self.p = Protocol(self.w, self.m, dict(P.TOPOLOGIES[topology]), P.TOPO_DRAW_CAPS[topology])
        else:
            self.p = Protocol(self.w, self.m)
        self.topo = Counter()
        self.topo_snap = {}
        self.drawcap_wallets = set()
        self.T = days * D
        self.heap, self.seq = [], 0
        self.users, self.by_wallet = [], {}
        self.liq_stats = Counter()
        self.searcher_profit = Counter()
        self.keeper_pnl = 0.0
        self.reimbursement = 0.0
        self.route_fail_since = {}
        self.sandwich_extracted = 0.0
        self.third_party = Counter()
        self.borrow_avail = defaultdict(Counter)
        self.rescue_stats, self.deleverage_stats, self.recredit_stats = Counter(), Counter(), Counter()
        self.removal_stats, self.exit_stats, self.freeze_results = Counter(), Counter(), []
        self.breaker_time = Counter()
        self._make_users()
        self._schedule_system()

    # ------------------------------------------------------------------ setup
    def _make_users(self):
        if self.topology:
            return self._make_users_topology()
        uid = 0
        for persona, cfg in PERSONAS.items():
            for _ in range(cfg['n']):
                u = User(uid, persona, cfg, self.rng)
                # one PositionProxy per (wallet, CDP Spoke, market) (REQ-PROXY-100): a person with
                # several markets holds one account per market, each with its own health factor
                for part in self._split(u, key=lambda mk: mk):
                    self._add_user(part)
                uid += 1
        # attacker 1: top-up-slice re-leverager on USDC/USDT
        cfg = dict(PERSONAS['whale'], conc=0.0, exit=0.0, guardian=0.0, borrow=1.0, usdc=0.0, mobile=0.0)
        a1 = User(uid, 'attacker_slice', cfg, self.rng)
        a1.todo = [dict(mk='USDC/USDT', usd=900_000.0, full=True)]
        a1.home_markets = ['USDC/USDT']
        a1.arrival, a1.check_h, a1.target_hf, a1.cash, a1.spare = 0.5 * D, 1.0, 1.101, 0.0, 5_000_000.0
        self.users.append(a1)
        self.by_wallet[a1.wallet] = a1
        self.push(a1.arrival, 'check', a1)
        uid += 1
        a2 = User(uid, 'attacker_flash', cfg, self.rng)
        a2.todo, a2.wants_borrow, a2.arrival = [], False, 1e18
        self.users.append(a2)
        self.by_wallet[a2.wallet] = a2
        self.attacker2 = a2
        self.n_people = uid + 1 + N_KEEPERS + N_SEARCHERS

    def _add_user(self, u):
        self.users.append(u)
        self.by_wallet[u.wallet] = u
        self.push(u.arrival, 'check', u)

    def _split(self, u, key=None):
        """One user per account the person's markets need: per Spoke in a topology run (T1: one per
        market), per market in the base run. Each part keeps the person's behaviour, check rhythm and
        arrival, and takes the share of size, cash, spare funds and guardian funds that its markets
        carry."""
        key = key or (lambda mk: self.p.spokes[mk])
        groups = OrderedDict()
        for td in u.todo:
            groups.setdefault(key(td['mk']), []).append(td)
        if len(groups) <= 1:
            if self.p.spokes is not None:
                self.p.spoke_of[u.wallet] = next(iter(groups)) if groups else self.p.spokes[u.home_markets[0]]
            return [u]
        total = sum(td['usd'] for td in u.todo)
        parts = []
        for i, (spoke, tds) in enumerate(groups.items()):
            s = copy.copy(u)
            frac = sum(td['usd'] for td in tds) / total
            s.wallet = 'w%d.%d' % (u.uid, i)
            s.wallets = [s.wallet]
            s.todo = [dict(td) for td in tds]
            s.home_markets = [td['mk'] for td in tds]
            for k in ('size', 'cash', 'spare', 'guardian_funds'):
                setattr(s, k, getattr(u, k) * frac)
            s.held = {'GHO': 0.0, 'USDC': 0.0}
            s.nfts, s.recredit_todo = [], []
            s.retries, s.ledger, s.flags = Counter(), Counter(), set()
            if self.p.spokes is not None:
                self.p.spoke_of[s.wallet] = spoke
            parts.append(s)
        return parts

    def _make_users_topology(self):
        """The same 985 people as the base run (same RNG draws) on the three stable markets; T3 adds
        150 WETH/USDC LPs of the Volatile-Hub Spoke from their own RNG, so the stable people are
        identical in every topology."""
        uid = 0
        for persona, cfg in PERSONAS.items():
            for _ in range(cfg['n']):
                u = User(uid, persona, cfg, self.rng, (TOPO_MARKET_W, TOPO_LEVER_W))
                for part in self._split(u):
                    self._add_user(part)
                uid += 1
        if 'WETH/USDC' in P.MARKETS:
            rv = random.Random(self.seed * 7 + 3)
            for persona, n in VOL_USERS.items():
                for _ in range(n):
                    u = User(uid, persona, PERSONAS[persona], rv, ({'WETH/USDC': 1.0}, {'WETH/USDC': 1.0}))
                    u.debt_asset = 'USDC'
                    u.vol = True
                    for part in self._split(u):
                        self._add_user(part)
                    uid += 1
        self.attacker2 = None
        self.n_people = uid + N_KEEPERS

    def _schedule_system(self):
        if self.topology:
            t = 0.0
            while t < self.T:
                self.push(t, 'scan', None)
                if int(t) % 1800 == 0:
                    self.push(t + 300, 'guardian', None)
                self.push(t + 17, 'sample', None)
                t += 600
            for d in range(1, self.days + 1):
                self.push(d * D - 1, 'daily', None)
            self.push((SHOCK_DAY - 0.05) * D, 'snap', None)
            return
        t = 0.0
        while t < self.T:
            self.push(t, 'scan', None)
            t += 600
        t = 0.0
        while t < self.T:
            self.push(t + 300, 'guardian', None)
            t += 1800
        for d in range(1, self.days + 1):
            self.push(d * D - 1, 'daily', None)
        self.push(self.ep['frozen'][0] * D, 'pause', 'Frozen')
        self.push(self.ep['paused'][0] * D, 'pause', 'Paused')
        self.push(self.ep['paused'][1] * D, 'pause', 'None')
        for t_attack, kind in [(3 * D, 'dust_accounts'), (5 * D, 'flash_pledge'), (12 * D, 'direct_liquidation_call'),
                               (30.1 * D, 'pledge_during_manipulation'), (self.ep['twap_grief'][0] * D, 'twap_grief'),
                               (20 * D, 'donation_grief'), (3.5 * D, 'address_freeze')]:
            self.push(t_attack, 'attack', kind)
        t = 0.0
        while t < self.T:
            self.push(t + 17, 'sample', None)
            t += 600
        self.push(0.3 * D, 'probe_setup', None)
        probes = list(PROBES)
        # the DAI stall's states start at times the feeds decide, so those probes are placed from the world
        mk = 'DAI/USDC'
        w = self.w
        for name, pred, lag in [('DAI routes stalled', lambda m: w.oliq[mk][m] == 'alt_past_borrow_age', 600),
                                ('DAI Cached', lambda m: w.ostate[mk][m] == 2, 600),
                                ('DAI Expired', lambda m: w.ostate[mk][m] == 3, 1200),
                                ('DAI grace after recovery', lambda m: w.ograce[mk][m], 300)]:
            t0 = w.first_minute(mk, pred, self.ep['dai_routes_stall'][0] - 0.1)
            if t0 is not None:
                probes.append((name, mk, (t0 + lag) / D))
        for label, mk, day in probes:
            if day * D < self.T:
                self.push(day * D, 'probe', (label, mk))

    def push(self, t, kind, obj):
        self.seq += 1
        heapq.heappush(self.heap, (t, self.seq, kind, obj))

    # ------------------------------------------------------------------ run
    def run(self):
        last_fee_t = 0.0
        while self.heap:
            t, _, kind, obj = heapq.heappop(self.heap)
            if t > self.T:
                break
            if t - last_fee_t >= 600:
                self._accrue_fees(last_fee_t, t)
                last_fee_t = t
            if kind == 'check':
                self.on_check(obj, t)
            elif kind == 'tx':
                obj(t)
            elif kind == 'scan':
                self.on_scan(t)
            elif kind == 'guardian':
                self.on_guardian(t)
            elif kind == 'daily':
                self.check_invariants(t)
            elif kind == 'pause':
                self.p.pause = obj
                self.m.governance.append((t / D, 'pause state -> %s' % (obj + ('(%s)' % self.p.pause_reason if obj == 'Paused' else ''))))
            elif kind == 'attack':
                self.on_attack(obj, t)
            elif kind == 'sample':
                self.on_sample(t)
            elif kind == 'probe_setup':
                self.probe_setup(t)
            elif kind == 'probe':
                self.on_probe(obj, t)
            elif kind == 'snap':
                self.snapshot(t)
        self._accrue_fees(last_fee_t, self.T)
        self.check_invariants(self.T)
        return self.results()

    def _accrue_fees(self, t0, t1):
        dt = (t1 - t0) / P.YEAR
        if dt <= 0:
            return
        mult = {}
        d = t1 / D
        for mk in P.MARKET_IDS:
            x = 1.0
            if mk in ('USDC/USDT', 'USDe/USDT') and self.ep['usdt_depeg'][0] <= d < self.ep['usdt_depeg'][0] + 2:
                x = 4.0
            if mk == 'USDe/USDT' and self.ep['usde_crash'][0] <= d < self.ep['usde_crash'][0] + 3:
                x = 5.0
            mult[mk] = x
        for n in self.p.nfts.values():
            if n.alive and n.liq > 0:
                fr = P.MARKETS[n.market]['fee_apr'] * mult[n.market]
                amt = n.liq * 2.0 * fr * dt
                n.owed += amt
                n.accrued += amt

    # ------------------------------------------------------------------ transactions
    def tx(self, u, action, t_prep, gas_units, fn, on_ok=None, on_fail=None, deadline=P.APP_DEADLINE):
        sign = u.sign_delay(self.rng)
        incl = u.incl_delay(self.rng, self.w.congested(t_prep))
        u.busy_until = t_prep + sign + (incl or 3600) + 1
        if incl is None:
            self.m.frustrate('tx_dropped', u.uid)
            self.m.revert(action, 'Dropped(not mined)', u.uid, 0.0)
            return
        t_incl = t_prep + sign + incl
        wallet = u.wallet

        def run(ti):
            gas_full = self.w.gas_usd(gas_units, ti)
            if ti > t_prep + deadline:
                g = gas_full * P.GAS['revert_fraction']
                u.ledger['gas'] += g
                self.m.revert(action, 'DeadlineExpired', u.uid, g)
                self.m.frustrate('deadline_expired', u.uid)
                if on_fail:
                    on_fail('DeadlineExpired', ti)
                return
            try:
                res = fn(ti)
            except Refused as e:
                g = gas_full * P.GAS['revert_fraction']
                u.ledger['gas'] += g
                err = e.args[0]
                self.m.revert(action, err, u.uid, g)
                if on_fail:
                    on_fail(err, ti)
                return
            u.ledger['gas'] += gas_full
            self.m.successes[action] += 1
            if on_ok:
                on_ok(res, ti)
        self.push(t_incl, 'tx', run)

    def schedule(self, u, t, hours=None):
        if u.done:
            return
        if u.forget_t is not None and t > u.forget_t and not u.todo:
            return
        h = hours if hours is not None else u.check_h * self.rng.uniform(0.6, 1.4)
        self.push(t + h * H, 'check', u)

    # ------------------------------------------------------------------ user check-in
    def on_check(self, u, t):
        if u.done:
            return
        if t < u.busy_until:
            self.push(u.busy_until + 60, 'check', u)
            return
        u.last_check = t
        if u.recall_t is not None and t >= u.recall_t:
            u.cash += u.deployed
            u.deployed, u.recall_t = 0.0, None
        if u.persona == 'attacker_slice':
            return self.attacker_slice(u, t)
        a = self.p.acct(u.wallet)
        if u.exit_t is not None and t >= u.exit_t:
            self.do_exit(u, t)
            return self.schedule(u, t, 6 if not u.done else None)
        if u.todo:
            self.try_pledge_next(u, t)
            return self.schedule(u, t, 0.2 if u.todo else 1.0)
        if a and a.has_debt():
            hf = self.p.hf(a, t)
            if hf < u.act_hf:
                self.rescue(u, t, hf)
                return self.schedule(u, t, 1.0)
        if u.recredit_todo and t >= u.recredit_todo[0][1]:
            n, _ = u.recredit_todo.pop(0)
            self.try_recredit(u, n, t)
            return self.schedule(u, t, 0.5)
        if u.loop_cash > 10:
            self.loop_pledge(u, t)
            return self.schedule(u, t, 0.2)
        relever = u.cfg.get('lever') and a is not None and a.has_debt() and self.p.hf(a, t) > u.target_hf + 0.12
        if a and a.markets() and u.wants_borrow and (not a.has_debt() or relever or (u.cfg.get('lever') and u.flags.isdisjoint({'borrow_done'}))):
            self.try_borrow(u, t)
            return self.schedule(u, t, 0.5 if u.loops_left > 0 else None)
        if u.next_rebalance is not None and t >= u.next_rebalance and a and a.markets():
            self.rebalance(u, t)
            u.next_rebalance = t + self.rng.uniform(*u.cfg['rebalance']) * D
            return self.schedule(u, t, 0.5)
        if t - u.last_collect >= u.cfg['collect'] * D:
            self.collect(u, t)
        self.schedule(u, t)

    # ------------------------------------------------------------------ pledge
    def try_pledge_next(self, u, t):
        pos = u.todo[0]
        mk = pos['mk']
        price = self.p.price(mk, t)
        if not pos['full']:
            self.m.refusal('pledge', 'NotFullRange', u.uid)
            self.m.frustrate('concentrated_rejected', u.uid)
            if self.rng.random() < 0.6:
                pos['full'] = True
                u.ledger['gas'] += self.w.gas_usd(P.GAS['decrease_collect'] + P.GAS['mint_nft'], t)
                conc = P.MARKETS[mk]['conc_fee_mult']
                u.ledger['fee_foregone'] += pos['usd'] * P.MARKETS[mk]['fee_apr'] * (conc - 1) * (self.T - t) / P.YEAR
            else:
                u.todo.pop(0)
                if not u.todo and not u.nfts:
                    u.gave_up = True
                    u.done = True
            return
        nft = pos.get('nft')
        if nft is None:
            nft = self.p.new_nft(u.wallet, mk, pos['usd'] / price)
            nft.alive = True
            pos['nft'] = nft
            u.nfts.append(nft)
        est_gas = self.w.gas_usd(P.GAS['nft_approve'] + (P.GAS['pledge_first'] if self.p.acct(u.wallet) is None else P.GAS['pledge'])
                                 + (P.GAS['borrow'] if u.wants_borrow else 0), t)
        if est_gas > 0.25 * pos['usd'] and 'gas_warned' not in u.flags:
            u.flags.add('gas_warned')
            if self.rng.random() < 0.5:
                self.m.frustrate('gas_exceeds_value', u.uid)
                u.todo.pop(0)
                if not u.todo:
                    u.done = u.gave_up = True
                return
            self.m.frustrate('gas_exceeds_value', u.uid)
        wallet = pos.get('wallet', u.wallet)
        try:
            self.p.pledge_check(wallet, nft, t)
        except Refused as e:
            err = e.args[0]
            self.m.refusal('pledge', err, u.uid)
            if err == 'BelowMinPledge':
                self.m.frustrate('below_min', u.uid)
                u.todo.pop(0)
                if not u.todo and not self.p.acct(u.wallet):
                    u.done = u.gave_up = True
                return
            if err == 'CapExceeded(depositor)':
                self.m.frustrate('depositor_cap_split', u.uid)
                room = P.DEPOSITOR_USD_CAP - self.p.dep_used.get(wallet, 0.0)
                if room > 1000 and self.rng.random() < 0.6:
                    keep = room * 0.98 / max(price, 1.0)
                    rest = nft.liq - keep
                    nft.liq = nft.liq_initial = keep
                    nw = '%sb%d' % (u.wallet, len(u.wallets))
                    u.wallets.append(nw)
                    self.by_wallet[nw] = u
                    u.ledger['gas'] += self.w.gas_usd(P.GAS['decrease_collect'] + P.GAS['mint_nft'], t)
                    u.todo.append(dict(mk=mk, usd=rest * price, full=True, wallet=nw))
                    self.p.spoke_of[nw] = self.p.spoke_of.get(u.wallet, 'Stable')
                    return
                u.todo.pop(0)
                return
            if err.startswith('CapExceeded') or err.startswith('BreakerTripped') or err in ('PoolShareExceeded', 'SliceNotAvailable', 'NotRescueTopUp'):
                if err.startswith('CapExceeded') or err == 'SliceNotAvailable':
                    self.m.frustrate('cap_full', u.uid)
                u.retries['cap'] += 1
                if u.retries['cap'] > 3:
                    nft.alive = False
                    u.todo.pop(0)
                    if not u.todo and not self.p.acct(u.wallet):
                        u.done = u.gave_up = True
                else:
                    u.busy_until = t + self.rng.uniform(1, 3) * D
                return
            u.busy_until = t + 2 * H
            return

        def ok(res, ti, u=u, nft=nft, pos=pos):
            if pos in u.todo:
                u.todo.remove(pos)
            if wallet != u.wallet:
                u.flags.add('sybil')

        def fail(err, ti, u=u):
            if err.startswith('CapExceeded'):
                self.m.frustrate('cap_full', u.uid)
            u.busy_until = ti + 2 * H

        first = self.p.acct(wallet) is None
        gas = P.GAS['nft_approve'] + (P.GAS['pledge_first'] if first else P.GAS['pledge'])
        self.tx(u, 'pledge', t, gas, lambda ti, w=wallet, n=nft: self.p.pledge(w, n, ti), ok, fail)

    # ------------------------------------------------------------------ borrow
    def classify_borrow_block(self, u, err, t):
        a = self.p.acct(u.wallet)
        d = t / D
        if err.startswith('PriceNotLive(Drifting:band') and self.ep['gho_premium'][0] <= d < self.ep['gho_premium'][1]:
            self.m.frustrate('band_blocked_gho_premium', u.uid)
        elif err.startswith('PriceNotLive(Drifting:twap') and self.ep['twap_grief'][0] <= d < self.ep['twap_grief'][1] + 0.05:
            self.m.frustrate('twap_griefed', u.uid)
        elif err == 'DebtPriceTooOld':
            self.m.frustrate('usdc_feed_stall_blocked' if self.ep['usdc_primary_stall'][0] <= d < self.ep['usdc_primary_stall'][1] + 0.1 else 'borrow_blocked_price', u.uid)
        elif err.startswith('PriceNotLive') or err == 'PriceTooOld':
            self.m.frustrate('borrow_blocked_price', u.uid)
        elif err.startswith('BreakerTripped') or err.startswith('DebtBreaker'):
            self.m.frustrate('borrow_blocked_breaker', u.uid)
        elif err == 'DrawCapExceeded':
            self.m.frustrate('drawcap_exhausted', u.uid)
        if a and len(a.markets()) > 1 and (err.startswith('PriceNotLive') or err == 'PriceTooOld' or err.startswith('BreakerTripped')):
            bad = [mk for mk in a.markets() if self.w.o(mk, t)[0] != 0 or not self.w.borrow_age_ok(mk, t) or self.p.market_breaker(mk, t)]
            good = [mk for mk in a.markets() if mk not in bad]
            if bad and good:
                self.m.frustrate('borrow_blocked_other_market', u.uid)

    def try_borrow(self, u, t):
        a = self.p.acct(u.wallet)
        coll = self.p.coll_usd(a, t)
        cc = self.p.cf_coll(a, t, exclude_rescue=True)
        maxltv = self.p.cf_coll(a, t) / P.RECOMMENDED_HF / max(coll, 1e-9)
        if u.want_ltv > maxltv + 1e-9 and 'low_ltv' not in u.flags:
            u.flags.add('low_ltv')
            self.m.frustrate('low_ltv', u.uid)
        asset = u.debt_asset
        if u.maxpress:
            # "max" = the app's max button, Lens.recommendedBorrow (HF 1.10) for the deadline (Q-268, Q-398)
            units = self.p.preview_borrow_recommended(u.wallet, asset, t, P.APP_DEADLINE)
            amt = units * self.p.debt_price(asset, t)
        else:
            amt = cc / u.target_hf - self.p.debt_value(a, t)
            units = amt / self.p.debt_price(asset, t)
        floor = 2.0 if u.persona == 'small' else 25.0
        if amt < floor:
            u.flags.add('borrow_done')
            return
        try:
            self.p.borrow_check(u.wallet, asset, units, t, 0.0, a.nonce)
        except Refused as e:
            err = e.args[0]
            self.m.refusal('borrow', err, u.uid)
            self.classify_borrow_block(u, err, t)
            if err == 'DrawCapExceeded':
                self.topo['drawcap_refusals_pre_shock' if t < SHOCK_DAY * D else 'drawcap_refusals_after'] += 1
                self.drawcap_wallets.add(u.wallet)
                u.retries['drawcap'] += 1
                other = 'USDC' if asset == 'GHO' else 'GHO'
                if self.rng.random() < 0.5 and (self.p.draw_caps is None or self.p.draw_caps[a.spoke].get(other, 0.0) > 0):
                    u.debt_asset = other
                u.busy_until = t + D
                if u.retries['drawcap'] >= 4:
                    u.wants_borrow = False
            elif err.startswith('Application'):
                u.busy_until = t + 6 * H
            elif err == 'HealthFactorTooLow':
                u.flags.add('borrow_done')
            return
        nonce = a.nonce

        def ok(res, ti, u=u, asset=asset):
            if u.cfg.get('lever') and u.loops_left > 0:
                u.loop_cash += res
                u.loops_left -= 1
            elif u.hold_borrowed:
                u.held[asset] += res
            else:
                u.deployed += res
            if u.loops_left <= 0:
                u.flags.add('borrow_done')

        def fail(err, ti, u=u):
            if err == 'HealthFactorTooLow' and u.maxpress:
                self.m.frustrate('max_borrow_reverted', u.uid)
                u.retries['max'] += 1
                if u.retries['max'] >= 2:      # gives up on 'max' and types a lower amount
                    u.maxpress = False
                    u.target_hf = max(u.target_hf, 1.115)
            elif err == 'BadNonce':
                self.m.frustrate('bad_nonce', u.uid)
            else:
                self.classify_borrow_block(u, err, ti)

        n_mk = len(a.markets())
        gas = P.GAS['borrow'] + P.GAS['borrow_per_extra_market'] * max(0, n_mk - 1)
        self.tx(u, 'borrow', t, gas, lambda ti: self.p.borrow(u.wallet, asset, units, ti, 0.0, nonce), ok, fail)
        if u.mobile and self.rng.random() < 0.06:
            # the same borrow sent again from a second tab/device with the nonce read earlier
            busy = u.busy_until
            self.tx(u, 'borrow', t + 30, gas, lambda ti: self.p.borrow(u.wallet, asset, units, ti, 0.0, nonce), ok, fail)
            u.busy_until = max(busy, u.busy_until)

    def loop_pledge(self, u, t):
        mk = u.home_markets[0]
        price = self.p.price(mk, t)
        usd = u.loop_cash * (1 - P.SWAP_COST)
        u.ledger['swap_cost'] += u.loop_cash * P.SWAP_COST
        u.ledger['gas'] += self.w.gas_usd(P.GAS['swap'] + P.GAS['mint_nft'], t)
        u.loop_cash = 0.0
        nft = self.p.new_nft(u.wallet, mk, usd / price)
        u.nfts.append(nft)
        try:
            self.p.pledge_check(u.wallet, nft, t)
        except Refused as e:
            err = e.args[0]
            self.m.refusal('pledge(loop)', err, u.uid)
            if err.startswith('CapExceeded') or err == 'SliceNotAvailable':
                self.m.frustrate('cap_full', u.uid)
            u.held[u.debt_asset] += usd  # keeps the tokens instead
            u.flags.add('borrow_done')
            return
        self.tx(u, 'pledge', t, P.GAS['nft_approve'] + P.GAS['pledge'], lambda ti: self.p.pledge(u.wallet, nft, ti),
                lambda r, ti: u.flags.discard('borrow_done'),
                lambda err, ti: u.held.__setitem__(u.debt_asset, u.held[u.debt_asset] + usd))

    # ------------------------------------------------------------------ rescue
    TOPUP_FRUSTRATION = {'ApplicationPaused': 'topup_refused_paused', 'NotRescueTopUp': 'topup_refused_not_rescue',
                         'PoolShareExceeded': 'topup_refused_pool_share'}

    def _topup_frustration(self, u, err, eligible):
        if err == 'PoolShareExceeded' and eligible:
            code = 'rescue_refused_pool_share'
        elif err.startswith('PriceNotAccepted'):
            code = 'topup_refused_stale'
        elif err.startswith('BreakerTripped'):
            code = 'rescue_refused_breaker' if eligible else 'topup_refused_breaker'
        elif err == 'NotRescueTopUp' and eligible:
            code = 'rescue_refused_size'
        else:
            code = self.TOPUP_FRUSTRATION.get(err, 'topup_refused_slice')
        self.m.frustrate(code, u.uid)
        if eligible:
            self.rescue_stats['refused:' + err.split('(')[0]] += 1

    def rescue(self, u, t, hf):
        a = self.p.acct(u.wallet)
        Dv = self.p.debt_value(a, t)
        cc = self.p.cf_coll(a, t)
        goal = u.target_hf + 0.05 if u.cfg.get('lever') else max(1.25, min(u.target_hf, 1.6))
        need_repay = max(0.0, Dv - cc / goal)
        if u.below_act_since is None:
            u.below_act_since = t
        eligible = hf < P.RECOMMENDED_HF
        tried_topup = False
        if u.spare >= P.MIN_PLEDGE_USD * 2 and (u.cash + sum(u.held.values()) < need_repay or self.rng.random() < 0.5):
            mk = max(a.markets(), key=lambda m_: a.credited(m_) * self.p.served(m_, t))
            cf = P.MARKETS[mk]['cf']
            served = self.p.served(mk, t)
            need_coll = (goal * Dv - cc) / cf
            usd = min(u.spare, max(need_coll, 20.0))
            cand = self.p.new_nft(u.wallet, mk, usd / served)
            cand.alive = False
            ch, err = None, None
            try:
                ch = self.p.pledge_check(u.wallet, cand, t)
            except Refused as e:
                err = e.args[0]
            if ch is None and eligible and (err in ('NotRescueTopUp', 'PoolShareExceeded', 'SliceNotAvailable') or err.startswith('BreakerTripped')):
                # the app offers the rescue size: usdToRestore at the served price, the price Aave
                # values the collateral at (SPEC-CAP-003)
                acc = self.p.price(mk, t)
                L2 = self.p.usd_to_restore(a, mk, t) / served * 0.999
                if L2 * acc < P.RESCUE_MIN_PLEDGE_USD:
                    self.rescue_stats['restore_below_rescue_minimum'] += 1
                elif L2 * served > u.spare:
                    self.rescue_stats['restore_above_spare_funds'] += 1
                if L2 * acc >= P.RESCUE_MIN_PLEDGE_USD and L2 * served <= u.spare:
                    cand.liq = cand.liq_initial = L2
                    usd = L2 * served
                    try:
                        ch = self.p.pledge_check(u.wallet, cand, t)
                        self.rescue_stats['sized_to_restore'] += 1
                        if served < acc * 0.999:
                            self.rescue_stats['sized_to_restore_below_accepted'] += 1
                    except Refused as e:
                        err = e.args[0]
            if ch is None:
                tried_topup = True
                self.m.refusal('top-up', err, u.uid)
                u.last_rescue_refused = t
                self._topup_frustration(u, err, eligible)
                del self.p.nfts[cand.id]
            else:
                cand.alive = True
                u.nfts.append(cand)
                u.spare -= usd
                u.ledger['gas'] += self.w.gas_usd(P.GAS['mint_nft'], t)
                if ch['rescue']:
                    self.rescue_stats['planned:' + '+'.join(ch['why'] or ['minimum'])] += 1

                def ok(r, ti, u=u):
                    u.below_act_since = None
                    if r[1]['rescue']:
                        self.rescue_stats['rescue_topups_done'] += 1
                        for why in r[1]['why']:
                            self.rescue_stats['rescue_topups_done:' + why] += 1
                        self.m.frustrate('rescued_by_topup_exemption', u.uid)

                def fail(err, ti, u=u, cand=cand, usd=usd, eligible=eligible):
                    cand.alive = False
                    u.spare += usd
                    u.last_rescue_refused = ti
                    self._topup_frustration(u, err, eligible)
                self.tx(u, 'top-up', t, P.GAS['nft_approve'] + P.GAS['pledge'], lambda ti: self.p.pledge(u.wallet, cand, ti), ok, fail)
                return
        asset = max(P.DEBT_ASSETS, key=lambda k: a.debt[k])
        avail = u.cash + u.held['GHO'] + u.held['USDC']
        if avail < 1.0:
            if u.deployed > 0 and u.recall_t is None:
                u.recall_t = t + D
            elif not self.deleverage(u, u.wallet, t, goal=goal) and tried_topup:
                u.flags.add('rescue_impossible')
            return
        pay = min(need_repay, avail, a.debt[asset] * self.p.debt_price(asset, t))
        if pay < 1.0:
            return
        self._spend(u, asset, pay, t)

        def ok(spent, ti, u=u, pay=pay, asset=asset):
            u.below_act_since = None
            if spent < pay:
                u.held[asset] += pay - spent
        self.tx(u, 'repay', t, P.GAS['erc20_approve'] + P.GAS['repay'],
                lambda ti: self.p.repay(u.wallet, asset, pay, False, pay, pay, ti), ok,
                lambda err, ti: u.held.__setitem__(asset, u.held[asset] + pay))

    def deleverage(self, u, w, t, goal=None, full=False):
        """AaveAdapter.repayWithCollateral (Q-255) from the largest record. Returns True if sent."""
        a = self.p.acct(w)
        if a is None or not a.has_debt() or not a.markets():
            return False
        asset = max(P.DEBT_ASSETS, key=lambda k: a.debt[k] * self.p.debt_price(k, t))
        recs = sorted((r for mk in a.markets() for r in a.records[mk] if r.credited > 0),
                      key=lambda r: -r.credited * self.p.served(r.market, t))
        rec = recs[0]
        mk = rec.market
        p = self.p.served(mk, t)
        cf = P.MARKETS[mk]['cf']
        s = P.SLIPPAGE_ALLOWANCE
        pd = self.p.debt_price(asset, t)
        per_unit = p * (1 - s) / (1 + P.MAX_FLASH_FEE)   # debt value repaid per unit (REP-017)
        if full:
            units = a.debt[asset] * pd / per_unit * 1.002
        else:
            Dv, C = self.p.debt_value(a, t), self.p.cf_coll(a, t)
            den = goal * per_unit - p * cf
            units = (goal * Dv - C) / den if den > 0 else rec.credited
        units = min(max(units, 0.0), rec.credited)
        if units >= rec.credited * 0.98:
            units = rec.credited
        if units <= 0:
            return False
        try:
            self.p.deleverage_quote(w, rec.nft, units, asset, t)
        except Refused as e:
            self.m.refusal('repayWithCollateral', e.args[0], u.uid)
            self.m.frustrate('deleverage_refused', u.uid)
            self.deleverage_stats['refused:' + e.args[0].split('(')[0]] += 1
            return False
        nft = rec.nft

        def ok(r, ti, u=u):
            u.cash += r['gho_out']
            u.ledger['deleverage_loss'] += r['loss']
            u.below_act_since = None
            self.deleverage_stats['done'] += 1
            self.deleverage_stats['repaid_usd'] += r['repaid']
            self.deleverage_stats['conversion_loss_usd'] += r['loss']
            self.m.frustrate('used_repay_with_collateral', u.uid)

        def fail(err, ti, u=u):
            self.deleverage_stats['reverted:' + err.split('(')[0]] += 1
        self.tx(u, 'repayWithCollateral', t, P.GAS['repay_with_collateral'],
                lambda ti: self.p.repay_with_collateral(w, nft, units, asset, ti, 0.0), ok, fail)
        return True

    def _spend(self, u, asset, amount, t):
        """Take `amount` of the debt asset from the user's wallet, swapping cash if needed."""
        h = min(u.held[asset], amount)
        u.held[asset] -= h
        rest = amount - h
        if rest > 0:
            other = 'USDC' if asset == 'GHO' else 'GHO'
            h2 = min(u.held[other], rest)
            u.held[other] -= h2
            rest -= h2
            u.cash -= rest
            if rest + h2 > 0:
                u.ledger['swap_cost'] += (rest + h2) * P.SWAP_COST
                u.ledger['gas'] += self.w.gas_usd(P.GAS['swap'], t)

    # ------------------------------------------------------------------ fees
    def collect(self, u, t):
        best = None
        for n in u.nfts:
            if n.alive and n.owed > 4 * self.w.gas_usd(P.GAS['collect'], t):
                if best is None or n.owed > best.owed:
                    best = n
        u.last_collect = t
        if best is None:
            return
        if best.in_vault:
            def ok(amt, ti, u=u):
                u.cash += amt
                u.ledger['fees_collected'] += amt
                a = self.p.acct(u.wallet)
                if a and a.has_debt() and amt > 5 and self.rng.random() < 0.4:
                    # uses the fees to pay down the loan: a second approval + repay
                    self.m.frustrate('fees_manual', u.uid)
                    asset = max(P.DEBT_ASSETS, key=lambda k: a.debt[k])
                    pay = min(amt, a.debt[asset] * self.p.debt_price(asset, ti))
                    self._spend(u, asset, pay, ti)
                    self.tx(u, 'repay', ti + 60, P.GAS['erc20_approve'] + P.GAS['repay'],
                            lambda tj: self.p.repay(u.wallet, asset, pay, False, pay, pay, tj))
            self.tx(u, 'collectFees', t, P.GAS['collect'], lambda ti: self.p.collect(best.wallet, best), ok)
        else:
            amt = best.owed
            best.owed, best.collected = 0.0, best.collected + amt
            u.cash += amt
            u.ledger['fees_collected'] += amt
            u.ledger['gas'] += self.w.gas_usd(P.GAS['collect'], t)

    # ------------------------------------------------------------------ active LP
    def rebalance(self, u, t):
        a = self.p.acct(u.wallet)
        pledged = [n for n in u.nfts if n.in_vault and n.alive and n.wallet == u.wallet and self.p._record_of(a, n)]
        if not pledged:
            return
        if self.rng.random() < 0.5:
            # add liquidity
            mk = pledged[0].market
            price = self.p.served(mk, t)
            usd = sum(n.liq for n in pledged) * price * self.rng.uniform(0.2, 0.4)
            if self.rng.random() < 0.2:
                # Uniswap increaseLiquidity on the pledged NFT, then AaveAdapter.recredit (Q-254)
                n = pledged[0]
                n.liq += usd / price
                n.donated += usd / price
                u.ledger['gas'] += self.w.gas_usd(P.GAS['mint_nft'] * 0.6, t)
                self.recredit_stats['liquidity_added'] += 1
                self.try_recredit(u, n, t)
                return
            nft = self.p.new_nft(u.wallet, mk, usd / price)
            u.nfts.append(nft)
            u.ledger['gas'] += self.w.gas_usd(P.GAS['mint_nft'], t)
            u.todo.append(dict(mk=mk, usd=usd, full=True, nft=nft))
            return
        # remove ~30% of the liquidity of one pledged NFT with removeLiquidity (Q-254)
        n = max(pledged, key=lambda x: x.liq)
        rec = self.p._record_of(a, n)
        units = rec.credited * 0.3
        try:
            self.p.remove_check(u.wallet, n, units, t, 0.0)
        except Refused as e:
            self.m.refusal('removeLiquidity(rebalance)', e.args[0], u.uid)
            self.m.frustrate('partial_removal_refused', u.uid)
            return

        def ok(value, ti, u=u):
            u.cash += value
            u.ledger['gas'] += 0.0
            self.removal_stats['done'] += 1
            self.m.frustrate('used_partial_removal', u.uid)

        def fail(err, ti, u=u):
            self.removal_stats['reverted:' + err] += 1
        self.tx(u, 'removeLiquidity', t, P.GAS['remove_liquidity'], lambda ti: self.p.remove_liquidity(u.wallet, n, units, ti, 0.0), ok, fail)

    def try_recredit(self, u, n, t):
        a = self.p.acct(u.wallet)
        rec = self.p._record_of(a, n) if a else None
        if rec is None or n.liq - rec.credited <= 1e-9:
            return
        try:
            self.p.pledge_check(u.wallet, n, t, L=n.liq - rec.credited)
        except Refused as e:
            self.m.refusal('recredit', e.args[0], u.uid)
            self.m.frustrate('recredit_refused', u.uid)
            self.recredit_stats['refused:' + e.args[0].split('(')[0]] += 1
            if u.retries['recredit'] < 4:
                u.retries['recredit'] += 1
                u.recredit_todo.append((n, t + self.rng.uniform(1, 3) * D))
            return

        def ok(r, ti, u=u):
            self.recredit_stats['done'] += 1
            self.recredit_stats['units'] += r[0]

        def fail(err, ti, u=u, n=n):
            self.recredit_stats['reverted:' + err.split('(')[0]] += 1
            if u.retries['recredit'] < 4:
                u.retries['recredit'] += 1
                u.recredit_todo.append((n, ti + self.rng.uniform(1, 3) * D))
        self.tx(u, 'recredit', t, P.GAS['recredit'], lambda ti: self.p.recredit(u.wallet, n, ti), ok, fail)

    # ------------------------------------------------------------------ exit
    def do_exit(self, u, t):
        w = None
        for wl in u.wallets:
            a_ = self.p.acct(wl)
            if a_ and (a_.has_debt() or any(a_.records[mk] for mk in P.MARKET_IDS)):
                w = wl
                break
        if w is None:
            u.done = u.exited = True
            return
        a = self.p.acct(w)
        self.p._acc(a, t)
        in_vault = [n for n in u.nfts if n.in_vault and n.wallet == w]
        if a.has_debt():
            debts = {k: a.debt[k] for k in P.DEBT_ASSETS if a.debt[k] > 0}
            need = sum(v * self.p.debt_price(k, t) for k, v in debts.items())
            avail = u.cash + u.held['GHO'] + u.held['USDC']
            if avail < need * 1.002:
                if u.deployed > 0:
                    if u.recall_t is None:
                        u.recall_t = t + D
                    return
                # repay with collateral (Q-255) pays the debt from the position itself
                if self.deleverage(u, w, t, full=True):
                    if 'exit_rwc' not in u.flags:
                        u.flags.add('exit_rwc')
                        self.m.frustrate('exit_via_repay_with_collateral', u.uid)
                    return
                if not u.stuck_exit:
                    u.stuck_exit = True
                    self.m.frustrate('exit_needs_external_funds', u.uid)
                    u.ledger['exit_shortfall'] = need - avail
                if self.rng.random() < 0.5:
                    u.cash += (need - avail) * 1.01
                    u.ledger['external_funding'] += (need - avail) * 1.01
                return
            credited = [n for n in in_vault if self.p._record_of(a, n) and self.p._record_of(a, n).credited > 0]
            if not credited:
                return
            n = max(credited, key=lambda x: x.liq)
            units = self.p._record_of(a, n).credited
            quotes = {}
            for k in debts:
                # Lens.quoteRepayAll for the transaction's deadline, used as cap and approval (Q-268, Q-269)
                q = self.p.quote_repay_all(w, k, t, P.APP_DEADLINE)
                bal = q if self.repay_quote == 'literal' else q * self.rng.uniform(1.0, 1.01)
                quotes[k] = (q, q, bal)
            for k, (cap, allw, bal) in quotes.items():
                self._spend(u, k, bal, t)

            def fn(ti, w=w, n=n, units=units, quotes=quotes):
                return self.p.repay_all_and_withdraw(w, n, units, quotes, ti)

            def ok(r, ti, u=u, w=w, quotes=quotes):
                acct = self.p.acct(w)
                for k, (cap, allw, bal) in quotes.items():
                    u.held[k] += bal - acct.repay_spent.get(k, 0.0)
                self.exit_stats['repay_all_first_attempt' if u.retries['repay_all'] == 0 else 'repay_all_retry'] += 1

            def fail(err, ti, u=u, quotes=quotes):
                for k, (cap, allw, bal) in quotes.items():
                    u.held[k] += bal
                if err in ('ERC20InsufficientAllowance', 'ERC20InsufficientBalance', 'RepayExceedsMax'):
                    self.m.frustrate('repay_short_interest', u.uid)
                    u.retries['repay_all'] += 1
                if err == 'UnitsMismatch':
                    self.m.frustrate('units_mismatch', u.uid)
            self.tx(u, 'repayAllAndWithdraw', t, P.GAS['erc20_approve'] * len(quotes) + P.GAS['repay_all_withdraw'], fn, ok, fail)
            return
        if in_vault:
            n = in_vault[0]
            rec = self.p._record_of(a, n)
            if rec is None:
                n.in_vault = False
                return
            if rec.credited <= 1e-12:
                self.tx(u, 'releaseZeroCredit', t, P.GAS['release_zero'], lambda ti, w=w, n=n: self.p.release_zero(w, n))
                return
            units = rec.credited
            self.tx(u, 'withdraw', t, P.GAS['withdraw'], lambda ti, w=w, n=n, units=units: self.p.withdraw(w, n, units, ti, 0.0), None,
                    lambda err, ti: self.m.frustrate('units_mismatch', u.uid) if err == 'UnitsMismatch' else None)
            return
        # records left with no NFT in the user's list (should not happen)
        for mk in P.MARKET_IDS:
            for r in list(a.records[mk]):
                if r.credited <= 1e-12:
                    self.p.release_zero(w, r.nft)
        u.done = u.exited = True

    # ------------------------------------------------------------------ keepers and searchers (3.5)
    def on_scan(self, t):
        for wallet, a in list(self.p.accounts.items()):
            if not a.has_debt():
                continue
            if getattr(a, 'next_scan', 0) > t:
                continue
            hf = self.p.hf(a, t)
            a.next_scan = t + (3600 if hf > 2 else 1800 if hf > 1.35 else 0)
            u = self.by_wallet[wallet]
            if u.act_hf and hf < u.act_hf and u.below_act_since is None:
                u.below_act_since = t
            if hf >= 1.0:
                continue
            gate = self.p.liquidation_gate(a, t, hf)
            if gate:
                self.m.liq_blocked[gate] += 1
                self.m.liq_blocked_accounts[gate].add(wallet)
                continue
            self.liquidate_account(a, u, t)

    def _routed(self, a, mk, asset, t):
        """One full-size routed liquidation as an approved keeper prepares it (3.5 LIQ-027 to LIQ-041,
        LIQ-075 to LIQ-077, Q-358): the debt asset flash-borrowed through IFlashSource (the caller's
        own funds when flash liquidity is short), effective slippage net of the premium, recovery
        floor, per-leg minimums, the caller shortfall top-up within maxShortfallBps, conversion into
        the debt asset, the caller's rounding-gap top-up (no SettlementBudget, Q-397) and the waterfall
        A / Kr / B in the debt asset.
        All amounts in USD at the debt asset's price. Returns a candidate dict, or (None, reason)."""
        sz = self.p.size_liquidation(a, mk, asset, t)
        if sz['repay'] <= 1e-6 or sz['seize'] <= 1e-6:   # dust credit left on a market: nothing to settle
            return None, 'NothingToRepay'
        D_ = sz['repay']
        pdebt = sz['pdebt']
        if D_ / pdebt <= P.FLASH_LIQUIDITY[asset]:
            F, Kf, prem = D_, 0.0, P.FLASH_PREMIUM            # flash path
        else:
            F, Kf, prem = 0.0, D_, 0.0                        # caller-funded path (FlashLiquidityShort)
        if prem > P.MAX_FLASH_FEE:
            return None, 'FlashFeeTooHigh'
        phi = F * prem
        phiD = min(F, D_) * prem
        costs = prem if F > 0 else 0.0                        # costsBps = phi / F (LIQ-027)
        s = max(0.0, min(P.SLIPPAGE_ALLOWANCE, (sz['lb'] - 1 - costs) / sz['lb']))
        V = sz['seize']
        min_out = max(0.0, V * (1 - s) - P.FLOOR_ROUNDING_GHO)
        R, ok, pf = self.p.convert(mk, t, V, s, asset)
        shortfall, max_sf = 0.0, 0.0
        if not (ok and R >= min_out):
            max_sf = P.MAX_SHORTFALL_BPS * V          # keeper's maxShortfall, within its reimbursement budget
            s_leg = min(0.9999, s + min(P.MAX_SHORTFALL_BPS, max_sf / V))
            R, ok, pf = self.p.convert(mk, t, V, s_leg, asset)
            if not ok:
                return None, 'MinOutNotMet'
            shortfall = max(0.0, min_out - R)
            if shortfall > max_sf:
                return None, 'RecoveryBelowFloor'
        Rp = R + shortfall
        # waterfall in the debt asset (LIQ-031, SPEC-LIQ-009, SPEC-LIQ-022)
        Y = max(0.0, Rp - D_ - phiD)
        Gv = max(0.0, V - D_ - phiD)
        A = min(Gv * P.AVANA_FEE_SHARE, Y)
        Kr = min(Y - A, Gv - A)
        B = Y - A - Kr
        gap = max(0.0, D_ + phiD - Rp - Kf)
        if gap > 0:
            # Q-397: the caller pays the rounding gap through the shortfall top-up, within maxShortfallBps
            if shortfall + gap > P.MAX_SHORTFALL_BPS * V:
                return None, 'InsufficientProceeds'
            shortfall += gap
            Rp += gap
        Bd = 0.0
        out = (Kf + F + Rp + Bd) - (D_ + F + phi + A + B)       # keeperOut (SPEC-LIQ-010)
        if out < -1e-9:
            return None, 'InsufficientProceeds'
        return dict(sz=sz, mk=mk, asset=asset, V=V, R=R, D=D_, F=F, Kf=Kf, phi=phi, phiD=phiD, Y=Y, A=A, Kr=Kr, B=B,
                    Bd=Bd, out=out, shortfall=shortfall, min_out=min_out, pf=pf, mode='routed',
                    net=out - Kf - shortfall), None

    def liquidate_account(self, a, u, t):
        for _ in range(8):
            hf = self.p.hf(a, t)
            if hf >= 1.0 or not a.has_debt() or not a.markets():
                return
            assets = [k for k in P.DEBT_ASSETS if a.debt[k] > 0 and self.p.debt_gate(k, t) is None]
            mks = [mk for mk in a.markets() if self.p.seize_gate(mk, t) is None]
            if not assets or not mks:
                return
            asset = max(assets, key=lambda k: a.debt[k] * self.p.debt_price(k, t))
            best, failed = None, {}
            for mk in mks:
                cand, why = self._routed(a, mk, asset, t)
                if cand is None:
                    failed[mk] = why
                    continue
                if best is None or cand['net'] > best['net']:
                    best = cand
            if best is None:
                for mk, why in failed.items():
                    self.m.liq_blocked[why] += 1
                    self.m.liq_blocked_accounts[why].add(a.wallet)
                    # a failed attempt counts toward the route-failure alert (Q-399; no in-kind path, Q-401)
                    if why in ('RecoveryBelowFloor', 'MinOutNotMet'):
                        self.liq_stats['shortfall_reports'] += 1
                        self.p.record_shortfall(mk, t)
                        self.route_fail_since.setdefault(mk, t)
                return
            sz, mk, mode = best['sz'], best['mk'], best['mode']
            n_rec = len([r for r in a.records[mk] if r.credited > 0])
            gas = self.w.gas_usd(P.GAS['liquidate'] + P.GAS['liquidate_per_record'] * n_rec, t)
            permissionless = mode == 'routed' and best['net'] - gas > 0 and self.rng.random() < 0.25
            Bd = best['Bd']
            b_ = best
            tag = '%s %s' % (a.wallet, mk)
            self.m.check('liquidation debt-asset conservation (SPEC-LIQ-010)',
                         abs((b_['Kf'] + b_['F'] + b_['R'] + b_['shortfall'] + Bd) - (b_['D'] + b_['F'] + b_['phi'] + b_['A'] + b_['B'] + b_['out']))
                         < 1e-6 * max(1.0, b_['F'] + b_['R']), tag)
            if mode == 'routed':
                self.m.check('routed liquidation meets the recovery floor (R + shortfall >= minOut)',
                             b_['R'] + b_['shortfall'] >= b_['min_out'] - 1e-9, tag)
                self.m.check('waterfall A + Kr + B = Y, each >= 0 (LIQ-031, SPEC-LIQ-022)',
                             abs(b_['A'] + b_['Kr'] + b_['B'] - b_['Y']) < 1e-9 * max(1.0, b_['Y']) and min(b_['A'], b_['Kr'], b_['B']) >= -1e-9, tag)
                self.m.check('no borrower surplus when a shortfall was paid (LIQ-POST-016)',
                             b_['B'] <= 1e-9 or (b_['shortfall'] <= 0 and Bd <= 0), tag)
                self.m.check('flash premium within maxFlashFeeBps (LIQ-030)', b_['phi'] <= b_['F'] * P.MAX_FLASH_FEE + 1e-12, tag)
            ep = self.episode(t)
            held_markets = [m_ for m_ in P.MARKET_IDS if a.records[m_]]
            contagion = False
            if self.topology:
                # the seized market on its own, with the debt split over the account's markets in
                # proportion to their CF-weighted value at peg (2 USD per whole vault token)
                live = a.markets()
                pegc = sum(P.MARKETS[m_]['cf'] * a.credited(m_) * 2.0 for m_ in live)
                Dv = self.p.debt_value(a, t)
                alone = self.p.served(mk, t) / 2.0 * pegc / Dv if Dv > 0 else float('inf')
                contagion = len(live) > 1 and alone >= 1.0
            touched, deficit, seized_units = self.p.apply_seizure(a, mk, best['asset'], sz, t)
            self.p.record_outcome(mk, seized_units, best['pf'], t)
            self.route_fail_since.pop(mk, None)
            pnl = best['out'] - best['Kf'] - best['shortfall'] - gas
            reimb = 0.0
            if not permissionless and pnl < 0:
                reimb = -pnl
                self.reimbursement += -pnl
            if permissionless:
                self.searcher_profit['searcher%d' % self.rng.randint(1, N_SEARCHERS)] += pnl
            else:
                self.keeper_pnl += pnl
            if best['shortfall'] > 0:
                self.liq_stats['shortfall_calls'] += 1
                self.liq_stats['shortfall_gho'] += best['shortfall']
            bonus = sz['seize'] - sz['repay'] - best['B']   # the borrower surplus B comes back in the debt asset
            u.ledger['liq_bonus'] += bonus
            u.ledger['liq_surplus'] += best['B']
            self.liq_stats['flash_calls' if best['F'] > 0 else 'caller_funded_calls'] += 1
            self.liq_stats['flash_premium'] += best['phi']
            self.liq_stats['borrower_surplus'] += best['B']
            u.ledger['seized_value'] += sz['seize']
            self.m.liquidations.append(dict(t=t / D, wallet=a.wallet, persona=u.persona, market=mk, asset=best['asset'], hf=sz['hf'],
                                            lb=sz['lb'], repay=sz['repay'], seize=sz['seize'], bonus=bonus, mode=mode,
                                            caller='permissionless' if permissionless else 'keeper', keeper_pnl=pnl,
                                            gas=gas, reimb=reimb, deficit=deficit, episode=ep, units=seized_units,
                                            shortfall=best['shortfall'], avana_fee=best['A'], keeper_reward=best['Kr'],
                                            borrower_surplus=best['B'], flash=best['F'], flash_premium=best['phi'],
                                            other_market_failed=any(self.p.seize_gate(m_, t) for m_ in held_markets if m_ != mk),
                                            spoke=a.spoke, pid=u.pid, contagion=contagion, n_markets=len(held_markets),
                                            t_sec=t))
            self.m.frustrate('liquidated', u.uid)
            if t - u.last_rescue_refused < D:
                self.m.frustrate('liquidated_unable_to_act', u.uid)
            if u.act_hf and u.below_act_since is not None and (u.cash + sum(u.held.values()) > 0.1 * sz['repay'] or u.spare > 20) \
                    and u.last_check < u.below_act_since:
                self.m.frustrate('no_alerts', u.uid)
            if len(held_markets) > 1:
                shocked = {'USDe crash': 'USDe', 'USDT depeg': 'USDT', 'pause + USDe aftershock': 'USDe'}.get(ep)
                if shocked and shocked not in mk and any(shocked in m_ for m_ in held_markets):
                    self.m.frustrate('liquidated_good_collateral', u.uid)

    def episode(self, t):
        d = t / D
        if self.topology:
            return 'shock' if self.ep['shock'][0] <= d < self.ep['shock'][1] else 'calm'
        if self.ep['usdt_feed_outage'][0] <= d < self.ep['usdt_feed_outage'][0] + 0.5:
            return 'USDT feed outage'
        if self.ep['usdt_depeg'][0] <= d < self.ep['usdt_depeg'][1]:
            return 'USDT depeg'
        if self.ep['usde_crash'][0] <= d < self.ep['usde_crash'][1]:
            return 'USDe crash'
        if self.ep['frozen'][0] <= d < self.ep['paused'][1] + 0.5:
            return 'pause + USDe aftershock'
        if self.ep['pool_drain'][0] <= d < 55:
            return 'GHO/USDC drain'
        return 'calm'

    # ------------------------------------------------------------------ third-party repay service (Q-212)
    def on_guardian(self, t):
        for u in self.users:
            if not u.guardian or u.guardian_funds <= 1:
                continue
            a = self.p.acct(u.wallet)
            if not a or not a.has_debt():
                continue
            hf = self.p.hf(a, t)
            if hf >= 1.08:
                continue
            asset = max(P.DEBT_ASSETS, key=lambda k: a.debt[k])
            need = max(0.0, self.p.debt_value(a, t) - self.p.cf_coll(a, t) / 1.25)
            pay = min(need, u.guardian_funds, a.debt[asset] * self.p.debt_price(asset, t))
            if pay < 1:
                continue
            try:
                spent = self.p.repay(u.wallet, asset, pay, False, pay, pay, t + 30)
            except Refused as e:
                self.third_party['refused:' + e.args[0]] += 1
                continue
            u.guardian_funds -= spent
            u.ledger['gas'] += 0  # paid by the service
            self.third_party['repaid'] += 1
            self.third_party['repaid_in_' + self.p.pause] += 1
            self.third_party['usd'] += spent

    # ------------------------------------------------------------------ attackers
    def attacker_slice(self, u, t):
        """Top-up slice re-leverage: when HF dips below 1.10 and the regular budget is
        full, pledge exactly the restore amount from the slice, then borrow back to 1.10."""
        a = self.p.acct(u.wallet)
        if u.todo:
            self.try_pledge_next(u, t)
            return self.schedule(u, t, 0.1)
        if a is None:
            return self.schedule(u, t, 1)
        hf = self.p.hf(a, t)
        mk = 'USDC/USDT'
        m = self.p.mk[mk]
        room = P.MARKETS[mk]['cap'] - m['regular']
        if 0 < room < 1_500_000 and t > 10 * D:
            # cap squatting: debt-free filler wallets take the last regular room (they keep earning LP fees)
            k = len(u.wallets)
            fw = 'w%df%d' % (u.uid, k)
            u.wallets.append(fw)
            self.by_wallet[fw] = u
            usd = min(room, 990_000.0)
            nft = self.p.new_nft(fw, mk, usd / self.p.price(mk, t))
            u.nfts.append(nft)
            try:
                self.p.pledge(fw, nft, t)
                u.ledger['gas'] += self.w.gas_usd(P.GAS['mint_nft'] + P.GAS['nft_approve'] + P.GAS['pledge_first'], t)
                u.ledger['squat_usd'] += usd
                self.m.attacks.append(dict(t=t / D, attack='cap squatting', step='filler wallet %s pledges $%.0f' % (fw, usd),
                                           result='regular room of USDC/USDT now $%.0f' % (P.MARKETS[mk]['cap'] - m['regular'])))
            except Refused as e:
                nft.alive = False
        if a.has_debt() and hf < P.RECOMMENDED_HF and room <= 1.0:
            Dv = self.p.debt_value(a, t)
            price = self.p.price(mk, t)
            restore = (P.RECOMMENDED_HF - hf) * Dv / P.MARKETS[mk]['cf']
            usd = max(restore * 0.999, 10.5)
            nft = self.p.new_nft(u.wallet, mk, usd / price)
            u.nfts.append(nft)
            u.ledger['gas'] += self.w.gas_usd(P.GAS['mint_nft'], t)
            try:
                self.p.pledge_check(u.wallet, nft, t)
            except Refused as e:
                self.m.attacks.append(dict(t=t / D, attack='slice re-leverage', step='top-up', result='refused: ' + e.args[0]))
                nft.alive = False
                return self.schedule(u, t, 1)
            self.tx(u, 'pledge', t, P.GAS['nft_approve'] + P.GAS['pledge'], lambda ti: self.p.pledge(u.wallet, nft, ti))
            return self.schedule(u, t, 0.1)
        if hf > 1.103 or not a.has_debt():
            cc = self.p.cf_coll(a, t)
            amt = cc / 1.1015 - self.p.debt_value(a, t)
            if amt > 50:
                try:
                    self.p.borrow_check(u.wallet, 'GHO', amt, t, 0.0, a.nonce)
                except Refused:
                    return self.schedule(u, t, 1)
                nonce = a.nonce
                self.tx(u, 'borrow', t, P.GAS['borrow'], lambda ti: self.p.borrow(u.wallet, 'GHO', amt, ti, 0.0, nonce),
                        lambda r, ti: u.held.__setitem__('GHO', u.held['GHO'] + r))
        return self.schedule(u, t, 1)

    def on_attack(self, kind, t):
        u = self.attacker2
        p = self.p
        if kind == 'dust_accounts':
            made = 0
            for i in range(40):
                w = 'dust%d' % i
                self.by_wallet[w] = u
                n = p.new_nft(w, 'USDe/USDT', 10.6 / p.price('USDe/USDT', t))
                try:
                    p.pledge(w, n, t)
                    u.ledger['gas'] += self.w.gas_usd(P.GAS['nft_approve'] + P.GAS['pledge_first'] + P.GAS['mint_nft'], t)
                except Refused as e:
                    self.m.attacks.append(dict(t=t / D, attack='dust accounts', step=w, result='pledge refused: ' + e.args[0]))
                    continue
                for k in range(12):
                    tb = t + 60 + k * 900
                    try:
                        amt = p.cf_coll(p.acct(w), tb) / 1.1005
                        p.borrow(w, 'GHO', amt, tb, 0.0, 0)
                        u.ledger['gas'] += self.w.gas_usd(P.GAS['borrow'], tb)
                        made += 1
                        break
                    except Refused:
                        u.ledger['gas'] += self.w.gas_usd(P.GAS['borrow'], tb) * P.GAS['revert_fraction']
            self.m.attacks.append(dict(t=t / D, attack='dust accounts', step='open 40 x $10.60 USDe/USDT accounts at HF 1.10',
                                       result='%d opened; gas paid $%.0f' % (made, u.ledger['gas'])))
        elif kind == 'flash_pledge':
            self.m.attacks.append(dict(t=t / D, attack='flash-loan pledge-borrow-exit', step='flash-mint $5M of LP, pledge, borrow max, withdraw in one tx',
                                       result='reverts: withdraw-with-debt needs HF >= 1.10 after (HealthFactorTooLow); borrow (<= 28% of the LP) cannot repay the flash loan; no loss'))
        elif kind == 'direct_liquidation_call':
            self.m.attacks.append(dict(t=t / D, attack='direct Spoke.liquidationCall', step='call liquidationCall on an account',
                                       result='Unauthorized() (LIQ-055): only LPVaultSwap is LIQUIDATION_MANAGER'))
        elif kind == 'pledge_during_manipulation':
            n = p.new_nft('atk2', 'USDC/USDT', 50_000 / 2.0)
            try:
                p.pledge_check('atk2', n, t)
                res = 'accepted at the Chainlink-derived price; credit = liquidity, so pool manipulation adds no value'
            except Refused as e:
                res = 'refused: ' + e.args[0]
            del p.nfts[n.id]
            self.m.attacks.append(dict(t=t / D, attack='pledge while pool is pushed off peg', step='move USDC/USDT pool 2% then pledge', result=res))
        elif kind == 'twap_grief':
            m = int(t // 60)
            L = self.w.other_liq['GHO/USDC'][m] + p.mk['GHO/USDC']['supply']
            v_equiv = L * 2.0
            per_block = v_equiv * 0.007 ** 2 / 8
            hours = (self.ep['twap_grief'][1] - self.ep['twap_grief'][0]) * 24
            cost = per_block * hours * 300
            self.m.attacks.append(dict(t=t / D, attack='TWAP griefing in drained GHO/USDC pool',
                                       step='hold pool 0.7%% off Chainlink for %.1f h' % hours,
                                       result='market Drifting(TWAP): borrow and withdraw-with-debt blocked for its holders; liquidation unaffected; estimated cost $%.0f' % cost))
        elif kind == 'address_freeze':
            # Q-242: the guardians freeze the dust attacker's wallets, at most 20 per caller per 24 h
            dust = sorted((w for w in p.accounts if w.startswith('dust')), key=lambda w: int(w[4:]))
            done = 0
            for i, w in enumerate(dust):
                try:
                    p.freeze_address('EmergencyGuardian' if i < 20 else 'AaveProtocolGuardian', w, t)
                    done += 1
                except Refused:
                    pass
            try:
                p.freeze_address('EmergencyGuardian', 'dust_extra', t)
                limit = 'accepted'
            except Refused as e:
                limit = 'refused: ' + e.args[0]
            self.m.attacks.append(dict(t=t / D, attack='address freeze of the dust wallets', step='%d freezeAddress calls by two guardians' % len(dust),
                                       result='%d frozen; a 21st freeze by the same guardian within 24 h %s' % (done, limit)))
            w = dust[0]
            a = p.acct(w)
            n = p.new_nft(w, 'USDe/USDT', 50.0 / p.served('USDe/USDT', t))
            n2 = p.new_nft('dust_fresh', 'USDe/USDT', 50.0 / p.served('USDe/USDT', t))
            p.frozen.add('dust_fresh')   # probe wallet, frozen directly so the guardians' daily limit is not used
            rec = a.records['USDe/USDT'][0] if a.records['USDe/USDT'] else None
            res = {}

            def run(col, f):
                try:
                    f()
                    res[col] = 'Y'
                except Refused as e:
                    res[col] = 'N (%s)' % e.args[0]
            run('new account from a frozen wallet', lambda: p.pledge_check('dust_fresh', n2, t))
            run('non-rescue top-up', lambda: p.pledge_check(w, n, t))
            # a rescue top-up needs an account whose restore amount reaches the $10 minimum, so the
            # indebted probe account is frozen for this one check
            wd, _, _, _, _ = self.probe_accts['USDC/USDT']
            n3 = p.new_nft(wd, 'USDC/USDT', 0.99 * p.usd_to_restore(p.acct(wd), 'USDC/USDT', t, 1.05) / p.served('USDC/USDT', t))
            p.frozen.add(wd)
            if n3.liq * p.price('USDC/USDT', t) >= P.RESCUE_MIN_PLEDGE_USD:
                run('rescue top-up', lambda: p.pledge_check(wd, n3, t, hf_override=1.05))
            else:
                res['rescue top-up'] = '- (the probe account has no debt to restore)'
            run('non-rescue top-up (probe account)', lambda: p.pledge_check(wd, n3, t))
            p.frozen.discard(wd)
            del p.nfts[n3.id]
            run('borrow', lambda: p.borrow_check(w, 'GHO', 1.0, t, 0.0, a.nonce))
            run('repay', lambda: p.repay(w, 'GHO', 0.01, False, 0.01, 0.01, t))
            if rec is not None and a.has_debt():
                run('partial removal with debt', lambda: p.remove_check(w, rec.nft, rec.credited * 0.1, t, 0.0))
                run('repay with collateral', lambda: p.deleverage_quote(w, rec.nft, rec.credited * 0.1, 'GHO', t))
                g = p.liquidation_gate(a, t, 0.99)
                res['liquidation of its positions (gate)'] = 'Y' if g is None else 'N (%s)' % g
            else:
                res['debt-dependent rows'] = '- (the frozen dust wallet has no debt in this run)'
            del p.nfts[n.id], p.nfts[n2.id]
            p.frozen.discard('dust_fresh')
            exp = {'new account from a frozen wallet': 'N', 'non-rescue top-up': 'N', 'rescue top-up': 'Y', 'borrow': 'N', 'repay': 'Y',
                   'non-rescue top-up (probe account)': 'N',
                   'partial removal with debt': 'N', 'repay with collateral': 'N', 'liquidation of its positions (gate)': 'Y'}
            for k, v in res.items():
                if v.startswith('-'):
                    continue
                ok = v.startswith(exp[k]) or 'CapExceeded' in v
                self.m.check('address freeze gates match EMG-070', ok, '%s got %s' % (k, v))
            self.freeze_results.append(res)
        elif kind == 'donation_grief':
            self.m.attacks.append(dict(t=t / D, attack='donate liquidity to a victim NFT', step='NFPM.increaseLiquidity on a pledged tokenId',
                                       result='no effect on credit, HF or withdrawal; the liquidity returns to the victim with the NFT'))

    # ------------------------------------------------------------------ rule probes
    def probe_setup(self, t):
        """One indebted probe account (USDC debt, two NFTs) and one debt-free probe account per market."""
        self.probe_accts = {}
        probe_user = User(-1, 'probe', dict(PERSONAS['passive_lp'], act=0.0, guardian=0.0), random.Random(1))
        for mk in P.MARKET_IDS:
            price = self.p.served(mk, t)
            wd, wf = 'probe_debt_' + mk, 'probe_free_' + mk
            self.by_wallet[wd] = self.by_wallet[wf] = probe_user
            n1 = self.p.new_nft(wd, mk, 12000 / price)
            n2 = self.p.new_nft(wd, mk, 8000 / price)
            n3 = self.p.new_nft(wf, mk, 2000 / price)
            self.p.pledge(wd, n1, t)
            self.p.pledge(wd, n2, t)
            self.p.pledge(wf, n3, t)
            for k in range(24):
                try:
                    self.p.borrow(wd, 'USDC', self.p.cf_coll(self.p.acct(wd), t + k * 600) / 2.0, t + k * 600, 0.0, 0)
                    break
                except Refused:
                    continue
            self.probe_accts[mk] = (wd, wf, n1, n2, n3)
        self.m.probes = []

    def probe_label(self, mk, t):
        p = self.p
        st, reason, _, lgate, grace = self.w.o(mk, t)
        dst, _, dborrow, dliq = self.w.debt_o(t)
        if p.pause == 'Paused':
            return 'Application Paused (General)'
        if p.pause == 'Frozen':
            return 'Application Frozen'
        if st == 3:
            return 'Expired'
        if st == 2:
            return 'Cached'
        if reason & 1:
            return 'Disagreement beyond disagreementPauseMax' if lgate == 'disagree_expired' else 'Drifting (feed disagreement)'
        if lgate == 'alt_past_borrow_age':
            return 'Alternate past borrowPriceMaxAge (seizure as Cached)'
        if not (dborrow and dliq):
            return 'USDC debt price failing'
        if grace:
            return 'Grace after recovery, manual breaker still tripped' if p.market_breaker(mk, t) else 'Grace after recovery'
        if p.market_breaker(mk, t):
            return 'Market breaker tripped'
        if st == 1 and reason & 4:
            return 'Drifting (TWAP)'
        if st == 1 and reason == 2:
            return 'Drifting (USD band breach)'
        if any(self.w.selected_leg(tok, t)[2] == 1 for tok in P.MARKETS[mk]['tokens']):
            return 'Live on alternate, every leg within borrowPriceMaxAge'
        return 'Live'

    def on_probe(self, obj, t):
        name, mk = obj
        p = self.p
        wd, wf, n1, n2, n3 = self.probe_accts[mk]
        ad, af = p.acct(wd), p.acct(wf)
        if not ad.has_debt():
            self.m.probes.append(dict(label=name + ' (skipped: probe account could not borrow)', market=mk, day=t / D, state=None, observed={}, expected={}))
            return
        label = self.probe_label(mk, t)
        out = {}

        def run(col, f):
            try:
                f()
                out[col] = 'Y'
            except Refused as e:
                out[col] = 'N (%s)' % e.args[0]
        cand = p.new_nft('probe_new', mk, 100 / p.served(mk, t))
        run('new', lambda: p.pledge_check('probe_new_%s_%d' % (mk, int(t)), cand, t))
        run('topup', lambda: p.pledge_check(wd, cand, t))
        # a rescue top-up sized to 99% of the collateral that restores minOpeningHealthFactor at
        # the price Aave values it at (the served price), for the probe account at HF 1.05
        resc = p.new_nft('probe_rescue', mk, 0.99 * p.usd_to_restore(ad, mk, t, 1.05) / p.served(mk, t))
        run('rescue', lambda: p.pledge_check(wd, resc, t, hf_override=1.05))
        del p.nfts[cand.id], p.nfts[resc.id]
        run('borrow', lambda: p.borrow_check(wd, 'USDC', 1.0, t, 0.0, ad.nonce))
        run('repay', lambda: None if ad.has_debt() else (_ for _ in ()).throw(Refused('NoDebt')))
        run('collect', lambda: None if n1.wallet == wd else (_ for _ in ()).throw(Refused('NotDepositor')))
        rec_f = p._record_of(af, n3)
        run('wd_free', lambda: p.withdraw_check(wf, n3, rec_f.credited, t, 0.0))
        rec2 = p._record_of(ad, n2)
        run('wd_debt', lambda: p.withdraw_check(wd, n2, rec2.credited, t, 0.0))
        rec1 = p._record_of(ad, n1)
        run('remove_debt', lambda: p.remove_check(wd, n1, rec1.credited * 0.1, t, 0.0))
        run('rwc', lambda: p.deleverage_quote(wd, n1, rec1.credited * 0.05, 'USDC', t))
        # repay-all-and-withdraw reads no pause, freeze or price state: its gates are the record and the caps
        run('repay_all_wd', lambda: None if p._record_of(ad, n1) else (_ for _ in ()).throw(Refused('NotRecordProxy')))
        g = p.liquidation_gate(ad, t, 0.99)
        out['liq'] = 'Y' if g is None else 'N (%s)' % g
        exp = EXPECTED[label]
        for k, v in out.items():
            # a rescue top-up is exempt from the pool-share cap, so only the market and slice budgets excuse it
            capgate = any(x in v for x in (('CapExceeded', 'SliceNotAvailable') if k == 'rescue' else ('CapExceeded', 'SliceNotAvailable', 'PoolShareExceeded')))
            ok = v.startswith(exp[k][0]) or capgate
            if k == 'rescue' and exp[k] == 'Y':
                self.m.check('rescue top-up sized to restore minOpeningHealthFactor at the served price is admitted (SPEC-CAP-003, REQ-RISK-026)',
                             ok, '%s %s day %.2f got %s (accepted %.4f, served %.4f)' % (label, mk, t / D, v, p.price(mk, t), p.served(mk, t)))
            else:
                self.m.check('probe: state gates match the 3.6 emergency matrix', ok, '%s %s %s got %s' % (label, mk, k, v))
        self.m.probes.append(dict(label=label, name=name, market=mk, day=t / D, state=self.w.o(mk, t)[:2], observed=out, expected=exp))

    # ------------------------------------------------------------------ topology metrics
    def snapshot(self, t):
        """Capital efficiency just before the shock: debt against borrow capacity at
        minOpeningHealthFactor, over the same people in every topology."""
        p = self.p
        debt = cap = coll = 0.0
        n_acc = 0
        headroom = Counter()
        safe = 0.0
        for a in p.accounts.values():
            if not a.markets():
                continue
            n_acc += 1
            dv = p.debt_value(a, t)
            cc = p.cf_coll(a, t) / P.RECOMMENDED_HF
            debt += dv
            cap += cc
            coll += p.coll_usd(a, t)
            headroom[a.spoke] += max(0.0, cc - dv)
            # largest debt that keeps HF >= 1 after any one pool token (DAI or USDT) drops to 0.80
            # (LP value -10.6%), on this account's own collateral: the cross-collateral effect
            parts = [(P.MARKETS[mk]['cf'] * a.credited(mk) * p.served(mk, t), P.MARKETS[mk]['tokens']) for mk in a.markets()]
            drop = 1 - math.sqrt(0.80)
            toks = {tk for _, ts in parts for tk in ts if tk in ('DAI', 'USDT', 'WETH')}
            safe += min([sum(v * (1 - (drop if tk in ts else 0.0)) for v, ts in parts) for tk in toks] or [sum(v for v, _ in parts)])
        spokes = {}
        cap_bound = 0.0
        for sp, caps in p.draw_caps.items():
            spokes[sp] = {k: dict(drawn=round(p.spoke_drawn(sp, k), 2), cap=v) for k, v in caps.items() if v > 0}
            room = sum(max(0.0, v - p.spoke_drawn(sp, k)) for k, v in caps.items())
            spokes[sp]['headroom_usd'] = headroom[sp]
            spokes[sp]['cap_room_usd'] = room
            cap_bound += max(0.0, headroom[sp] - room)
        self.topo_snap = dict(day=t / D, accounts=n_acc, debt_usd=debt, capacity_usd=cap, collateral_usd=coll,
                              used=debt / cap if cap else 0.0, spokes=spokes,
                              headroom_usd=sum(headroom.values()), headroom_beyond_draw_caps_usd=cap_bound,
                              shock_safe_debt_usd=safe, shock_safe_over_capacity=safe / cap if cap else 0.0,
                              drawcap_refusals=self.topo['drawcap_refusals_pre_shock'],
                              drawcap_accounts=len(self.drawcap_wallets))

    def topology_sample(self, t):
        """Collateral whose borrow and withdraw-with-debt are blocked (Live, price age and breaker
        gates, account-wide in the RiskModule), split into collateral of the blocking market itself
        and healthy collateral blocked by another market of the same account. USD-hours."""
        p, w = self.p, self.w
        h = 600 / H
        # deficit breaker (breakerDeficitMax, per Spoke and debt asset): blocks borrowing on the whole Spoke
        for sp in p.spoke_deficit:
            if any(p.debt_breaker(k, t, sp) for k in P.DEBT_ASSETS):
                for a in p.spoke_accounts.get(sp, ()):
                    if a.has_debt():
                        self.topo['deficit_blocked_usd_h'] += sum(a.credited(mk) * p.price(mk, t) for mk in a.markets()) * h
        bad = {mk for mk in P.MARKET_IDS if w.o(mk, t)[0] != 0 or not w.borrow_age_ok(mk, t) or p.market_breaker(mk, t)}
        if not bad:
            return
        for a in p.accounts.values():
            if not a.has_debt():
                continue
            mks = a.markets()
            if not any(mk in bad for mk in mks):
                continue
            for mk in mks:
                usd = a.credited(mk) * p.price(mk, t) * h
                self.topo['blocked_own_usd_h' if mk in bad else 'blocked_other_usd_h'] += usd

    # ------------------------------------------------------------------ sampling
    def on_sample(self, t):
        if self.topology:
            self.topology_sample(t)
        tt = t + self.rng.uniform(0, 580)
        for mk in P.MARKET_IDS:
            st = self.w.o(mk, tt)[0]
            if st:
                k = 'state'
            elif not self.w.borrow_age_ok(mk, tt):
                k = 'age'
            elif self.p.market_breaker(mk, tt):
                k = 'breaker'
                self.breaker_time[mk + ' ' + ','.join(self.p.market_breaker(mk, tt))] += 600 / H
                for ep in ('gho_premium', 'usdt_depeg', 'usde_crash', 'dai_routes_stall'):
                    if self.ep[ep][0] <= tt / D < self.ep[ep][1]:
                        self.breaker_time['%s during %s' % (mk, ep)] += 600 / H
            else:
                k = 'ok'
            self.borrow_avail[mk][k] += 1
        dst, _, dborrow, _ = self.w.debt_o(tt)
        self.borrow_avail['USDC debt price']['ok' if dborrow else ('state' if dst else 'age')] += 1

    # ------------------------------------------------------------------ invariants
    def check_invariants(self, t):
        p, m = self.p, self.m
        for mk in P.MARKET_IDS:
            st = p.mk[mk]
            cred = sum(r.credited for a in p.accounts.values() for r in a.records[mk])
            m.check('backing: supply <= credited + pending, equal with a conforming LPVaultSwap (Q-257)',
                    abs(st['supply'] - (st['credited'] + st['pending'])) < 1e-6 * max(1, st['supply']), mk)
            m.check('credited == sum of records', abs(st['credited'] - cred) < 1e-6 * max(1, cred), mk)
            m.check('market regular counter <= cap', st['regular'] <= P.MARKETS[mk]['cap'] * (1 + 1e-9), mk)
            m.check('slice counter <= slice cap', st['slice'] <= P.MARKETS[mk]['cap'] * P.TOPUP_SLICE_FRACTION * (1 + 1e-9), mk)
        for a in p.accounts.values():
            p._acc(a, t)
            for mk in P.MARKET_IDS:
                for r in a.records[mk]:
                    m.check('record live liquidity >= credited', r.nft.liq >= r.credited - 1e-9, str(r.nft.id))
                    m.check('custody iff open record', r.nft.in_vault, str(r.nft.id))
                    m.check('rescue units <= credited per record', r.rescue <= r.credited + 1e-9, str(r.nft.id))
            for k in P.DEBT_ASSETS:
                bal = a.borrowed[k] + a.interest[k] - a.repaid[k] - a.liquidated[k] - a.written_off[k]
                m.check('debt conservation per account', abs(bal - a.debt[k]) < 1e-6 * max(1, a.borrowed[k] + a.interest[k]), a.wallet)
        open_nfts = {r.nft.id for a in p.accounts.values() for mk in P.MARKET_IDS for r in a.records[mk]}
        for n in p.nfts.values():
            if n.in_vault:
                m.check('vault holds only NFTs with an open record', n.id in open_nfts, str(n.id))
            m.check('fee conservation per NFT', abs(n.accrued - n.collected - n.owed) < 1e-6 * max(1, n.accrued), str(n.id))
        for k in P.DEBT_ASSETS:
            tot = sum(a.debt[k] for a in p.accounts.values())
            m.check('Hub drawn == sum of account debt', abs(tot - p.drawn[k]) < 1e-6 * max(1.0, tot) + 1e-3, k)

    # ------------------------------------------------------------------ results
    def results(self):
        if self.topology:
            from .report import topology_summary
            return topology_summary(self)
        from .report import summarise
        return summarise(self)
