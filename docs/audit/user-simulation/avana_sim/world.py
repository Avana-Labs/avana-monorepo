"""The outside world: token prices, Chainlink rounds, Uniswap pools, gas and
settlement-route depth, plus the LPOracle state of every market derived from
them by the rules of 2.10 (Live / Drifting / Cached / Expired, disagreement
pause, grace latch, USD band, TWAP guard, stable ceiling).

Everything is precomputed on a one-minute grid from a seeded RNG, so a run is
reproducible from (seed, feed profile).
"""
import bisect
import math
import random

from . import params as P

TOKENS = ('USDC', 'USDT', 'DAI', 'GHO', 'USDe')
LN_TICK = math.log(1.0001)

# Scenario timeline (days). Each episode is listed in the report.
EP = dict(
    gho_premium=(8.0, 10.0),          # GHO trades at a premium (USD band upper edge)
    usdt_feed_outage=(18.5, 19.6),    # both USDT routes stop updating for ~26 hours
    usdt_depeg=(30.0, 36.0),          # USDT 1.00 -> 0.92 in 6h, back to 0.995 by day 36
    usdt_disagree=(30.05, 30.10),     # USDT alternate route lags 75 minutes behind the primary
    pool_drain=(45.0, 47.0),          # GHO/USDC pool: other LPs withdraw 85% over 2 days
    twap_grief=(47.0, 47.1),          # attacker holds the drained GHO/USDC pool 0.7% off for 2.4 h
    usde_crash=(60.0, 70.0),          # USDe 1.00 -> 0.50 in 8h, 0.70 by day 70
    usde_disagree=(60.20, 60.25),     # USDe routes disagree for 72 minutes
    usde_routes_stressed=(60.0, 62.5),
    frozen=(75.0, 75.25),             # Emergency Guardian freeze
    paused=(75.25, 77.25),            # then pause for 48 hours
    usdc_primary_stall=(85.0, 85.1667),  # USDC/USD primary stops for 4 hours (alternate fresh)
    dai_routes_stall=(52.0, 53.25),   # every DAI route, the standby included, stops for 30 hours
)


# Topology scenarios (design review): a calm path with one shock from SHOCK_DAY. Every base
# episode above is moved out of the run (NEVER), so only the scenario's shock acts.
SHOCK_DAY = 25.0
NEVER = (1e6, 1e6)
SCENARIOS = {
    'calm': dict(),                                          # control: no shock
    'dai-depeg': dict(depeg={'DAI': 0.92}),                  # DAI 1.00 -> 0.92 in 6 h, held 1 day, back by day +4
    'usdt-depeg': dict(depeg={'USDT': 0.95}),                # USDT 1.00 -> 0.95, same shape
    'pool-crunch': dict(crunch='DAI/USDC'),                  # DAI/USDC pool: other LPs and exit depth -80%
    'two-pool': dict(depeg={'DAI': 0.92, 'USDT': 0.95}),     # both depegs at once (DAI/USDC and the USDC/USDT pools)
    'oracle-stale': dict(stale='DAI', stale_hours=8.0, drift={'DAI': 0.96}),  # every DAI route stops 8 h while DAI drifts to 0.96
    'dai-crash': dict(crash={'DAI': (0.50, 8.0, 0.70)}),     # tail sensitivity: DAI -> 0.50 in 8 h, 0.70 by day +6
    'dai-failure': dict(crash={'DAI': (0.05, 1.0, 0.05)}),   # tail sensitivity: DAI fails, 0.05 in 1 h, no recovery
    'eth-crash': dict(eth_drop=0.40),                        # WETH -40% in 3 h, -30% by day +6 (T3's own risk)
}


def scenario_ep(name):
    ep = {k: NEVER for k in EP}
    ep['shock'] = (SHOCK_DAY, SHOCK_DAY + 5.0)
    sc = SCENARIOS[name]
    if 'stale' in sc:
        ep['stale'] = (SHOCK_DAY, SHOCK_DAY + sc['stale_hours'] / 24.0)
    if 'crunch' in sc:
        ep['crunch'] = (SHOCK_DAY, SHOCK_DAY + 5.0)
    return ep


def _lin(t, t0, t1, a, b):
    if t <= t0:
        return a
    if t >= t1:
        return b
    return a + (b - a) * (t - t0) / (t1 - t0)


class Feed:
    """Chainlink push feed: a round lands when the deviation threshold or the
    heartbeat triggers, after a publication delay."""

    def __init__(self, name, dev, heartbeat):
        self.name, self.dev, self.hb = name, dev, heartbeat
        self.ts, self.vals = [], []

    def at(self, t):
        i = bisect.bisect_right(self.ts, t) - 1
        if i < 0:
            return self.vals[0], -10 ** 9
        return self.vals[i], self.ts[i]

    def series(self, n_min):
        """(values, updatedAts) of the latest round at the start of every minute, computed once."""
        if getattr(self, '_ser', None) is None:
            vs, us = [], []
            i, n = -1, len(self.ts)
            for m in range(n_min):
                t = m * 60.0
                while i + 1 < n and self.ts[i + 1] <= t:
                    i += 1
                if i < 0:
                    vs.append(self.vals[0]); us.append(-10 ** 9)
                else:
                    vs.append(self.vals[i]); us.append(self.ts[i])
            self._ser = (vs, us)
        return self._ser


class World:
    def __init__(self, seed, days=90, profile='spec', scenario=None):
        self.rng = random.Random(seed * 7919 + 13)
        self.days, self.profile, self.seed = days, profile, seed
        self.scenario = scenario
        self.sc = SCENARIOS[scenario] if scenario else {}
        self.ep = scenario_ep(scenario) if scenario else EP
        # base: the path never depends on the run length; a scenario run is built for its own length
        self.n_min = int(days * 1440) + 1 if scenario else int(max(days, 90) * 1440) + 1
        # WETH only when a market uses it, drawn from its own RNG so the stable path is unchanged
        self.tokens = TOKENS + (('WETH',) if any('WETH' in c['tokens'] for c in P.MARKETS.values()) else ())
        self._prices()
        self._gas()
        self._feeds()
        self._pools()
        self._oracle()

    # ------------------------------------------------------------ true prices
    def _prices(self):
        rng = self.rng
        sig = {'USDC': 0.00012, 'USDT': 0.00018, 'DAI': 0.00015, 'GHO': 0.0006, 'USDe': 0.0004}
        self.px = {}
        for tok in TOKENS:
            x, arr = 0.0, []
            for m in range(self.n_min):
                x += -0.02 * x + rng.gauss(0, sig[tok]) * 0.25
                d = m / 1440.0
                arr.append(1.0 + x + self._episode(tok, d))
            self.px[tok] = arr
        if 'WETH' in self.tokens:
            rv = random.Random(self.seed * 31337 + 5)
            s = P.WETH_DAILY_VOL / math.sqrt(1440)
            x, arr = 0.0, []
            for m in range(self.n_min):
                x += rv.gauss(0, s)
                arr.append(math.exp(x) * (1.0 + self._weth_episode(m / 1440.0)))
            self.px['WETH'] = arr

    def _weth_episode(self, d):
        drop = self.sc.get('eth_drop')
        if not drop:
            return 0.0
        a = SHOCK_DAY
        if d < a:
            return 0.0
        if d < a + 0.125:
            return _lin(d, a, a + 0.125, 0, -drop)
        if d < a + 2:
            return -drop
        return _lin(d, a + 2, a + 6, -drop, -0.75 * drop)

    def _scenario_episode(self, tok, d):
        sc, a = self.sc, SHOCK_DAY
        if tok in sc.get('crash', {}):
            low, hours, rec = sc['crash'][tok]
            if d < a:
                return 0.0
            if d < a + hours / 24.0:
                return (low - 1.0) * ((d - a) / (hours / 24.0)) ** 0.7
            if d < a + 2:
                return low - 1.0
            return _lin(d, a + 2, a + 6, low - 1.0, rec - 1.0)
        if tok in sc.get('depeg', {}):
            dev = sc['depeg'][tok] - 1.0
            if d < a:
                return 0.0
            if d < a + 0.25:
                return _lin(d, a, a + 0.25, 0, dev)
            if d < a + 1.25:
                return dev
            if d < a + 4:
                return _lin(d, a + 1.25, a + 4, dev, -0.005)
            return _lin(d, a + 4, a + 5, -0.005, 0)
        if tok in sc.get('drift', {}):
            dev = sc['drift'][tok] - 1.0
            b = self.ep['stale'][1]
            if d < a:
                return 0.0
            if d < b:
                return _lin(d, a, b, 0, dev)
            if d < a + 3:
                return _lin(d, b, a + 3, dev, -0.005)
            return _lin(d, a + 3, a + 4, -0.005, 0)
        return 0.0

    def _episode(self, tok, d):
        if self.scenario:
            return self._scenario_episode(tok, d)
        e = EP
        if tok == 'GHO':
            a, b = e['gho_premium']
            if a <= d < b:
                return _lin(d, a, a + 4 / 24, 0, 0.047) if d < a + 1 else _lin(d, b - 4 / 24, b, 0.047, 0)
            a, b = e['pool_drain']
            if a + 0.5 <= d < 55:
                return _lin(d, a + 0.5, a + 1.5, 0, -0.015) if d < 50 else _lin(d, 50, 55, -0.015, -0.002)
        if tok == 'USDT':
            a, b = e['usdt_feed_outage']
            if a <= d < b + 0.5:
                return _lin(d, a, a + 0.5, 0, -0.015) if d < b else _lin(d, b, b + 0.5, -0.015, -0.003)
            a, b = e['usdt_depeg']
            if a <= d < b:
                if d < a + 0.25:
                    return _lin(d, a, a + 0.25, 0, -0.08)
                if d < a + 1:
                    return -0.08
                return _lin(d, a + 1, b, -0.08, -0.005)
            a, b = e['paused']
            if a + 0.05 <= d < b:
                return _lin(d, a + 0.05, a + 0.6, 0, -0.015) if d < a + 0.6 else _lin(d, a + 0.6, b, -0.015, 0)
        if tok == 'DAI':
            a, b = e['dai_routes_stall']
            if a <= d < b + 0.5:
                return _lin(d, a, a + 0.5, 0, -0.006) if d < b else _lin(d, b, b + 0.5, -0.006, -0.001)
        if tok == 'USDe':
            a, b = e['usde_crash']
            if a <= d < 90:
                if d < a + 8 / 24:
                    k = (d - a) / (8 / 24)
                    return -0.5 * (k ** 0.7)
                if d < 63:
                    return -0.5 + 0.03 * math.sin(d * 9)
                if d < b:
                    return _lin(d, 63, b, -0.47, -0.30)
                a2, b2 = e['paused']
                if a2 + 0.05 <= d < a2 + 1.3:
                    return _lin(d, a2 + 0.05, a2 + 1.3, -0.30, -0.55)
                if d >= a2 + 1.3:
                    return _lin(d, a2 + 1.3, 90, -0.55, -0.45)
                return -0.30
        return 0.0

    def price(self, tok, t):
        return self.px[tok][min(int(t // 60), self.n_min - 1)]

    # ------------------------------------------------------------ gas
    def _gas(self):
        rng, G = self.rng, P.GAS_PRICE
        g = []
        for m in range(self.n_min):
            d = m / 1440.0
            base = G['base_lo'] + (G['base_hi'] - G['base_lo']) * math.sin(2 * math.pi * (d % 1)) ** 2
            base *= math.exp(rng.gauss(0, G['noise_sigma']))
            if self.scenario:
                if SHOCK_DAY <= d < SHOCK_DAY + 0.5:
                    base = max(base, G['scenario_shock_eth_drop'] if self.sc.get('eth_drop') else G['scenario_shock'])
                g.append(base)
                continue
            if 30.0 <= d < 30.5:
                base = max(base, G['usdt_depeg'])
            if 60.0 <= d < 60.5:
                base = max(base, G['usde_crash_peak'])
            elif 60.5 <= d < 61.0:
                base = max(base, G['usde_crash_tail'])
            if 75.25 <= d < 75.5:
                base = max(base, G['late_spike'])
            g.append(base)
        self.gas_gwei = g

    def gas_usd(self, units, t):
        return units * self.gas_gwei[min(int(t // 60), self.n_min - 1)] * 1e-9 * P.ETH_USD

    def congested(self, t):
        return self.gas_gwei[min(int(t // 60), self.n_min - 1)] > P.GAS_CONGESTION_GWEI

    # ------------------------------------------------------------ feeds
    def _feeds(self):
        prof = P.FEED_PROFILES[self.profile]
        self.primary, self.alt, self.standby = {}, {}, {}
        for tok in TOKENS:
            dev, hb = prof[tok]
            self.primary[tok] = self._make_feed(tok, 'primary', dev, hb)
            self.alt[tok] = self._make_feed(tok, 'alt', P.ALT_FEED[0], P.ALT_FEED[1])
        # Standby routes use their own RNG so the primary and alternate rounds, and every
        # path drawn after them, are the same as in a run without standby routes.
        rng_sb = random.Random(self.seed * 104729 + 7)
        for tok in TOKENS:
            self.standby[tok] = self._make_feed(tok, 'standby', P.STANDBY_FEED[0], P.STANDBY_FEED[1], rng_sb)
        if 'WETH' in self.tokens:
            rv = random.Random(self.seed * 31337 + 11)
            self.primary['WETH'] = self._make_feed('WETH', 'primary', P.WETH_FEED[0], P.WETH_FEED[1], rv)
            self.alt['WETH'] = self._make_feed('WETH', 'alt', P.ALT_FEED[0], P.ALT_FEED[1], rv)
            self.standby['WETH'] = self._make_feed('WETH', 'standby', P.WETH_FEED[0], P.WETH_FEED[1], rv)
        # Listing check of REQ-ORACLE-054: every primary (and standby) leg has a heartbeat of
        # at most 3,600 s; a token without such a primary route is not listed.
        self.listable = {tok: self.primary[tok].hb <= P.MAX_PRIMARY_HEARTBEAT and self.standby[tok].hb <= P.MAX_PRIMARY_HEARTBEAT
                         for tok in self.tokens}
        self._routes_in_force()
        self._token_legs()

    def _make_feed(self, tok, kind, dev, hb, rng=None):
        rng = rng or self.rng
        f = Feed(tok + '/' + kind, dev, hb)
        last_v, last_t = self.px[tok][0], -rng.uniform(0, hb * 0.9)
        f.ts.append(last_t)
        f.vals.append(last_v)
        pending = None
        for m in range(1, self.n_min):
            t = m * 60.0
            d = t / P.DAY
            if pending and pending[0] <= t:
                f.ts.append(pending[0])
                f.vals.append(pending[1])
                last_v, last_t = pending[1], pending[0]
                pending = None
            if pending:
                continue
            if self._outage(tok, kind, d):
                continue
            true = self.px[tok][m]
            lag = self._alt_lag(tok, d) if kind == 'alt' else 0
            if lag:
                true = self.px[tok][max(0, m - lag)]
            if abs(true - last_v) / last_v > dev or t - last_t >= hb:
                lo, hi = P.FEED_DELAY_CONGESTED if self.gas_gwei[m] > P.GAS_CONGESTION_GWEI else P.FEED_DELAY
                pending = (t + rng.uniform(lo, hi), true)
        return f

    def _outage(self, tok, kind, d):
        if self.scenario:
            a, b = self.ep.get('stale', NEVER)
            return tok == self.sc.get('stale') and a <= d < b
        a, b = EP['dai_routes_stall']
        if tok == 'DAI' and a <= d < b:
            return True
        if kind == 'standby':
            return False
        a, b = EP['usdt_feed_outage']
        if tok == 'USDT' and a <= d < b:
            return True
        a, b = EP['usdc_primary_stall']
        if tok == 'USDC' and kind == 'primary' and a <= d < b:
            return True
        return False

    def _alt_lag(self, tok, d):
        """Minutes the faulty alternate route lags behind the market (0 = healthy)."""
        if self.scenario:
            return 0
        a, b = EP['usdt_disagree']
        if tok == 'USDT' and a <= d < b:
            return 120
        a, b = EP['usde_disagree']
        if tok == 'USDe' and a <= d < b:
            return 75
        return 0

    @staticmethod
    def _fresh(feed, t):
        v, u = feed.at(t)
        return (t - u <= P.liq_max_age(feed.hb)), v, u

    def _routes_in_force(self):
        """Standby switches (Q-248, EMG-091, playbook P-02): monitoring pages when a primary
        leg reaches 90% of its feedMaxAge (M-03) or 30 minutes before a disagreement's
        pause ends (M-02); a guardian calls useStandbyRoute GUARDIAN_REACTION later if the
        standby is fresh and agrees with the healthy route. The listed route is restored
        by restorePriceRoute at the normal delay once it is healthy again."""
        self.slots = {}
        self.standby_events = []
        self.manual_trip_t = {}
        for tok in self.tokens:
            pf, af, sf = self.primary[tok], self.alt[tok], self.standby[tok]
            PV, PU = pf.series(self.n_min)
            AV, AU = af.series(self.n_min)
            SV, SU = sf.series(self.n_min)
            p_liq, a_liq, s_bor = P.liq_max_age(pf.hb), P.liq_max_age(af.hb), P.borrow_max_age(sf.hb)
            p_page = P.PAGE_AGE_FRACTION * p_liq
            tol = pf.dev + af.dev + P.AGREEMENT_MARGIN
            stol = sf.dev + af.dev + P.AGREEMENT_MARGIN
            prim_sched, alt_sched = [(0.0, pf)], [(0.0, af)]
            switched = None          # 'primary' / 'alt' while the standby fills that slot
            page_t = None
            disagree_since = None
            healthy_since = None
            for m in range(self.n_min):
                t = m * 60.0
                if switched is None:
                    pv, pu, av, au, sv, su = PV[m], PU[m], AV[m], AU[m], SV[m], SU[m]
                    fp = t - pu <= p_liq
                    fa = t - au <= a_liq
                    fs = t - su <= s_bor
                    dis = fp and fa and abs(pv - av) > tol * min(pv, av)
                    if dis:
                        disagree_since = t if disagree_since is None else disagree_since
                    else:
                        disagree_since = None
                    slot = None
                    if t - pu > max(p_page, pf.hb):   # paged (M-03) and confirmed past its heartbeat
                        page_t = t if page_t is None else page_t
                        if t >= page_t + P.GUARDIAN_REACTION and fs:
                            slot = 'primary'
                        elif t >= page_t + P.GUARDIAN_REACTION and not fs and page_t not in self.manual_trip_t.get(tok, {}):
                            # playbook P-02 step 3: the standby fails too, so a guardian trips the market breaker
                            self.manual_trip_t.setdefault(tok, {})[page_t] = t
                    else:
                        page_t = None
                        if dis and t >= disagree_since + P.DISAGREE_PAUSE_MAX - P.DISAGREEMENT_PAGE + P.GUARDIAN_REACTION and fs:
                            slot = 'alt' if abs(sv - pv) <= stol * min(sv, pv) else 'primary'
                    if slot:
                        switched = slot
                        (prim_sched if slot == 'primary' else alt_sched).append((t, sf))
                        self.standby_events.append((t / P.DAY, tok, slot, 'useStandbyRoute'))
                        healthy_since = None
                else:
                    if switched == 'primary':
                        ok = t - PU[m] <= p_liq
                    else:
                        ok = t - AU[m] <= a_liq and not self._alt_lag(tok, t / P.DAY)
                    if ok:
                        healthy_since = t if healthy_since is None else healthy_since
                        if t >= healthy_since + P.NORMAL_DELAY:
                            listed = pf if switched == 'primary' else af
                            (prim_sched if switched == 'primary' else alt_sched).append((t, listed))
                            self.standby_events.append((t / P.DAY, tok, switched, 'restorePriceRoute'))
                            switched, page_t, disagree_since = None, None, None
                    else:
                        healthy_since = None
            self.slots[tok] = (prim_sched, alt_sched)

    @staticmethod
    def _in_force(sched, t):
        f = sched[0][1]
        for t0, ff in sched:
            if t0 <= t:
                f = ff
            else:
                break
        return f

    def _token_legs(self):
        """Per token and minute: the route in use (REQ-ORACLE-005 failover), its value and
        timestamp, the leg's borrow and liquidation age limits, and the agreement check."""
        self.leg = {}
        for tok in self.tokens:
            prim_sched, alt_sched = self.slots[tok]
            rows = []
            pi = ai = 0
            for m in range(self.n_min):
                t = m * 60.0
                while pi + 1 < len(prim_sched) and prim_sched[pi + 1][0] <= t:
                    pi += 1
                while ai + 1 < len(alt_sched) and alt_sched[ai + 1][0] <= t:
                    ai += 1
                pf, af = prim_sched[pi][1], alt_sched[ai][1]
                PV, PU = pf.series(self.n_min)
                AV, AU = af.series(self.n_min)
                pv, pu, av, au = PV[m], PU[m], AV[m], AU[m]
                fp = t - pu <= pf.hb + P.FEED_MAX_AGE_PAD
                fa = t - au <= af.hb + P.FEED_MAX_AGE_PAD
                dis = False
                if fp and fa:
                    dis = abs(pv - av) > (pf.dev + af.dev + P.AGREEMENT_MARGIN) * min(pv, av)
                if fp:
                    rows.append((pv, pu, 0, pf.hb, dis, min(pv, av) if fa else pv, max(pv, av) if fa else pv))
                elif fa:
                    rows.append((av, au, 1, af.hb, False, av, av))
                else:
                    rows.append(None)
            self.leg[tok] = rows

    def selected_leg(self, tok, t):
        """(value, updatedAt, route, heartbeat, disagree, lower, higher) of the route in use, or None when both fail."""
        return self.leg[tok][min(int(t // 60), self.n_min - 1)]

    # ------------------------------------------------------------ pools
    def _pools(self):
        """Other LPs' in-range liquidity (whole-vault-token units) per market per
        minute, and the pool's log price for the TWAP guard."""
        rng = self.rng
        self.other_liq, self.pool_logp, self.twap_cum = {}, {}, {}
        for mk, cfg in P.MARKETS.items():
            t0, t1 = cfg['tokens']
            liq, lp, cum = [], [], [0.0]
            for m in range(self.n_min):
                d = m / 1440.0
                drain = 1.0
                if mk == 'GHO/USDC':
                    a, b = EP['pool_drain']
                    drain = _lin(d, a, b, 1.0, 0.15)
                if self.scenario and mk == self.sc.get('crunch'):
                    a, b = self.ep['crunch']
                    drain = _lin(d, a, a + 0.5, 1.0, 0.2) if d < b else _lin(d, b, b + 2, 0.2, 1.0)
                ratio = self.px[t0][max(0, m - 1)] / self.px[t1][max(0, m - 1)]
                x = math.log(ratio)
                if mk == 'GHO/USDC':
                    a, b = EP['twap_grief']
                    if a <= d < b:
                        x += 0.007
                    if d >= EP['pool_drain'][0]:
                        x += rng.gauss(0, 0.0004)
                lp.append(x)
                cum.append(cum[-1] + x)
                L = cfg['pool']['full_range'] / 2.0
                for hw, usd in cfg['pool']['buckets']:
                    if abs(x) < math.log(1 + hw):
                        L += usd / 2.0 / (1 - (1 + hw) ** -0.5)
                liq.append(L * drain)
            self.other_liq[mk], self.pool_logp[mk], self.twap_cum[mk] = liq, lp, cum

    def other_liq_hm(self, mk, t):
        m = min(int(t // 60), self.n_min - 1)
        lo = max(0, m - 30)
        arr = self.other_liq[mk][lo:m + 1]
        return len(arr) / sum(1.0 / max(v, 1.0) for v in arr)

    # ------------------------------------------------------------ oracle (2.10)
    def _oracle(self):
        """Per market per minute (2.10, Q-247, Q-274, Q-275): state (0 Live, 1 Drifting,
        2 Cached, 3 Expired), Drifting reasons, the accepted price (Avana's own valuations,
        REQ-ORACLE-087), the served price (Aave, SPEC-ORC-017), the seizure gate of this
        market, the grace window, the borrow-age gate and the price-drop breaker."""
        self.ostate, self.oreason, self.oacc, self.oserved, self.oliq, self.ograce = {}, {}, {}, {}, {}, {}
        self.oage_ok, self.opdrop, self.oqprod = {}, {}, {}
        for mk, cfg in P.MARKETS.items():
            t0, t1 = cfg['tokens']
            L0, L1 = self.leg[t0], self.leg[t1]
            vol = cfg.get('volatile', False)       # volatile pair: no stable ceiling, no USD band (stable-only checks)
            drop_bps = cfg.get('breaker_drop', P.ALERT_PRICE_DROP)
            twap_tol = cfg.get('twap_tol', 300 if vol else P.TWAP_TOL_TICKS)
            st, rs, ac, sv, lq, gr, ag, pdp = [], [], [], [], [], [], [], []
            qp = []   # q0 * q1 on the uncapped quotes (USD^2), None when a token has no quote (SPEC-BRK-002)
            accepted = 2.0
            fail_start = None
            expired_latch = False
            grace_until = -1
            disagree_since = None
            cp, cp_at = accepted, 0.0
            for m in range(self.n_min):
                t = m * 60.0
                l0, l1 = L0[m], L1[m]
                if l0 is None or l1 is None:
                    if fail_start is None:
                        fail_start = t
                    state = 2 if t - fail_start < P.CACHED_WINDOW else 3
                    if state == 3:
                        expired_latch = True
                    st.append(state); rs.append(0); ac.append(accepted)
                    sv.append(accepted if state == 2 else 1e-8)
                    lq.append('stale'); gr.append(False); ag.append(False); pdp.append(False); qp.append(None)
                    disagree_since = None
                    continue
                fail_start = None
                if expired_latch:
                    expired_latch = False
                    grace_until = min(t, max(l0[1], l1[1])) + P.GRACE_DURATION   # recoveredAt (EMG-034, Q-264)
                q0, q1 = l0[0], l1[0]
                v0, v1 = (q0, q1) if vol else (min(q0, P.STABLE_CEILING), min(q1, P.STABLE_CEILING))
                reason = 0
                disagree = l0[4] or l1[4]
                if disagree:
                    reason |= 1
                    if disagree_since is None:
                        disagree_since = t
                else:
                    disagree_since = None
                if not vol and (math.sqrt(q0 * q1) < P.USD_BAND[0] or math.sqrt(v0 * v1) > P.USD_BAND[1]):
                    reason |= 2
                lo = max(0, m - P.TWAP_WINDOW // 60)
                twap = (self.twap_cum[mk][m + 1] - self.twap_cum[mk][lo + 1]) / max(1, m - lo) if m > lo else self.pool_logp[mk][m]
                if abs(twap - math.log(q0 / q1)) / LN_TICK > twap_tol:
                    reason |= 4
                fresh = 2.0 * math.sqrt(v0 * v1)
                if reason == 0:
                    accepted = fresh
                    served = fresh
                elif disagree:
                    w0 = min(l0[5], P.STABLE_CEILING) if l0[4] else v0
                    w1 = min(l1[5], P.STABLE_CEILING) if l1[4] else v1
                    served = min(2.0 * math.sqrt(w0 * w1), accepted)
                else:
                    served = min(fresh, accepted)
                if t >= cp_at + P.CHECKPOINT_INTERVAL:
                    cp, cp_at = accepted, t
                pdp.append(t - cp_at <= 2 * P.HOUR and accepted < cp * (1 - drop_bps))
                liq_gate = 'ok'
                if disagree_since is not None:
                    liq_gate = 'disagree_pause' if t - disagree_since < P.DISAGREE_PAUSE_MAX else 'disagree_expired'
                elif (l0[2] == 1 and t - l0[1] > P.borrow_max_age(l0[3])) or (l1[2] == 1 and t - l1[1] > P.borrow_max_age(l1[3])):
                    liq_gate = 'alt_past_borrow_age'
                st.append(1 if reason else 0); rs.append(reason); ac.append(accepted); sv.append(served); qp.append(2.0 if vol else q0 * q1)
                lq.append(liq_gate); gr.append(t < grace_until)
                ag.append(t - l0[1] <= P.borrow_max_age(l0[3]) and t - l1[1] <= P.borrow_max_age(l1[3]))
            self.ostate[mk], self.oreason[mk], self.oacc[mk], self.oserved[mk] = st, rs, ac, sv
            self.oliq[mk], self.ograce[mk], self.oage_ok[mk], self.opdrop[mk] = lq, gr, ag, pdp
            self.oqprod[mk] = qp
        self._debt_oracle()
        self._manual_trips()

    def _manual_trips(self):
        """tripMarketBreaker on every market of a token whose routes and standby all fail; the pause
        guardian resets it once the market has been Live for one cachedWindow (P-02 recovery)."""
        self.manual = {mk: [] for mk in P.MARKETS}
        for tok, trips in self.manual_trip_t.items():
            for t_trip in trips.values():
                for mk, cfg in P.MARKETS.items():
                    if tok not in cfg['tokens']:
                        continue
                    m0, live = int(t_trip // 60), 0
                    reset = self.n_min * 60.0
                    for m in range(m0, self.n_min):
                        live = live + 1 if (self.ostate[mk][m] == 0 and self.oliq[mk][m] == 'ok' and self.oage_ok[mk][m]) else 0
                        if live * 60 >= P.CACHED_WINDOW:
                            reset = m * 60.0
                            break
                    self.manual[mk].append((t_trip, reset))
                    self.standby_events.append((t_trip / P.DAY, tok, mk, 'tripMarketBreaker'))
                    self.standby_events.append((reset / P.DAY, tok, mk, 'resetMarketBreaker'))

    def manual_trip(self, mk, t):
        return any(a <= t < b for a, b in self.manual[mk])

    def first_minute(self, mk, pred, after_day):
        for m in range(int(after_day * 1440), self.n_min):
            if pred(m):
                return m * 60.0
        return None

    def o(self, mk, t):
        """(state, reasons, accepted price, seizure gate, grace) of market mk at t."""
        m = min(int(t // 60), self.n_min - 1)
        return self.ostate[mk][m], self.oreason[mk][m], self.oacc[mk][m], self.oliq[mk][m], self.ograce[mk][m]

    def served(self, mk, t):
        return self.oserved[mk][min(int(t // 60), self.n_min - 1)]

    def borrow_age_ok(self, mk, t):
        """Every input of the market's price within its leg's borrowPriceMaxAge at t (Q-274)."""
        return self.oage_ok[mk][min(int(t // 60), self.n_min - 1)]

    def at_or_below_peg(self, mk, t):
        """SPEC-BRK-002: q0 * q1 <= 10^16 (1.0 in USD^2); a token with no quote counts as at or below peg."""
        qp = self.oqprod[mk][min(int(t // 60), self.n_min - 1)]
        return qp is None or qp <= 1.0

    def price_drop(self, mk, t):
        return self.opdrop[mk][min(int(t // 60), self.n_min - 1)]

    # ------------------------------------------------------------ DebtOracle for USDC (Q-248)
    def _debt_oracle(self):
        """USDC debt reserve: the LPOracle pipeline on one token (REQ-ORACLE-092), served
        price by SPEC-ORC-018, the borrow gate (Live and within borrowPriceMaxAge) and the
        repayment gate of a liquidation (not liquidationPaused, within liquidationPriceMaxAge)."""
        rows = []
        L = self.leg['USDC']
        accepted = 1.0
        fail_start = None
        for m in range(self.n_min):
            t = m * 60.0
            l = L[m]
            if l is None:
                if fail_start is None:
                    fail_start = t
                state = 2 if t - fail_start < P.CACHED_WINDOW else 3
                served = accepted if state == 2 else accepted * (1 + P.DEBT_STRESS_RISE['USDC'])
                rows.append((state, served, False, False))
                continue
            fail_start = None
            age = t - l[1]
            if l[4]:
                rows.append((1, max(l[6], accepted), False, False))
                continue
            accepted = l[0]
            alt_past = l[2] == 1 and age > P.borrow_max_age(l[3])
            rows.append((0, l[0], age <= P.borrow_max_age(l[3]), (not alt_past) and age <= P.liq_max_age(l[3])))
        self.debt_rows = rows

    def debt_o(self, t):
        """(state, served price, borrow gate ok, liquidation repay gate ok) of the USDC DebtOracle."""
        return self.debt_rows[min(int(t // 60), self.n_min - 1)]

    # ------------------------------------------------------------ settlement routes (2.12)
    def route_info(self, tok, t, usd, mk=None):
        """(cost, primaryFailed): fraction of oracle value lost converting `usd` of `tok` to
        GHO on the best working route (primary, then backup), and whether the primary sell
        route was unavailable (GSM frozen outside 0.99-1.01). Backup routes never trade
        through the market's own pool (Q-273)."""
        if tok == 'GHO':
            return 0.0, False
        if self.scenario:
            return self._scenario_route(tok, t, usd, mk)
        d = t / P.DAY
        px = self.price(tok, t)
        if tok in ('USDC', 'USDT'):
            if 0.99 <= px <= 1.01:
                return 0.0005 + usd / 200e6, False
            depth = 5e6 if EP['usdt_depeg'][0] <= d < EP['usdt_depeg'][0] + 1.5 else 50e6
            return 0.0008 + 0.01 * usd / depth, True
        if tok == 'DAI':
            return 0.0006 + usd / 100e6, False
        if tok == 'USDe':
            a, b = EP['usde_routes_stressed']
            if a <= d < b:
                disc = 0.03 + 0.03 * math.sin((d - a) * 3.1) ** 2
                return disc + 0.01 * usd / 0.5e6, False
            return 0.0006 + 0.01 * usd / 30e6, False
        return 0.002, False

    def _scenario_route(self, tok, t, usd, mk):
        """Scenario routes: a stable token off peg by more than 1% loses its primary (GSM/PSM-style)
        route and trades on 10% of the normal depth; the crunched market's exit depth is 20% of
        normal (-80%); WETH trades on $30M of depth, $6M and a 0.5% discount in the crash window."""
        d = t / P.DAY
        px = self.price(tok, t)
        crunch = self.sc.get('crunch')
        k = 0.2 if (crunch and mk == crunch and self.ep['crunch'][0] <= d < self.ep['crunch'][1] + 1) else 1.0
        if tok == 'WETH':
            a = SHOCK_DAY
            if self.sc.get('eth_drop') and a <= d < a + 2:
                return 0.0008 + 0.005 + 0.01 * usd / (6e6 * k), False
            return 0.0008 + 0.01 * usd / (30e6 * k), False
        if 0.99 <= px <= 1.01:
            return 0.0005 + usd / (100e6 * k), False
        return 0.0008 + 0.01 * usd / (10e6 * k), True

    def route_cost(self, tok, t, usd, mk=None):
        return self.route_info(tok, t, usd, mk)[0]
