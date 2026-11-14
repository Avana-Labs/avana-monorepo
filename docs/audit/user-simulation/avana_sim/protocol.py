"""Avana at the level of the spec's rules (decisions Q-001 to Q-278).

Each user action is checked twice: once by the app's pre-check when the user
prepares it (a refusal costs no gas) and once on-chain at the block it lands
in (a revert costs gas). Gates and error names follow the flow pages:
3.1 Deposit, 3.2 Borrow, 3.3 Repay, 3.4 Withdraw, 3.5 Liquidation,
3.6 Emergency, 3.7 Collect fees, and the contract pages they cite.

Prices: Avana's own valuations (cap charges, the minimum pledge value, the
restore amount's booking, previews) use the LPOracle's last accepted price; Aave's
health factor, liquidation sizing, the rescue-excluded health check and the
restore amount's divisor use the served price (REQ-ORACLE-087, SPEC-ORC-017,
SPEC-CAP-003).

Units: liquidity is counted in whole vault tokens (one whole token is worth
about $2 at peg); every amount of money is in USD (GHO = $1 for debt).
"""
import math

from . import params as P


class NFT:
    __slots__ = ('id', 'wallet', 'market', 'liq', 'full_range', 'owed', 'donated', 'in_vault',
                 'alive', 'liq_initial', 'seized', 'collected', 'accrued', 'removed', 'recredited')

    def __init__(self, nid, wallet, market, liq, full_range=True):
        self.id, self.wallet, self.market, self.liq = nid, wallet, market, liq
        self.full_range, self.owed, self.donated, self.in_vault, self.alive = full_range, 0.0, 0.0, False, True
        self.liq_initial, self.seized, self.collected, self.accrued = liq, 0.0, 0.0, 0.0
        self.removed, self.recredited = 0.0, 0.0


class Record:
    __slots__ = ('id', 'nft', 'market', 'credited', 'orig_units', 'orig_charge', 'charge', 'wallet', 'rescue')

    def __init__(self, rid, nft, market, credited, charge, wallet, rescue=0.0):
        self.id, self.nft, self.market, self.credited = rid, nft, market, credited
        self.orig_units, self.orig_charge, self.charge, self.wallet = credited, charge, charge, wallet
        self.rescue = rescue


class Account:
    """One PositionProxy per wallet per Borrow Spoke (Q-225, Q-276). The base runs have one Spoke;
    a topology run gives each (person, Spoke) its own wallet and so its own account."""

    def __init__(self, wallet, spoke='Stable'):
        self.wallet = wallet
        self.spoke = spoke
        self.records = {mk: [] for mk in P.MARKET_IDS}
        self.debt = {a: 0.0 for a in P.DEBT_ASSETS}
        self.nonce = 0
        self.borrowed = {a: 0.0 for a in P.DEBT_ASSETS}
        self.repaid = {a: 0.0 for a in P.DEBT_ASSETS}
        self.interest = {a: 0.0 for a in P.DEBT_ASSETS}
        self.liquidated = {a: 0.0 for a in P.DEBT_ASSETS}
        self.written_off = {a: 0.0 for a in P.DEBT_ASSETS}

    def has_debt(self):
        return any(v > 1e-9 for v in self.debt.values())

    def markets(self):
        return [mk for mk, rs in self.records.items() if any(r.credited > 0 for r in rs)]

    def credited(self, mk):
        return sum(r.credited for r in self.records[mk])

    def rescue(self, mk):
        return sum(r.rescue for r in self.records[mk])


class Refused(Exception):
    pass


class Protocol:
    def __init__(self, world, metrics, spokes=None, draw_caps=None):
        self.w, self.m = world, metrics
        # topology runs: market -> Spoke, per-Spoke drawCaps, wallet -> Spoke (set by the engine)
        self.spokes, self.draw_caps = spokes, draw_caps
        self.spoke_of = {}
        self.spoke_accounts = {}
        self.spoke_deficit = {}
        self.pause = 'None'
        self.pause_reason = P.PAUSE_REASON
        self.frozen = set()
        self.freeze_log = {}
        self.accounts = {}
        self.nfts = {}
        self.next_nft = 1
        self.next_rec = 1
        self.mk = {mk: dict(supply=0.0, credited=0.0, pending=0.0, regular=0.0, slice=0.0)
                   for mk in P.MARKET_IDS}
        self.token_used = {}
        self.dep_used = {}
        self.drawn = {a: 0.0 for a in P.DEBT_ASSETS}
        self.deficit = {a: 0.0 for a in P.DEBT_ASSETS}
        self.keepers = 3
        self.slice_by_wallet = {}
        self.rescue_by_wallet = {}
        # monitoring alert windows (seizure, route failures; Q-399) and shortfall runs (REQ-SWAP-103)
        self.latch = {mk: dict(window_start=-1e18, credited_at_start=0.0, seized=0.0, failures=0)
                      for mk in P.MARKET_IDS}
        self.latch_log = []
        self.shortfall_since = {mk: 0.0 for mk in P.MARKET_IDS}
        self.last_shortfall = {mk: -1e18 for mk in P.MARKET_IDS}
        self.rescue_excluded_refusals = []
        self.first_slice = {}
        self.borrowed_after_slice = {}

    # ----------------------------------------------------------------- interest (lazy, per account)
    @staticmethod
    def rate(asset, t):
        if asset == 'USDC' and 60 * P.DAY <= t < 70 * P.DAY:
            return P.USDC_STRESS_RATE
        return P.RATES[asset]

    def _acc(self, a, t):
        dt = t - getattr(a, 'acc_t', t)
        a.acc_t = max(t, getattr(a, 'acc_t', t))
        if dt <= 0:
            return
        for k in P.DEBT_ASSETS:
            if a.debt[k] > 0:
                inc = a.debt[k] * self.rate(k, t) * dt / P.YEAR
                a.debt[k] += inc
                a.interest[k] += inc
                self.drawn[k] += inc

    # ----------------------------------------------------------------- helpers
    def new_nft(self, wallet, market, liq, full_range=True):
        n = NFT(self.next_nft, wallet, market, liq, full_range)
        self.nfts[n.id] = n
        self.next_nft += 1
        return n

    def price(self, mk, t):
        """Last accepted price: Avana's own valuations (REQ-ORACLE-087)."""
        return self.w.o(mk, t)[2]

    def served(self, mk, t):
        """Served price: Aave's health factor and sizing (SPEC-ORC-017)."""
        return self.w.served(mk, t)

    def debt_price(self, a, t):
        return 1.0 if a == 'GHO' else self.w.debt_o(t)[1]

    def acct(self, wallet):
        return self.accounts.get(wallet)

    def cf_coll(self, a, t, extra=None, exclude_rescue=False, extra_rescue=None):
        tot = 0.0
        for mk in P.MARKET_IDS:
            c = a.credited(mk) + (extra.get(mk, 0.0) if extra else 0.0)
            if exclude_rescue:
                c -= a.rescue(mk) + (extra_rescue.get(mk, 0.0) if extra_rescue else 0.0)
            if c > 0:
                tot += c * self.served(mk, t) * P.MARKETS[mk]['cf']
        return tot

    def debt_value(self, a, t, extra=None):
        self._acc(a, t)
        tot = 0.0
        for k in P.DEBT_ASSETS:
            d = a.debt[k] + (extra.get(k, 0.0) if extra else 0.0)
            if d > 0:
                tot += d * self.debt_price(k, t)
        return tot

    def hf(self, a, t, extra_coll=None, extra_debt=None):
        """Aave's health factor at served prices; rescue units count in full (Q-253)."""
        d = self.debt_value(a, t, extra_debt)
        if d <= 1e-12:
            return float('inf')
        return self.cf_coll(a, t, extra_coll) / d

    def hf_ex(self, a, t, extra_coll=None, extra_debt=None, extra_rescue=None):
        """Health factor with rescue units valued at zero (SPEC-CF-005, REQ-RISK-068)."""
        d = self.debt_value(a, t, extra_debt)
        if d <= 1e-12:
            return float('inf')
        return self.cf_coll(a, t, extra_coll, True, extra_rescue) / d

    def coll_usd(self, a, t):
        return sum(a.credited(mk) * self.served(mk, t) for mk in P.MARKET_IDS)

    def usd_to_restore(self, a, mk, t, hf=None):
        """SPEC-CAP-003: USD of collateral that restores the recommended HF 1.10 (rescue target)."""
        hf = self.hf(a, t) if hf is None else hf
        if hf >= P.RECOMMENDED_HF:
            return 0.0
        return (P.RECOMMENDED_HF - hf) * self.debt_value(a, t) / P.MARKETS[mk]['cf']

    # ----------------------------------------------------------------- breakers (Q-241)
    def market_breaker(self, mk, t):
        """Reasons other than ORACLE that trip market mk's breaker (REQ-RISK-065)."""
        r = []
        S = self.mk[mk]['supply']
        if S > P.POOL_SHARE_MAX * (self.w.other_liq_hm(mk, t) + S):
            r.append('POOL_SHARE')   # Q-399: Avana's combined share of the pool above poolShareMaxBps
        if self.w.manual_trip(mk, t):
            r.append('MANUAL')
        return r

    def debt_breaker(self, asset, t, spoke=None):
        if self.spokes is not None and spoke is not None:   # breakerDeficitMax: the asset's Hub deficit on this Spoke
            return ['DEFICIT'] if self.spoke_deficit.get(spoke, {}).get(asset, 0.0) > P.BREAKER_DEFICIT_MAX else []
        return ['DEFICIT'] if self.deficit[asset] > P.BREAKER_DEFICIT_MAX else []

    def _window(self, mk, t, units=0.0):
        lt = self.latch[mk]
        if t >= lt['window_start'] + P.ALERT_WINDOW:
            lt['window_start'] = t
            lt['credited_at_start'] = self.mk[mk]['credited'] + units
            lt['seized'] = 0.0
            lt['failures'] = 0
            lt['alerted'] = set()
        return lt

    def _latch(self, mk, reason, t):
        """Monitoring alert (Q-399): logged once per window, never blocks activity."""
        lt = self.latch[mk]
        if reason not in lt.setdefault('alerted', set()):
            self.latch_log.append((t / P.DAY, mk, reason))
        lt['alerted'].add(reason)

    def record_outcome(self, mk, units, sell_primary_failed, t):
        """Seizure and route-failure monitoring alerts (Q-399)."""
        lt = self._window(mk, t, units)
        lt['seized'] += units
        if lt['seized'] > P.ALERT_SEIZURE * lt['credited_at_start']:
            self._latch(mk, 'SEIZURE_SURGE', t)
        lt['failures'] += 1 if sell_primary_failed else 0
        if lt['failures'] >= P.ALERT_ROUTE_FAILURES:
            self._latch(mk, 'ROUTE_FAILURES', t)
        self.shortfall_since[mk] = 0.0

    def record_shortfall(self, mk, t):
        """A failed keeper attempt (RecoveryBelowFloor): counts toward the route-failure alert (Q-399)."""
        if self.shortfall_since[mk] == 0.0 or self.last_shortfall[mk] + P.SHORTFALL_GAP < t:
            self.shortfall_since[mk] = t
        self.last_shortfall[mk] = t
        lt = self._window(mk, t)
        lt['failures'] += 1
        if lt['failures'] >= P.ALERT_ROUTE_FAILURES:
            self._latch(mk, 'ROUTE_FAILURES', t)
        return False

    # ----------------------------------------------------------------- address freeze (Q-242)
    def freeze_address(self, caller, account, t):
        log = [x for x in self.freeze_log.get(caller, []) if t - x < P.DAY]
        if len(log) >= P.MAX_ADDRESS_FREEZES_PER_DAY:
            raise Refused('FreezeRateLimited')
        log.append(t)
        self.freeze_log[caller] = log
        self.frozen.add(account)

    # ----------------------------------------------------------------- pledge (3.1, 2.7)
    def pledge_check(self, wallet, nft, t, L=None, hf_override=None):
        """Returns dict(c, slice, rescue, rescue_units) or raises Refused(error)."""
        a = self.accounts.get(wallet)
        topup = a is not None and a.has_debt()
        require_rescue = False
        # Adapter: pause state and address freeze before custody (REQ-ADAPTER-083)
        if self.pause == 'Paused':
            if self.pause_reason == 'MintPathSuspect':
                raise Refused('ApplicationPaused')
            require_rescue = True
        if self.pause == 'Frozen' and not topup:
            raise Refused('ApplicationFrozen')
        if wallet in self.frozen:
            if a is None:
                raise Refused('AddressIsFrozen')
            require_rescue = True
        if not nft.full_range:
            raise Refused('NotFullRange')
        mk = nft.market
        if self.spokes is not None and self.spokes[mk] != self.spoke_of.get(wallet, self.spokes[mk]):
            raise Refused('MarketNotOnSpoke')
        state, reason, price, _, _ = self.w.o(mk, t)
        if state >= 2:
            raise Refused('PriceNotAccepted(Cached/Expired)')
        if not topup and state == 1 and reason != 2:
            raise Refused('PriceNotAccepted(Drifting)')
        L = nft.liq if L is None else L
        pledge_usd = L * price
        c = L * max(price, P.STRESS_FLOOR_PER_VT)
        hf = (self.hf(a, t) if topup else float('inf')) if hf_override is None else hf_override
        eligible = topup and hf < P.RECOMMENDED_HF
        restore = 0.0
        if eligible:
            # SPEC-CAP-003: the collateral that restores minOpeningHealthFactor at the price Aave
            # values it at (served8 = latestAnswer()), booked at the accepted price.
            restore = self.usd_to_restore(a, mk, t, hf) * max(price, P.STRESS_FLOOR_PER_VT) / self.served(mk, t)
        m = self.mk[mk]
        cap = P.MARKETS[mk]['cap']
        room = max(0.0, cap - m['regular'])
        slice_part = 0.0
        if c > room:
            if not eligible:
                raise Refused('CapExceeded(market)' if not topup else 'SliceNotAvailable')
            slice_part = c - room
            if slice_part > restore:
                raise Refused('SliceNotAvailable')
            if m['slice'] + slice_part > cap * P.TOPUP_SLICE_FRACTION:
                raise Refused('CapExceeded(slice)')
        for tok in P.MARKETS[mk]['tokens']:
            if self.token_used.get(tok, 0.0) + (c - slice_part) > P.TOKEN_USD_CAP:
                raise Refused('CapExceeded(token)')
        if self.dep_used.get(wallet, 0.0) + (c - slice_part) > P.DEPOSITOR_USD_CAP:
            raise Refused('CapExceeded(depositor)')
        S = m['supply']
        pool_share = (S + L) > P.POOL_SHARE_MAX * (self.w.other_liq_hm(mk, t) + S)
        breaker = self.market_breaker(mk, t)
        below_min = pledge_usd < P.MIN_PLEDGE_USD
        if pledge_usd < min(P.MIN_PLEDGE_USD, P.RESCUE_MIN_PLEDGE_USD):
            raise Refused('BelowMinPledge')
        needs = require_rescue or pool_share or bool(breaker) or below_min
        if needs:
            if not (eligible and c <= restore * (1 + 1e-12)):
                if below_min and not (require_rescue or pool_share or breaker):
                    raise Refused('BelowMinPledge')
                if require_rescue:
                    raise Refused('NotRescueTopUp')
                if pool_share:
                    raise Refused('PoolShareExceeded')
                raise Refused('BreakerTripped(%s)' % ','.join(breaker))
            return dict(c=c, slice=slice_part, rescue=True, rescue_units=L, L=L,
                        why=[x for x, y in (('pause', require_rescue and self.pause == 'Paused'), ('freeze', wallet in self.frozen),
                                            ('pool_share', pool_share), ('breaker', bool(breaker))) if y])
        ru = L * slice_part / c if slice_part > 0 else 0.0
        return dict(c=c, slice=slice_part, rescue=False, rescue_units=ru, L=L, why=[])

    def _book(self, wallet, mk, ch):
        m = self.mk[mk]
        m['regular'] += ch['c'] - ch['slice']
        m['slice'] += ch['slice']
        if ch['slice']:
            self.slice_by_wallet[wallet] = self.slice_by_wallet.get(wallet, 0.0) + ch['slice']
            self.first_slice.setdefault(wallet, True)
        if ch['rescue_units']:
            self.rescue_by_wallet[wallet] = self.rescue_by_wallet.get(wallet, 0.0) + ch['rescue_units']
        for tok in P.MARKETS[mk]['tokens']:
            self.token_used[tok] = self.token_used.get(tok, 0.0) + ch['c']
        self.dep_used[wallet] = self.dep_used.get(wallet, 0.0) + ch['c']
        m['supply'] += ch['L']
        m['credited'] += ch['L']

    def pledge(self, wallet, nft, t):
        ch = self.pledge_check(wallet, nft, t)
        first = wallet not in self.accounts
        if first:
            spoke = self.spoke_of.setdefault(wallet, self.spokes[nft.market]) if self.spokes is not None else 'Stable'
            self.accounts[wallet] = Account(wallet, spoke)
            self.accounts[wallet].acc_t = t
            self.spoke_accounts.setdefault(spoke, []).append(self.accounts[wallet])
        a = self.accounts[wallet]
        mk = nft.market
        rec = Record(self.next_rec, nft, mk, nft.liq, ch['c'], wallet, ch['rescue_units'])
        self.next_rec += 1
        a.records[mk].append(rec)
        a.records[mk].sort(key=lambda r: (-r.credited, r.id))
        self._book(wallet, mk, ch)
        nft.in_vault = True
        self.m.check('rescue units <= credited per record', rec.rescue <= rec.credited + 1e-9, str(nft.id))
        return first, ch

    def recredit(self, wallet, nft, t):
        """AaveAdapter.recredit (Q-254): book live - credited as a top-up of exactly that amount."""
        a = self.accounts.get(wallet)
        rec = self._record_of(a, nft) if a else None
        if rec is None:
            raise Refused('NotRecordProxy')
        if nft.wallet != wallet:
            raise Refused('NotDepositor')
        added = nft.liq - rec.credited
        if added <= 1e-9:
            raise Refused('NothingToCredit')
        ch = self.pledge_check(wallet, nft, t, L=added)
        rec.credited += added
        rec.charge += ch['c']
        rec.orig_charge, rec.orig_units = rec.charge, rec.credited
        rec.rescue += ch['rescue_units']
        a.records[nft.market].sort(key=lambda r: (-r.credited, r.id))
        self._book(wallet, nft.market, ch)
        nft.recredited += added
        self.m.check('re-credit: record credited == live liquidity', abs(rec.credited - nft.liq) < 1e-6 * max(1.0, nft.liq), str(nft.id))
        return added, ch

    def _release_charge(self, rec, units_out):
        """SPEC-CAP-004 / Q-174 fixed-basis exit charge; slice first, saturating."""
        before = rec.charge
        remaining_units = rec.credited - units_out
        remaining = math.ceil(rec.orig_charge * remaining_units / rec.orig_units * 1e8) / 1e8 if rec.orig_units else 0.0
        release = max(0.0, before - remaining)
        rec.charge = remaining
        m = self.mk[rec.market]
        s = min(m['slice'], release)
        m['slice'] -= s
        m['regular'] = max(0.0, m['regular'] - (release - s))
        for tok in P.MARKETS[rec.market]['tokens']:
            self.token_used[tok] = max(0.0, self.token_used.get(tok, 0.0) - release)
        self.dep_used[rec.wallet] = max(0.0, self.dep_used.get(rec.wallet, 0.0) - release)

    def _debit(self, a, rec, units):
        """Collateralization debit of a record: charge release, rescue units capped at credited (SPEC-BACK-014)."""
        self._release_charge(rec, units)
        rec.credited -= units
        if rec.credited < 1e-12:
            rec.credited = 0.0
        rec.rescue = min(rec.rescue, rec.credited)
        m = self.mk[rec.market]
        m['supply'] -= units
        m['credited'] -= units
        a.records[rec.market].sort(key=lambda r: (-r.credited, r.id))

    # ----------------------------------------------------------------- borrow (3.2)
    def gate_account(self, a, t, asset=None, debts=None):
        """RiskModule preBorrowCheck / preWithdrawCheck (2.7, Q-229, Q-241, Q-247): account-wide."""
        for mk in a.markets():
            state, reason, _, _, _ = self.w.o(mk, t)
            if state >= 2:
                raise Refused('PriceNotLive(Cached/Expired)')
            if state == 1:
                raise Refused('PriceNotLive(Drifting:%s)' % ('band' if reason == 2 else 'twap' if reason == 4 else 'disagree' if reason & 1 else 'mixed'))
            if not self.w.borrow_age_ok(mk, t):
                raise Refused('PriceTooOld')
            br = self.market_breaker(mk, t)
            if br:
                raise Refused('BreakerTripped(%s)' % ','.join(br))
        scope = [k for k in P.DEBT_ASSETS if a.debt[k] > 0]
        if asset and asset not in scope:
            scope.append(asset)
        for k in scope:
            if k == 'USDC' and not self.w.debt_o(t)[2]:
                raise Refused('DebtPriceTooOld')
            if self.debt_breaker(k, t, a.spoke):
                raise Refused('DebtBreakerTripped')
        if self.keepers < 1:
            raise Refused('LiquidationHalted')

    def borrow_check(self, wallet, asset, units, t, min_hf, nonce):
        """`units` of the debt asset (GHO or USDC)."""
        a = self.accounts.get(wallet)
        if a is None:
            raise Refused('NoProxy')
        if self.pause != 'None':
            raise Refused('Application' + self.pause)
        if wallet in self.frozen:
            raise Refused('AddressIsFrozen')
        if nonce is not None and nonce != a.nonce:
            raise Refused('BadNonce')
        if units <= 0:
            raise Refused('ZeroAmount')
        self.gate_account(a, t, asset)
        if self.drawn[asset] + units + self.deficit[asset] > P.CREDIT_LINE[asset]:
            raise Refused('DrawCapExceeded')
        if self.draw_caps is not None:
            cap = self.draw_caps[a.spoke].get(asset, 0.0)
            if cap <= 0:
                raise Refused('ReserveNotApproved')
            if self.spoke_drawn(a.spoke, asset) + units > cap:
                raise Refused('DrawCapExceeded')
        req = max(P.MIN_HF, P.MARKET_HARD_FLOOR_HF, min_hf or 0.0)
        hfx = self.hf_ex(a, t, extra_debt={asset: units})
        if hfx < req:
            if self.hf(a, t, extra_debt={asset: units}) >= req:
                self.rescue_excluded_refusals.append((t / P.DAY, wallet))
            raise Refused('HealthFactorTooLow')
        # no minimum debt (Q-381)
        return units

    def spoke_drawn(self, spoke, asset):
        """Hub draw of one Spoke on a debt asset: its accounts' debt plus its uncovered deficit (SPEC-HUB-003)."""
        return sum(a.debt[asset] for a in self.spoke_accounts.get(spoke, ())) + self.spoke_deficit.get(spoke, {}).get(asset, 0.0)

    def borrow(self, wallet, asset, units, t, min_hf, nonce):
        units = self.borrow_check(wallet, asset, units, t, min_hf, nonce)
        a = self.accounts[wallet]
        self._acc(a, t)
        a.nonce += 1
        a.debt[asset] += units
        a.borrowed[asset] += units
        self.drawn[asset] += units
        if wallet in self.first_slice:
            self.borrowed_after_slice[wallet] = self.borrowed_after_slice.get(wallet, 0.0) + units * self.debt_price(asset, t)
        self.m.check('rescue-excluded HF >= 1.00 (or the hard floor) after every borrow (REQ-RISK-068)', self.hf_ex(a, t) >= max(P.MIN_HF, P.MARKET_HARD_FLOOR_HF) - 1e-12, wallet)
        return units

    def preview_borrow_recommended(self, wallet, asset, t, deadline):
        """Lens.recommendedBorrow (Q-398): the borrow that leaves HF 1.10."""
        return self.preview_borrow_max(wallet, asset, t, deadline, P.RECOMMENDED_HF)

    def preview_borrow_max(self, wallet, asset, t, deadline, target=None):
        """Lens.previewBorrowMax (REQ-LENS-035): rescue units at zero, target HF (Aave's 1.00, or the
        market's hard floor) grown to the deadline, +0.5%."""
        target = max(P.MIN_HF, P.MARKET_HARD_FLOOR_HF) if target is None else target
        a = self.accounts.get(wallet)
        if a is None:
            return 0.0
        try:
            self.gate_account(a, t, asset)
        except Refused:
            return 0.0
        if self.pause != 'None' or wallet in self.frozen:
            return 0.0
        rate = max([self.rate(k, t) for k in P.DEBT_ASSETS if a.debt[k] > 0] + [self.rate(asset, t)])
        ht = max(target * (1 + rate * deadline / P.YEAR) * P.BORROW_MAX_MARGIN, target)
        amt = (self.cf_coll(a, t, exclude_rescue=True) / ht - self.debt_value(a, t)) / self.debt_price(asset, t)
        if self.draw_caps is not None:
            amt = min(amt, self.draw_caps[a.spoke].get(asset, 0.0) - self.spoke_drawn(a.spoke, asset))
        return max(0.0, min(amt, P.CREDIT_LINE[asset] - self.drawn[asset] - self.deficit[asset]))

    # ----------------------------------------------------------------- repay (3.3)
    def quote_repay_all(self, borrower, asset, t, deadline):
        """Lens.quoteRepayAll (REQ-LENS-036): debt x (1 + rate x (deadline - now)) x 1.001, rounded up."""
        a = self.accounts.get(borrower)
        if a is None:
            return 0.0
        self._acc(a, t)
        q = a.debt[asset] * (1 + self.rate(asset, t) * deadline / P.YEAR) * P.REPAY_ALL_MARGIN
        return math.ceil(q * 1e6) / 1e6

    def repay(self, borrower, asset, max_spend, repay_all, allowance, balance, t):
        """Any payer. Never reads pause state, freeze or price state (REP-001, Q-260). Returns spent.
        A repay-all pulls max_spend and refunds the unused part in the same call (Q-269)."""
        a = self.accounts.get(borrower)
        if a is None:
            raise Refused('NoProxy')
        self._acc(a, t)
        D = a.debt[asset]
        if D <= 1e-12:
            return 0.0
        if repay_all:
            if D > max_spend + 1e-12:
                raise Refused('RepayExceedsMax')
            pull, x = max_spend, D
        else:
            pull = x = min(max_spend, D)
        if allowance + 1e-12 < pull:
            raise Refused('ERC20InsufficientAllowance')
        if balance + 1e-12 < pull:
            raise Refused('ERC20InsufficientBalance')
        a.debt[asset] -= x
        if a.debt[asset] < 1e-9:
            a.debt[asset] = 0.0
        a.repaid[asset] += x
        self.drawn[asset] = max(0.0, self.drawn[asset] - x)
        self.m.check('repay-all leaves no allowance (refund of the unused pull, REP-009)', (not repay_all) or pull - x >= -1e-9, borrower)
        return x

    # ----------------------------------------------------------------- withdraw (3.4)
    def _with_debt_gates(self, a, wallet, t):
        if self.pause == 'Paused':
            raise Refused('ApplicationPaused')
        if wallet in self.frozen:
            raise Refused('AddressIsFrozen')
        self.gate_account(a, t)

    def withdraw_check(self, wallet, nft, units, t, min_hf):
        a = self.accounts.get(wallet)
        if a is None:
            raise Refused('NoProxy')
        rec = self._record_of(a, nft)
        if rec is None:
            raise Refused('NotRecordProxy')
        if units <= 0:
            raise Refused('ZeroAmount(use releaseZeroCredit)')
        if abs(units - rec.credited) > 1e-9:
            raise Refused('UnitsMismatch')
        if a.has_debt():
            self._with_debt_gates(a, wallet, t)
            hf = self.hf_ex(a, t, extra_coll={nft.market: -units}, extra_rescue={nft.market: -rec.rescue})
            if hf < max(P.MIN_HF, P.MARKET_HARD_FLOOR_HF, min_hf or 0.0):
                raise Refused('HealthFactorTooLow')
        return rec

    def withdraw(self, wallet, nft, units, t, min_hf=0.0):
        rec = self.withdraw_check(wallet, nft, units, t, min_hf)
        a = self.accounts[wallet]
        self._close_record(a, rec, units)
        if a.has_debt():
            self.m.check('rescue-excluded HF >= 1.00 (or the hard floor) after withdraw-with-debt', self.hf_ex(a, t) >= max(P.MIN_HF, P.MARKET_HARD_FLOOR_HF) - 1e-12, wallet)
        return units

    def remove_check(self, wallet, nft, units, t, min_hf):
        """AaveAdapter.removeLiquidity (Q-254): 0 < units < credited."""
        a = self.accounts.get(wallet)
        if a is None:
            raise Refused('NoProxy')
        rec = self._record_of(a, nft)
        if rec is None:
            raise Refused('NotRecordProxy')
        if nft.wallet != wallet:
            raise Refused('NotDepositor')
        if not 0 < units < rec.credited:
            raise Refused('UnitsOutOfRange')
        if a.has_debt():
            self._with_debt_gates(a, wallet, t)
            left = rec.credited - units
            d_resc = min(rec.rescue, left) - rec.rescue
            hf = self.hf_ex(a, t, extra_coll={nft.market: -units}, extra_rescue={nft.market: d_resc})
            if hf < max(P.MIN_HF, P.MARKET_HARD_FLOOR_HF, min_hf or 0.0):
                raise Refused('HealthFactorTooLow')
            if left * self.price(nft.market, t) < P.MIN_PLEDGE_USD:
                raise Refused('BelowMinPledge(remaining record)')
        return rec

    def remove_liquidity(self, wallet, nft, units, t, min_hf=0.0):
        rec = self.remove_check(wallet, nft, units, t, min_hf)
        a = self.accounts[wallet]
        self._debit(a, rec, units)
        nft.liq -= units
        nft.removed += units
        if a.has_debt():
            self.m.check('rescue-excluded HF >= 1.00 (or the hard floor) after partial removal with debt', self.hf_ex(a, t) >= max(P.MIN_HF, P.MARKET_HARD_FLOOR_HF) - 1e-12, wallet)
        self.m.check('record live liquidity >= credited after removal', nft.liq >= rec.credited - 1e-9, str(nft.id))
        return units * self.served(nft.market, t)

    def repay_all_and_withdraw(self, wallet, nft, units, quotes, t):
        """WDR-024: repay-all of every listed reserve (pull the cap, refund the rest), require
        zero debt, then the debt-free withdrawal. Reads no pause, freeze or price state. Atomic."""
        a = self.accounts.get(wallet)
        if a is None:
            raise Refused('NoProxy')
        self._acc(a, t)
        rec = self._record_of(a, nft)
        if rec is None:
            raise Refused('NotRecordProxy')
        plan = {}
        for k, (cap, allowance, balance) in quotes.items():
            d = a.debt[k]
            if d <= 1e-12:
                continue
            if d > cap + 1e-12:
                raise Refused('RepayExceedsMax')
            if allowance + 1e-12 < cap:
                raise Refused('ERC20InsufficientAllowance')
            if balance + 1e-12 < cap:
                raise Refused('ERC20InsufficientBalance')
            plan[k] = d
        for k in P.DEBT_ASSETS:
            if a.debt[k] > 1e-12 and k not in plan:
                raise Refused('DebtRemaining')
        if abs(units - rec.credited) > 1e-9:
            raise Refused('UnitsMismatch')
        a.repay_spent = {}
        for k, x in plan.items():
            a.debt[k] = 0.0
            a.repaid[k] += x
            self.drawn[k] = max(0.0, self.drawn[k] - x)
            a.repay_spent[k] = x
        self._close_record(a, rec, units)
        return units

    def _close_record(self, a, rec, units):
        self._debit(a, rec, units)
        rec.credited = 0.0
        a.records[rec.market].remove(rec)
        rec.nft.in_vault = False

    def _record_of(self, a, nft):
        for r in a.records[nft.market]:
            if r.nft is nft:
                return r
        return None

    def release_zero(self, wallet, nft):
        a = self.accounts.get(wallet)
        rec = self._record_of(a, nft) if a else None
        if rec is None:
            raise Refused('NoRecord')
        if rec.credited > 1e-12:
            raise Refused('CreditRemaining')
        self._release_charge(rec, 0.0)
        a.records[rec.market].remove(rec)
        nft.in_vault = False

    def collect(self, wallet, nft):
        """3.7: depositor of record only, no other gate."""
        if nft.wallet != wallet:
            raise Refused('NotDepositor')
        amt = nft.owed
        nft.owed = 0.0
        nft.collected += amt
        return amt

    # ----------------------------------------------------------------- repay with collateral (Q-255)
    def deleverage_quote(self, wallet, nft, units, asset, t):
        """SPEC-LIQ-020 sizing and the conversion at sLeg = slippageAllowanceBps. Returns a dict or raises."""
        a = self.accounts.get(wallet)
        if a is None:
            raise Refused('NoProxy')
        if self.pause == 'Paused':
            raise Refused('ApplicationPaused')
        if wallet in self.frozen:
            raise Refused('AddressIsFrozen')
        rec = self._record_of(a, nft)
        if rec is None:
            raise Refused('NotRecordProxy')
        if not 0 < units <= rec.credited + 1e-12:
            raise Refused('UnitsOutOfRange')
        mk = nft.market
        g = self.seize_gate(mk, t)
        if g:
            raise Refused(g)
        if asset == 'USDC' and not self.w.debt_o(t)[3]:
            raise Refused('DebtPriceStale')
        self._acc(a, t)
        D = a.debt[asset]
        if D <= 1e-12:
            raise Refused('NoDebt')
        s = P.SLIPPAGE_ALLOWANCE
        V = units * self.served(mk, t)
        cap = V * (1 - s)
        pd = self.debt_price(asset, t)
        X = min(D, cap / (pd * (1 + P.MAX_FLASH_FEE)))
        if X <= 0:
            raise Refused('DeleverageTooSmall')
        phi = X * P.FLASH_PREMIUM if X <= P.FLASH_LIQUIDITY[asset] else None
        if phi is None:
            raise Refused('FlashLiquidityShort')
        G = (X + phi) * pd          # flash principal plus premium (REP-018)
        self.m.check('flash premium within maxFlashFeeBps (REP-018, LIQ-030)', phi <= X * P.MAX_FLASH_FEE + 1e-12, wallet)
        R = 0.0
        for tok in P.MARKETS[mk]['tokens']:
            cost = self.leg_cost(tok, asset, t, V / 2.0, mk)
            if cost > s:
                raise Refused('MinOutNotMet')
            R += V / 2.0 * (1 - cost)
        if R < G:
            raise Refused('DeleverageShortfall')
        return dict(rec=rec, X=X, G=G, R=R, V=V, units=units, mk=mk)

    def repay_with_collateral(self, wallet, nft, units, asset, t, min_hf=0.0):
        q = self.deleverage_quote(wallet, nft, units, asset, t)
        a = self.accounts[wallet]
        rec = q['rec']
        if a.debt[asset] - q['X'] > 1e-9 or any(a.debt[k] > 1e-9 for k in P.DEBT_ASSETS if k != asset):
            hf0 = self.hf(a, t)
            hf1 = self.hf(a, t, extra_coll={q['mk']: -units}, extra_debt={asset: -q['X']})
            if hf1 < hf0 - 1e-12 or hf1 < (min_hf or 0.0):
                raise Refused('HealthFactorTooLow')
        a.debt[asset] -= q['X']
        if a.debt[asset] < 1e-9:
            a.debt[asset] = 0.0
        a.repaid[asset] += q['X']
        self.drawn[asset] = max(0.0, self.drawn[asset] - q['X'])
        self._debit(a, rec, units)
        nft.liq -= units
        nft.removed += units
        if rec.credited <= 1e-12:
            a.records[rec.market].remove(rec)
            nft.in_vault = False
        self.m.check('repay with collateral: conversion covers the flash loan (SPEC-LIQ-020)', q['R'] - q['G'] >= -1e-9, wallet)
        return dict(repaid=q['X'] * self.debt_price(asset, t), gho_out=q['R'] - q['G'], loss=q['V'] - q['R'])

    # ----------------------------------------------------------------- liquidation (3.5)
    def seize_gate(self, mk, t):
        """LPVaultSwap's gate on the seized market (Q-247): not Cached, Expired, in a
        disagreement, or served by an alternate past its borrow age (REQ-ORACLE-090)."""
        state, reason, _, lgate, _ = self.w.o(mk, t)
        if state >= 2:
            return 'StalePrice(Cached/Expired)'
        if lgate != 'ok':
            return 'StalePrice(%s)' % lgate
        return None

    def debt_gate(self, asset, t):
        if asset == 'USDC' and not self.w.debt_o(t)[3]:
            return 'DebtPriceStale'
        return None

    def liquidation_gate(self, a, t, hf):
        """None when some (fresh seized market, fresh repaid reserve) pair exists, else the reason."""
        for mk in a.markets():
            if self.w.o(mk, t)[4] and hf >= P.GRACE_HF:
                return 'GraceHealthFactor'
        mks = [mk for mk in a.markets() if self.seize_gate(mk, t) is None]
        debts = [k for k in P.DEBT_ASSETS if a.debt[k] > 0 and self.debt_gate(k, t) is None]
        if mks and debts:
            return None
        if not mks:
            return self.seize_gate(a.markets()[0], t) if a.markets() else 'NoCollateral'
        return 'DebtPriceStale'

    @staticmethod
    def bonus(hf):
        min_lb = 1 + (P.MAX_LB - 1) * P.LB_FACTOR
        if hf <= P.HF_FOR_MAX_BONUS:
            return P.MAX_LB
        return min_lb + (P.MAX_LB - min_lb) * (1 - hf) / (1 - P.HF_FOR_MAX_BONUS)

    def size_liquidation(self, a, mk, asset, t):
        """Aave V4 sizing at served prices: target HF, bonus curve, $1,000 dust rule."""
        hf = self.hf(a, t)
        lb = self.bonus(hf)
        cf = P.MARKETS[mk]['cf']
        Dtot = self.debt_value(a, t)
        pdebt = self.debt_price(asset, t)
        to_target = Dtot * (P.TARGET_HF - hf) / (P.TARGET_HF - lb * cf)
        debt_val = a.debt[asset] * pdebt
        repay = min(to_target, debt_val)
        if debt_val - repay < P.DUST_USD:
            repay = debt_val
        price = self.served(mk, t)
        coll = a.credited(mk) * price
        seize = repay * lb
        if seize > coll or (coll - seize < P.DUST_USD and repay < debt_val - 1e-9):
            seize = coll
            repay = min(coll / lb, debt_val)
            if repay >= debt_val - 1e-9:
                seize = min(repay * lb, coll)
        return dict(hf=hf, lb=lb, repay=repay, seize=seize, price=price, pdebt=pdebt)

    def leg_cost(self, tok, asset, t, usd, mk):
        return self.leg_info(tok, asset, t, usd, mk)[0]

    def leg_info(self, tok, asset, t, usd, mk):
        """(cost, primaryFailed) of converting one unwound leg into the repaid debt asset (Q-358):
        a leg in the debt asset needs no swap; a GHO leg sold for USDC pays the GSM fee; any other
        token uses its route model."""
        if tok == asset:
            return 0.0, False
        if tok == 'GHO':
            return P.GHO_TO_USDC_COST, False
        return self.w.route_info(tok, t, usd, mk)

    def convert(self, mk, t, V, s_leg, asset='GHO'):
        """Per-leg conversion into the debt asset at minOut = Vleg(1 - sLeg) - allowance/n (SPEC-LIQ-018).
        Returns (R, legs_ok, sell_primary_failed)."""
        R, ok, pf = 0.0, True, False
        n = len(P.MARKETS[mk]['tokens'])
        for tok in P.MARKETS[mk]['tokens']:
            leg = V / n
            cost, prim_failed = self.leg_info(tok, asset, t, leg, mk)
            pf = pf or prim_failed
            if leg * (1 - cost) < leg * (1 - s_leg) - P.FLOOR_ROUNDING_GHO / n:
                ok = False
            R += leg * (1 - cost)
        return R, ok, pf

    def apply_seizure(self, a, mk, asset, sz, t):
        self._acc(a, t)
        units = sz['seize'] / sz['price']
        a.debt[asset] -= sz['repay'] / sz['pdebt']
        if a.debt[asset] < 1e-9:
            a.debt[asset] = 0.0
        a.liquidated[asset] += sz['repay'] / sz['pdebt']
        self.drawn[asset] = max(0.0, self.drawn[asset] - sz['repay'] / sz['pdebt'])
        left = units
        touched = 0
        for rec in list(a.records[mk]):   # largest-first (Q-194)
            if left <= 1e-12:
                break
            take = min(rec.credited, left)
            if take <= 0:
                continue
            self._release_charge(rec, take)
            rec.credited -= take
            rec.rescue = min(rec.rescue, rec.credited)
            rec.nft.liq -= take
            rec.nft.seized += take
            left -= take
            touched += 1
        a.records[mk].sort(key=lambda r: (-r.credited, r.id))
        m = self.mk[mk]
        m['supply'] -= units - left
        m['credited'] -= units - left
        deficit = 0.0
        if not a.markets() and a.has_debt():
            for k in P.DEBT_ASSETS:
                if a.debt[k] > 0:
                    deficit += a.debt[k] * self.debt_price(k, t)
                    self.deficit[k] += a.debt[k]
                    sd = self.spoke_deficit.setdefault(a.spoke, {})
                    sd[k] = sd.get(k, 0.0) + a.debt[k]
                    a.written_off[k] += a.debt[k]
                    self.drawn[k] = max(0.0, self.drawn[k] - a.debt[k])
                    a.debt[k] = 0.0
        return touched, deficit, units - left
