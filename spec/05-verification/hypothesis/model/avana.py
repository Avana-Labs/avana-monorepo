# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Avana reference model, final design (Q-001…Q-278): MarketRegistry (pause state and reason, market status,
circuit breakers, address freeze, debt reserves), ParameterStore values, vault tokens (Adapter-only mint and burn,
recipient check, proxy registry), Collateralization (records, credit, rescue units, exposure counters, reconcile,
pending balance), LPVault (custody), AaveAdapter (pledge, borrow, repay, withdrawal, partial removal, re-credit,
repay with collateral, backing check), RiskModule (checkPledge, pre-checks, rescue-excluded health check), the
Coverage Spokes per debt asset and the PayoutEscrow (failed payouts only), on top of the Aave V4 and Uniswap v3
models. LPVaultSwap lives in swap.py.

Every public flow runs as one atomic transaction (`System.tx`): on any revert the whole state is restored, as on-chain.
Flows return a dict of measured amounts for the tests.
"""
import copy

from .mathlib import WAD, RAY, BPS, U120, U128, U256, cdiv, mul_div, Overflow, to_value
from .tokens import Ledger, InsufficientBalance, ZeroTransfer, TokenBlocked, DECIMALS
from .uniswap import NFPM, Pool, sqrt_price_from_usd, position_amounts
from .oracle import Feed, TokenFeeds, LPOracle, DebtOracle, LIVE, DRIFTING, CACHED, EXPIRED
from .aave import Hub, Spoke, Asset, SpokeData, Reserve, AaveError, MAX_CAP
from .params import Params, DAY, HOUR
from .swap import SwapMixin

from .const import *  # noqa: F401,F403
from .const import (GHO, USDC_DEBT, HUB, LPVAULT, COLL, ADAPTER, SWAP, FLASH_SOURCE, DEX, ARB, FAUCET_TAG,
                    ESCROW, LEND_SPOKE, COV, CDP, TIER2, GHO_RID, USDC_RID, DEBT_RIDS, NONE, FROZEN, PAUSED, GENERAL,
                    MINT_PATH_SUSPECT, GUARDIANS, FEE_RECIPIENT, REVERTS, AvanaError, need)


class Clock:
    def __init__(self, now):
        self.now = now


class Market:
    def __init__(self, idx, t0, t1, spacing):
        self.idx, self.t0, self.t1 = idx, t0, t1
        self.d0, self.d1 = DECIMALS[t0], DECIMALS[t1]
        assert (self.d0 + self.d1) % 2 == 0
        self.d = (self.d0 + self.d1) // 2                # SPEC-ORC-005
        self.spacing = spacing
        self.vt = f"vt{idx}"
        self.rid = idx + 2
        self.aid = self.vt
        self.pool = None
        self.oracle = None
        self.status = "Active"                          # MarketRegistry status (Q-227): Active / Offboarding
        self.route_primary_up = True
        self.route_backup_up = True
        self.reports = []                               # floor-failure reports: monitoring alerts (Q-399)
        self.last_routed = -10 ** 12
        self.registry = set()                           # vault-token proxy registry (addValidProxy, Q-224)
        self.manual_breaker = False


class DebtDef:
    """A debt reserve of a Borrow Spoke (Q-233, Q-237): asset, decimals and price source. Liquidations flash-borrow
    the asset itself and settle in it, so a debt reserve has no buy or sell-back route."""

    def __init__(self, rid, asset, decimals, oracle=None):
        self.rid, self.asset, self.decimals, self.oracle = rid, asset, decimals, oracle
        self.manual_breaker = {}                        # spoke -> manual trip


class Record:
    def __init__(self, token_id, depositor, proxy, spoke, market, credited, charge, slice_charge, rescue_units, t):
        self.token_id, self.depositor, self.proxy, self.spoke, self.market = token_id, depositor, proxy, spoke, market
        self.credited = credited
        self.orig_units = credited                      # SPEC-BACK-005 fixed basis
        self.orig_charge = charge
        self.charge = charge
        self.slice_charge = slice_charge
        self.rescue_units = rescue_units                # SPEC-BACK-014
        self.status = "active"
        self.created = t


class Proxy:
    def __init__(self, wallet, spoke):
        self.wallet, self.spoke = wallet, spoke
        self.addr = f"proxy:{wallet}@{spoke}"           # CREATE2 salt keccak(wallet, spoke): one per pair (Q-225)
        self.nonce = 0


class System(SwapMixin):
    TOKENS = ("USDC", "USDT", "DAI", "GHO")

    def __init__(self, params=None, markets=(("USDC", "USDT", 1), ("DAI", "USDC", 1), ("GHO", "DAI", 10)),
                 prices=None, start=1_700_000_000, spokes=(CDP,)):
        self.p = params or Params()
        self.clock = Clock(start)
        self.ledger = Ledger()
        self.nfpm = NFPM(self.ledger)
        self.hub = Hub(self.clock, self.ledger, HUB)
        self.prices = dict(prices or {t: 10 ** 8 for t in self.TOKENS})
        self.lock = False
        self.feeds = {}
        for t in self.TOKENS:
            mk = lambda hb: Feed(self.prices[t], start, hb, self.p)
            self.feeds[t] = TokenFeeds(t, mk(self.p.heartbeat), mk(self.p.alt_heartbeat), mk(self.p.heartbeat))
        self.debt_feeds = TokenFeeds("USDC", Feed(self.prices["USDC"], start, self.p.heartbeat, self.p),
                                     Feed(self.prices["USDC"], start, self.p.alt_heartbeat, self.p),
                                     Feed(self.prices["USDC"], start, self.p.heartbeat, self.p), stable=False)
        self.debt_oracle = DebtOracle("USDC", self.debt_feeds, self.p, start)
        self.debts = {GHO_RID: DebtDef(GHO_RID, GHO, 18), USDC_RID: DebtDef(USDC_RID, USDC_DEBT, 6, self.debt_oracle)}
        self.approved = {CDP: {GHO_RID, USDC_RID}, TIER2: {GHO_RID}}
        self.markets = []
        self.proxies = {}                 # (wallet, spoke) -> Proxy
        self.proxy_of_addr = {}           # proxy address -> Proxy
        self.records = {}
        self.keepers = {"keeper0", "keeper1", "keeper2", "standby"}
        self.pause_state, self.pause_reason = NONE, None
        self.frozen_addresses = set()
        self.freeze_log = {}              # guardian -> [timestamps]
        self.config_drift = False         # Aave risk configuration drift (Q-270)
        self.hostile_swap = False         # an LPVaultSwap version that never settles (Q-201)
        self.counters_regular, self.counters_slice, self.counters_token, self.counters_depositor = {}, {}, {}, {}
        self.pending = {}                 # market -> dict(units, amounts {token: raw})
        self.orphan_burned = {}           # ghost: units burned without a debit (Q-257)
        self.unsettled = {}               # ghost: (proxy, market) -> units a faulty LPVaultSwap seized, unreconciled
        self.escrow_claimable, self.escrow_total, self.escrow_credited, self.escrow_claimed = {}, {}, {}, {}
        self.gas_burners = set()
        self.coverage_in = {GHO: 0, USDC_DEBT: 0}
        self.route_haircut = {}           # (market, route) -> bps lost to a sandwich or a manipulated pool on the swap route
        self.last_legs = []
        self.dust = {}                    # ghost: (token, holder) -> tokens sent to an Avana address by plain transfer       # ghost: GHO Coverage Spoke funding by settlePending
        self.settlements = []
        self.deleverages = []
        self.events = []
        self.spokes = {}
        for name in spokes:
            sp = Spoke(self.hub, name, self.price_of, self.p.target_hf, self.p.hf_for_max_bonus, self.p.lb_factor,
                       self.xfer)
            sp.manager = SWAP
            sp.max_user_reserves = self.p.max_user_reserves
            self.spokes[name] = sp
        # --- debt assets on the Hub: Lend Spoke supply (DAO bootstrap, public lenders later) under its supply cap,
        #     Coverage Spoke, Borrow Spoke draws within the credit line (Q-233, Q-236, Q-407)
        for asset, dec, curve in ((GHO, 18, self.p.gho_curve), (USDC_DEBT, 6, self.p.usdc_curve)):
            a = Asset(asset, dec, ir=curve)
            a.last_update = start
            a.spokes = {LEND_SPOKE: SpokeData(add_cap=self.p.lend_supply_cap[asset]), COV[asset]: SpokeData()}
            for name in spokes:
                if (GHO_RID if asset == GHO else USDC_RID) in self.approved[name]:
                    a.spokes[name] = SpokeData(add_cap=0, draw_cap=self.p.credit_line[asset] // 10 ** dec)
            self.hub.assets[asset] = a
            self.ledger.mint(asset, HUB, self.p.bootstrap_supply[asset], f"{asset} DAO bootstrap supply (Lend Spoke)")
            self.hub.add(asset, LEND_SPOKE, self.p.bootstrap_supply[asset])
            self.ledger.mint(asset, HUB, self.p.first_loss[asset], f"{asset} Coverage Spoke funding")
            self.hub.add(asset, COV[asset], self.p.first_loss[asset])
        for name, sp in self.spokes.items():
            sp.add_reserve(Reserve(GHO_RID, GHO, GHO, 18, cf=0, borrowable=True))
            if USDC_RID in self.approved[name]:
                sp.add_reserve(Reserve(USDC_RID, USDC_DEBT, USDC_DEBT, 6, cf=0, borrowable=True))
        # --- external liquidity: swap-route (DEX) inventory and arbitrage capital (no settlement budget, Q-397)
        self.ledger.mint(GHO, DEX, 10 ** 9 * WAD, "DEX inventory")
        for t in self.TOKENS:
            self.ledger.mint(t, ARB, 10 ** 15 * 10 ** DECIMALS[t], "arb capital")
            if t != GHO:
                self.ledger.mint(t, DEX, 10 ** 12 * 10 ** DECIMALS[t], "DEX inventory")
        for i, (a, b, sp) in enumerate(markets):
            self._list_market(i, a, b, sp)

    # ------------------------------------------------------------------ plumbing
    def tx(self, fn, *args, **kw):
        """Run fn atomically. Returns (True, result) or (False, reason) with state restored."""
        snap = copy.deepcopy(self.__dict__, {id(self): self})
        try:
            return True, fn(*args, **kw)
        except REVERTS as e:
            self.__dict__.clear()
            self.__dict__.update(snap)
            return False, f"{type(e).__name__}: {e}"

    def locked(self, fn, *args):
        """The protocol Lock (INV-054): every outer entry point holds it; a reentrant call reverts LockHeld."""
        need(not self.lock, "LockHeld")
        self.lock = True
        try:
            return fn(*args)
        finally:
            self.lock = False

    def now(self):
        return self.clock.now

    def _send(self, token, frm, to, amount):
        """Avana contracts skip a zero-amount transfer (Q-217); returns the amount received (balance delta, Q-271)."""
        if not amount:
            return 0
        b0 = self.ledger.balance(token, to)
        self.xfer(token, frm, to, amount)
        return self.ledger.balance(token, to) - b0

    def is_vault_token(self, token):
        return token.startswith("vt")

    def market_of_vt(self, vt):
        return self.markets[int(vt[2:])]

    def xfer(self, token, frm, to, amount):
        """ERC-20 transfer; vault tokens check only the recipient (Q-224)."""
        if self.is_vault_token(token):
            mk = self.market_of_vt(token)
            need(to in (HUB, ADAPTER, SWAP) or to in mk.registry, f"InvalidRecipient({to})")
        if amount:
            self.ledger.transfer(token, frm, to, amount)

    def vt_mint(self, mk, to, amount):
        """VaultToken.mint: Adapter only; to the Hub, the Adapter or a registered proxy (Q-224)."""
        need(to in (HUB, ADAPTER) or to in mk.registry, "InvalidRecipient")
        self.ledger.mint(mk.vt, to, amount, "adapter mint")

    def vt_burn(self, mk, frm, amount):
        """VaultToken.burn: Adapter only, from any holder, no allowance (Q-224)."""
        self.ledger.burn(mk.vt, frm, amount, "adapter burn")

    def price_of(self, rid):
        """AaveOracle.getReservePrice: GHO fixed $1 (Q-100); USDC through its DebtOracle; vault reserves through
        their LPOracle (Q-247, Q-248)."""
        if rid == GHO_RID:
            return 10 ** 8
        if rid == USDC_RID:
            return self.debt_oracle.latest_answer(self.now())
        return self.markets[rid - 2].oracle.latest_answer(self.now())

    def _list_market(self, i, a, b, spacing):
        m = Market(i, a, b, spacing)
        sp = sqrt_price_from_usd(self.prices[a], self.prices[b], m.d0, m.d1)
        m.pool = Pool(f"{a}/{b}", a, b, m.d0, m.d1, spacing, sp, self.ledger)
        m.oracle = LPOracle(i, self.feeds[a], self.feeds[b], m.pool, self.p, self.now())
        asset = Asset(m.vt, m.d)
        asset.last_update = self.now()
        asset.spokes = {name: SpokeData(add_cap=MAX_CAP, draw_cap=0) for name in self.spokes}
        self.hub.assets[m.aid] = asset
        for sp_ in self.spokes.values():
            sp_.add_reserve(Reserve(m.rid, m.aid, m.vt, m.d, cf=self.p.cf_bps, max_lb=self.p.max_lb_bps, liq_fee=0,
                                    collateral_risk=self.p.collateral_risk_bps, borrowable=False,
                                    receive_shares=False))
        self.ledger.supply.setdefault(m.vt, 0)
        self.markets.append(m)
        self.pending[i] = dict(units=0, amounts={a: 0, b: 0})
        self.orphan_burned[i] = 0
        self.create_position("lp_whale", i, 25 * 10 ** 6 * 10 ** m.d)

    # ------------------------------------------------------------------ views
    def spoke(self, name=CDP):
        return self.spokes[name]

    def proxy(self, wallet, spoke=CDP):
        return self.proxies.get((wallet, spoke))

    def px(self, wallet, spoke=CDP):
        p = self.proxies.get((wallet, spoke))
        return p.addr if p else None

    def debt(self, proxy_addr, rid=GHO_RID, spoke=None):
        sp = self.spokes[spoke or self.proxy_of_addr[proxy_addr].spoke]
        if rid not in sp.reserves:
            return 0
        return sp.user_debt(proxy_addr, rid)

    def hf(self, proxy_addr):
        return self.spokes[self.proxy_of_addr[proxy_addr].spoke].health_factor(proxy_addr)

    def borrow_count(self, proxy_addr):
        return self.spokes[self.proxy_of_addr[proxy_addr].spoke].account_data(proxy_addr)["n_borrow"]

    def account_markets(self, proxy_addr):
        sp = self.spokes[self.proxy_of_addr[proxy_addr].spoke]
        st = sp.st(proxy_addr)
        return [m for m in self.markets if m.rid in st.collateral and sp.up(proxy_addr, m.rid).supplied_shares > 0]

    def account_debts(self, proxy_addr):
        sp = self.spokes[self.proxy_of_addr[proxy_addr].spoke]
        return sorted(sp.st(proxy_addr).borrowing)

    def records_of(self, proxy_addr, m):
        return [r for r in self.records.values() if r.proxy == proxy_addr and r.market == m and r.status == "active"]

    def credited_total(self, m):
        return sum(r.credited for r in self.records.values() if r.market == m and r.status == "active")

    def account_credited(self, proxy_addr, m):
        return sum(r.credited for r in self.records_of(proxy_addr, m))

    def account_rescue(self, proxy_addr, m):
        return sum(r.rescue_units for r in self.records_of(proxy_addr, m))

    def gap(self, m):
        mk = self.markets[m]
        return self.credited_total(m) + self.pending[m]["units"] - self.ledger.supply.get(mk.vt, 0)

    def accepted_price(self, m):
        return self.markets[m].oracle.accepted

    def booking_price(self, m):
        """REQ-RISK-026: min(fresh, accepted); the accepted price alone when there is no fresh price (failed market)."""
        A = self.accepted_price(m)
        fresh = self.markets[m].oracle.evaluate(self.now())["fresh"]
        return fresh if fresh and fresh < A else A

    def borrow_price_of(self, rid):
        """Price of a reserve for the post-action health check (REQ-RISK-059): a vault-token reserve at
        min(served, accepted), every other reserve at its AaveOracle price."""
        p = self.price_of(rid)
        if rid in (GHO_RID, USDC_RID):
            return p
        return min(p, self.accepted_price(rid - 2))

    def vt_value_usd8(self, m, units, price=None):
        price = self.accepted_price(m) if price is None else price
        return units * price // 10 ** self.markets[m].d

    def vt_value_gho(self, m, units, price):
        """SPEC-LIQ-004: V = mulDiv(c·Pc, 10¹⁸, 10^d·Pgho), down."""
        return units * price * 10 ** 18 // (10 ** self.markets[m].d * 10 ** 8)

    def is_protected(self, a):
        return (a in (HUB, LPVAULT, COLL, ADAPTER, SWAP, FLASH_SOURCE, DEX, ESCROW, FEE_RECIPIENT)
                or a in self.proxy_of_addr or a in self.spokes or a in COV.values() or a.startswith("vt"))

    def unfrozen_keepers(self):
        return {k for k in self.keepers if k not in self.frozen_addresses}

    # ------------------------------------------------------------------ setup helpers (not protocol)
    def fund(self, who, token, amount):
        if amount:
            self.ledger.mint(token, who, amount, FAUCET_TAG)

    def create_position(self, owner, m, liq):
        """A wallet mints a full-range position (outside Avana); None when the pool refuses (e.g. a paused token)."""
        def f():
            mk = self.markets[m]
            a0, a1 = position_amounts(mk.pool.sqrt_p, liq, mk.pool.spacing, True)
            self.fund(owner, mk.t0, a0)
            self.fund(owner, mk.t1, a1)
            return self.nfpm.mint(mk.pool, owner, liq)
        ok, r = self.tx(f)
        return r if ok else None

    def set_price(self, token, price, move_pools=True, routes=("primary", "alternate"), new_phase=False):
        """Chainlink publishes a new round on the named routes; the pools follow by arbitrage."""
        self.prices[token] = price
        tf = self.feeds[token]
        for r in routes:
            tf.slots[r].push(price, self.now(), new_phase)
        if token == "USDC":
            for r in routes:
                self.debt_feeds.slots[r].push(price, self.now(), new_phase)
        if tf.standby not in tf.slots.values():
            tf.standby.push(price, self.now())
        if move_pools:
            for mk in self.markets:
                if token in (mk.t0, mk.t1) and not ({mk.t0, mk.t1} & self.ledger.paused):
                    sp = sqrt_price_from_usd(self.prices[mk.t0], self.prices[mk.t1], mk.d0, mk.d1)
                    mk.pool.move_price(sp, ARB)

    def advance(self, dt):
        self.clock.now += dt

    # ------------------------------------------------------------------ MarketRegistry: pause, freeze, breakers
    def freeze(self, caller="emergency_guardian"):
        need(self.pause_state == NONE, "InvalidTransition")
        self.pause_state = FROZEN

    def pause(self, reason=GENERAL, caller="emergency_guardian"):
        need(not (self.pause_state == PAUSED and self.pause_reason == reason), "InvalidTransition")
        self.pause_state, self.pause_reason = PAUSED, reason

    def unpause(self, caller="emergency_guardian"):
        need(self.pause_state == PAUSED, "InvalidTransition")
        self.pause_state, self.pause_reason = NONE, None

    def unfreeze(self, caller="emergency_guardian"):
        need(self.pause_state == FROZEN, "InvalidTransition")
        self.pause_state = NONE

    def freeze_address(self, guardian, account):
        """Q-242: immediate for a freeze guardian, at most 20 per guardian in the contract's 24 one-hour buckets
        (modelled as a continuous 24 h window), never the protected
        set; no keeper floor, so the last unfrozen keeper can be frozen and new borrowing then halts (Q-400)."""
        def f():
            need(guardian in GUARDIANS, "Unauthorized")
            need(not self.is_protected(account), "ProtectedAddress")
            log = [t for t in self.freeze_log.get(guardian, []) if t > self.now() - DAY]
            need(len(log) < self.p.freeze_rate_limit, "FreezeRateLimited")
            self.freeze_log[guardian] = log + [self.now()]
            self.frozen_addresses.add(account)
        return self.tx(f)

    def unfreeze_address(self, account):
        """APPLICATION_ADMIN operation at the normal delay (the timelock wait is modelled in timelock.py)."""
        self.frozen_addresses.discard(account)

    def market_breaker(self, m):
        """Q-399 market breaker on m: manual, oracle or band, pool-share concentration, issuer (SPEC-BRK-001..003)."""
        mk = self.markets[m]
        now = self.now()
        if mk.manual_breaker:
            return "MANUAL"
        if mk.oracle.state(now) != LIVE:
            return "ORACLE"
        if self.ledger.supply.get(mk.vt, 0) * BPS > self.p.pool_share_bps * mk.pool.liquidity:
            return "POOL_SHARE"
        for t in (mk.t0, mk.t1):
            if t in self.ledger.paused or self.ledger.fee_bps.get(t, 0) > 0:
                return "ISSUER"
        return None

    def funded_balance(self, asset):
        return self.hub.preview_remove_by_shares(asset, self.hub.assets[asset].spokes[COV[asset]].added_shares)

    def debt_breaker(self, spoke, rid):
        """Q-399 debt breaker on (spoke, r): manual, oracle, issuer, coverage, deficit above 10,000 GHO
        (SPEC-BRK-003, SPEC-BRK-004)."""
        d = self.debts[rid]
        now = self.now()
        if d.manual_breaker.get(spoke):
            return "MANUAL"
        if d.oracle is not None and not d.oracle.evaluate(now)["borrow_age_ok"]:
            return "ORACLE"
        if d.asset in self.ledger.paused or self.ledger.fee_bps.get(d.asset, 0) > 0:
            return "ISSUER"
        if self.funded_balance(d.asset) < self.p.first_loss_min[d.asset]:
            return "COVERAGE"
        sd = self.hub.assets[d.asset].spokes.get(spoke)
        if sd is not None and sd.deficit_ray > self.p.breaker_deficit_max[d.asset] * RAY:
            return "DEFICIT"
        return None

    def trip_market_breaker(self, m, on=True):
        self.markets[m].manual_breaker = on

    def trip_debt_breaker(self, spoke, rid, on=True):
        self.debts[rid].manual_breaker[spoke] = on

    def use_standby(self, token, slot, debt=False):
        """Q-248: a guardian switches a token's primary or alternate route to its standby at once."""
        def f():
            (self.debt_feeds if debt else self.feeds[token]).use_standby(slot)
        return self.tx(f)

    # ------------------------------------------------------------------ RiskModule
    def _rm(self, cond, err):
        """A faulty RiskModule implementation passes everything; only Aave's own checks bind (SPEC-CF-003)."""
        if not self.p.faulty_risk_module:
            need(cond, err)

    def usd_charge(self, m, L):
        """SPEC-CAP-001: mulDiv(L, max(price8, stressFloorUsd), 10^d, Ceil) at the booking price min(fresh, A)."""
        mk = self.markets[m]
        return cdiv(L * max(self.booking_price(m), self.p.stress_floor_usd8), 10 ** mk.d)

    def restore_booked(self, proxy_addr, m):
        """SPEC-CAP-003: booked USD of market-m collateral that restores the recommended HF 1.10 (Q-398)."""
        sp = self.spokes[self.proxy_of_addr[proxy_addr].spoke]
        ad = sp.account_data(proxy_addr)
        h_o = self.p.recommended_hf
        if ad["tdv_ray"] == 0 or ad["hf"] >= h_o:
            return 0
        cf = sp.reserves[self.markets[m].rid].cf
        if cf == 0:
            return 0
        x = mul_div(h_o - ad["hf"], ad["tdv_ray"], WAD * RAY, up=True)
        usd = mul_div(x, BPS, cf * 10 ** 18, up=True)
        # Booked at the booking price min(fresh, A), divided by the served price at which Aave values the collateral.
        price = self.booking_price(m)
        served = self.markets[m].oracle.latest_answer(self.now())
        return mul_div(usd, max(price, self.p.stress_floor_usd8), served, up=True)

    def hf_ex(self, proxy_addr, price_of=None):
        """SPEC-CF-005: Aave's HF with the account's rescue units valued at zero (rounded against the account);
        `price_of` replaces the AaveOracle prices (the post-action check passes borrow_price_of)."""
        price_of = price_of or self.price_of
        sp = self.spokes[self.proxy_of_addr[proxy_addr].spoke]
        if price_of is not self.price_of:
            orig = sp.price_of
            sp.price_of = price_of
            try:
                return self._hf_ex_at(proxy_addr, sp, price_of)
            finally:
                sp.price_of = orig
        return self._hf_ex_at(proxy_addr, sp, price_of)

    def _hf_ex_at(self, proxy_addr, sp, price_of):
        ad = sp.account_data(proxy_addr)
        hf = ad["hf"]
        E = 0
        for mk in self.markets:
            u = self.account_rescue(proxy_addr, mk.idx)
            if u:
                p = price_of(mk.rid)
                E += mul_div(u * p, sp.reserves[mk.rid].cf * 10 ** 18, 10 ** mk.d * BPS, up=True)
        if E == 0 or ad["tdv_ray"] == 0:
            return hf
        sub = mul_div(E, WAD * RAY, ad["tdv_ray"], up=True)
        return max(0, hf - sub)

    def _post_health_check(self, proxy_addr, min_hf):
        """SPEC-PROXY-001 / SPEC-CF-005 (Q-398): hfEx ≥ max(1.00, optional hard floor (0 = off), minHF), with the
        vault-token collateral valued at min(served, accepted) (REQ-RISK-059: the accepted price bounds borrowing).
        The RiskModule scales hfEx by accepted / served for the account's one market; valuing each market at that
        price is the same value up to the floors (MATH-UO-76b)."""
        need_ = max(WAD, self.p.hard_floor_hf, min_hf)
        h = self.hf_ex(proxy_addr, self.borrow_price_of)
        self._rm(h >= need_, f"HealthFactorTooLow({h}, {need_})")
        return h

    def _pre_check(self, proxy_addr, action, borrow_rid=None):
        """RiskModule.preBorrowCheck / preWithdrawCheck (Q-229, Q-234, Q-238, Q-241, INV-072)."""
        now = self.now()
        pxo = self.proxy_of_addr[proxy_addr]
        sp = self.spokes[pxo.spoke]
        if action == "borrow":
            self._rm(self.pause_state == NONE, f"Paused({self.pause_state})")
        else:
            self._rm(self.pause_state != PAUSED, "Paused")
        self._rm(not self.config_drift, "ConfigDrift")
        self._rm(len(self.unfrozen_keepers()) > 0, "LiquidationHalted")
        for mk in self.account_markets(proxy_addr):
            st = mk.oracle.poke(now)
            e = mk.oracle.evaluate(now)
            self._rm(st == LIVE, f"MarketNotLive({mk.idx}, {st})")
            self._rm(e["borrow_age_ok"], f"PriceTooOld({mk.idx})")
            r = sp.reserves[mk.rid]
            self._rm(not r.paused, f"AaveReservePaused({mk.rid})")
            if action == "borrow":
                self._rm(not r.frozen, f"AaveReserveFrozen({mk.rid})")
                self._rm(mk.status == "Active", f"MarketOffboarding({mk.idx})")
            self._rm(self.hub.shares_equal_assets(mk.aid), "HubSharesNotAssets")
            b = self.market_breaker(mk.idx)
            self._rm(b is None, f"BreakerTripped({mk.idx}, {b})")
        rids = set(self.account_debts(proxy_addr)) | ({borrow_rid} if borrow_rid is not None else set())
        for rid in sorted(rids):
            d = self.debts[rid]
            if d.oracle is not None:
                d.oracle.poke(now)
                self._rm(d.oracle.evaluate(now)["borrow_age_ok"], f"DebtPriceTooOld({rid})")
            self._rm(not sp.reserves[rid].paused, f"DebtReservePaused({rid})")
            b = self.debt_breaker(pxo.spoke, rid)
            self._rm(b is None, f"DebtBreakerTripped({rid}, {b})")

    def _check_pledge(self, wallet, spoke, proxy_addr, m, L, has_debt):
        """RiskModule.checkPledge (SPEC-CAP-001..005, Q-230, Q-252): returns (charge, slice, rescue, rescueUnits)."""
        now = self.now()
        mk = self.markets[m]
        sp = self.spokes[spoke]
        hf = sp.health_factor(proxy_addr) if proxy_addr else 2 ** 256 - 1
        st = mk.oracle.poke(now)
        c = self.usd_charge(m, L)
        restore = self.restore_booked(proxy_addr, m) if (proxy_addr and has_debt) else 0
        eligible = has_debt and hf < self.p.recommended_hf
        rescue = eligible and c <= restore
        # stops that rescue top-ups pass (Q-227, Q-241, Q-242, Q-252)
        need(not (self.pause_state == PAUSED and self.pause_reason == MINT_PATH_SUSPECT), "Paused(MintPathSuspect)")
        if not rescue:
            need(wallet not in self.frozen_addresses, "AddressFrozen")
            need(self.pause_state != PAUSED, "Paused(General)")
            need(self.pause_state != FROZEN or has_debt, "Frozen")
            b = self.market_breaker(m)
            if st in (LIVE, DRIFTING) and b == "ORACLE":
                b = None                      # the price-state test below is the oracle gate for pledges
            self._rm(b is None, f"BreakerTripped({m}, {b})")
        if not has_debt:
            self._rm(not self.config_drift, "ConfigDrift")
            for rid in self.approved[spoke]:
                self._rm(not sp.reserves[rid].paused, f"DebtReservePaused({rid})")
        self._rm(mk.status == "Active", "MarketOffboarding")
        self._rm(st in ((LIVE, DRIFTING) if has_debt else (LIVE,)), f"PriceState({st})")
        self._rm(self.hub.shares_equal_assets(mk.aid), "HubSharesNotAssets")
        pledge_usd = L * self.booking_price(m) // 10 ** mk.d
        floor_ = min(self.p.min_pledge_usd, self.p.rescue_min_pledge_usd) if rescue else self.p.min_pledge_usd
        self._rm(pledge_usd >= floor_, f"BelowMinPledge({pledge_usd}, {floor_})")
        if not rescue:
            supply = self.ledger.supply.get(mk.vt, 0)
            self._rm((supply + L) * BPS <= self.p.pool_share_bps * mk.pool.liquidity, "PoolShareExceeded")
        R, S = self.counters_regular.get(m, 0), self.counters_slice.get(m, 0)
        room = max(0, self.p.cap_market_usd - R)
        if eligible:
            sl = max(0, c - room)
            self._rm(S + sl <= self.p.topup_slice_usd, "CapExceeded(SLICE)")
            self._rm(sl <= restore, "SliceAboveRestore")
        else:
            sl = 0
            self._rm(c <= room, "CapExceeded(MARKET)")
        for t in (mk.t0, mk.t1):
            self._rm(self.counters_token.get(t, 0) + c - sl <= self.p.cap_token_usd, f"CapExceeded(TOKEN {t})")
        self._rm(self.counters_depositor.get(wallet, 0) + c - sl <= self.p.cap_depositor_usd, "CapExceeded(DEPOSITOR)")
        need(c < 2 ** 128 and sl <= c, "InvalidCharge")
        ru = L if rescue else (mul_div(L, sl, c, up=True) if sl > 0 else 0)
        return c, sl, rescue, ru

    def _book(self, m, wallet, c, sl):
        mk = self.markets[m]
        self.counters_regular[m] = self.counters_regular.get(m, 0) + c - sl
        self.counters_slice[m] = self.counters_slice.get(m, 0) + sl
        for t in (mk.t0, mk.t1):
            self.counters_token[t] = self.counters_token.get(t, 0) + c
        self.counters_depositor[wallet] = self.counters_depositor.get(wallet, 0) + c

    def _release(self, rec, exited):
        """SPEC-BACK-005: remaining = ceil(V0 × remaining / U0); slice released first; saturating counters; rescue
        units capped at credited (SPEC-BACK-014)."""
        remaining = rec.credited - exited
        rem_charge = cdiv(rec.orig_charge * remaining, rec.orig_units) if rec.orig_units else 0
        released = rec.charge - rem_charge
        m, mk = rec.market, self.markets[rec.market]
        from_slice = min(released, self.counters_slice.get(m, 0))
        self.counters_slice[m] = self.counters_slice.get(m, 0) - from_slice
        self.counters_regular[m] = max(0, self.counters_regular.get(m, 0) - (released - from_slice))
        rs = min(released, rec.slice_charge)
        rec.charge, rec.slice_charge = rem_charge, rec.slice_charge - rs
        for t in (mk.t0, mk.t1):
            self.counters_token[t] = max(0, self.counters_token.get(t, 0) - released)
        self.counters_depositor[rec.depositor] = max(0, self.counters_depositor.get(rec.depositor, 0) - released)
        rec.credited = remaining
        rec.rescue_units = min(rec.rescue_units, rec.credited)
        return released

    # ------------------------------------------------------------------ backing (Q-224, Q-257)
    def _backing_check(self, m, gap_before):
        mk = self.markets[m]
        supply = self.ledger.supply.get(mk.vt, 0)
        cp = self.credited_total(m) + self.pending[m]["units"]
        need(supply <= cp and cp - supply == gap_before, f"BackingMismatch({supply}, {cp})")

    # ------------------------------------------------------------------ Collateralization: reconcile, debit
    def _reconcile(self, proxy_addr, m, S=None):
        """SPEC-BACK-011: shortfall = accountCredited − S moves into the pending balance (largest first)."""
        mk = self.markets[m]
        if not self.hub.shares_equal_assets(mk.aid):
            return []
        sp = self.spokes[self.proxy_of_addr[proxy_addr].spoke]
        S = sp.up(proxy_addr, mk.rid).supplied_shares if S is None else S
        short = self.account_credited(proxy_addr, m) - S
        if short <= 0:
            return []
        debits = self._allocate_seizure(proxy_addr, m, short)
        for tid, d in debits:
            self._release(self.records[tid], d)
            got = self._unwind(tid, d, COLL)
            for t, a in got.items():
                self.pending[m]["amounts"][t] += a
        self.pending[m]["units"] += short
        self.unsettled[(proxy_addr, m)] = self.unsettled.get((proxy_addr, m), 0) - short
        self.events.append(("SeizureReconciled", proxy_addr, m, short))
        return debits

    def _unwind(self, tid, units, recipient, min0=0, min1=0):
        """LPVault: decreaseLiquidity then principal-capped collect, received measured by balance delta
        (SPEC-BACK-008, Q-271)."""
        mk = next(x for x in self.markets if x.pool is self.nfpm.positions[tid].pool)
        x0, x1 = self.nfpm.decrease_liquidity(LPVAULT, tid, units, min0, min1)
        b0, b1 = self.ledger.balance(mk.t0, recipient), self.ledger.balance(mk.t1, recipient)
        if x0 or x1:
            c0, c1 = self.nfpm.collect(LPVAULT, tid, recipient, x0, x1)
            need(c0 <= x0 and c1 <= x1, "CollectAboveRemoved")
        return {mk.t0: self.ledger.balance(mk.t0, recipient) - b0, mk.t1: self.ledger.balance(mk.t1, recipient) - b1}

    def _allocate_seizure(self, proxy_addr, m, units):
        """SPEC-BACK-006: largest credited first, ties by lowest record ID; only the last record is partial."""
        recs = sorted(self.records_of(proxy_addr, m), key=lambda r: (-r.credited, r.token_id))
        out, left = [], units
        for r in recs:
            if left == 0:
                break
            d = min(left, r.credited)
            if d > 0:
                out.append((r.token_id, d))
                left -= d
        need(left == 0, "SeizureExceedsCredit")
        return out

    # ------------------------------------------------------------------ AaveAdapter: pledge and re-credit
    def pledge(self, wallet, m, token_id, spoke=CDP, deadline=None):
        return self.tx(self.locked, self._pledge, wallet, m, token_id, spoke, deadline)

    def _pledge(self, wallet, m, token_id, spoke, deadline):
        now = self.now()
        need(deadline is None or deadline >= now, "DeadlineExpired")
        mk = self.markets[m]
        sp = self.spokes[spoke]
        pos = self.nfpm.positions.get(token_id)
        need(pos is not None and pos.owner == wallet, "NotTokenOwner")
        need(wallet not in (LPVAULT, COLL), "InvalidDepositor")                 # Q-258
        need(pos.pool is mk.pool, "PoolMismatch")
        pxo = self.proxies.get((wallet, spoke))
        has_debt = pxo is not None and sp.account_data(pxo.addr)["n_borrow"] > 0
        L = pos.liquidity
        need(0 < L <= U120, "InvalidLiquidity")
        c, sl, rescue, ru = self._check_pledge(wallet, spoke, pxo.addr if pxo else None, m, L, has_debt)
        if pxo is None:
            need(wallet not in self.frozen_addresses, "AddressFrozen")             # no proxy for a frozen wallet
            pxo = Proxy(wallet, spoke)
            self.proxies[(wallet, spoke)] = pxo
            self.proxy_of_addr[pxo.addr] = pxo
            self.events.append(("UserProxyCreated", wallet, spoke, pxo.addr))
        if pxo.addr not in mk.registry:
            mk.registry.add(pxo.addr)                                               # addValidProxy
        gap0 = self.gap(m)
        self.nfpm.transfer_from(LPVAULT, wallet, LPVAULT, token_id)                 # LPVault.receiveNft
        self._book(m, wallet, c, sl)
        self.records[token_id] = Record(token_id, wallet, pxo.addr, spoke, m, L, c, sl, ru, now)
        sh0 = sp.up(pxo.addr, mk.rid).supplied_shares
        self.vt_mint(mk, pxo.addr, L)
        sp.supply(pxo.addr, mk.rid, L, pxo.addr)
        sp.set_using_as_collateral(pxo.addr, mk.rid, True, pxo.addr)
        need(sp.up(pxo.addr, mk.rid).supplied_shares - sh0 == L, "SupplyIncomplete")
        self._backing_check(m, gap0)
        self.events.append(("CollateralPledged", wallet, token_id, L))
        return dict(L=L, charge=c, slice=sl, rescue=rescue, rescue_units=ru, proxy=pxo.addr, has_debt=has_debt)

    def recredit(self, wallet, token_id, spoke=CDP, deadline=None):
        return self.tx(self.locked, self._recredit, wallet, token_id, spoke, deadline)

    def _recredit(self, wallet, token_id, spoke, deadline):
        """Q-254: credit liquidity added to a pledged NFT as a top-up of exactly live − credited."""
        need(deadline is None or deadline >= self.now(), "DeadlineExpired")
        rec = self.records.get(token_id)
        pxo = self.proxies.get((wallet, spoke))
        need(rec is not None and rec.status == "active" and pxo is not None and rec.depositor == wallet
             and rec.proxy == pxo.addr, "NotDepositor")
        m, mk, sp = rec.market, self.markets[rec.market], self.spokes[spoke]
        self._reconcile(pxo.addr, m)
        added = self.nfpm.positions[token_id].liquidity - rec.credited
        need(added > 0, "NothingToCredit")
        need(rec.credited + added <= U120, "LiquidityAboveBound")
        has_debt = sp.account_data(pxo.addr)["n_borrow"] > 0
        c, sl, rescue, ru = self._check_pledge(wallet, spoke, pxo.addr, m, added, has_debt)
        gap0 = self.gap(m)
        self._book(m, wallet, c, sl)
        rec.orig_units = rec.credited + added                                      # SPEC-BACK-013 rebase
        rec.orig_charge = rec.charge + c
        rec.charge = rec.orig_charge
        rec.slice_charge += sl
        rec.credited += added
        rec.rescue_units += ru
        sh0 = sp.up(pxo.addr, mk.rid).supplied_shares
        self.vt_mint(mk, pxo.addr, added)
        sp.supply(pxo.addr, mk.rid, added, pxo.addr)
        sp.set_using_as_collateral(pxo.addr, mk.rid, True, pxo.addr)
        need(sp.up(pxo.addr, mk.rid).supplied_shares - sh0 == added, "SupplyIncomplete")
        self._backing_check(m, gap0)
        return dict(added=added, charge=c, slice=sl, rescue=rescue, rescue_units=ru)

    # ------------------------------------------------------------------ borrow
    def borrow(self, wallet, amount, rid=GHO_RID, spoke=CDP, receiver=None, deadline=None, min_hf=0, nonce=None):
        return self.tx(self.locked, self._borrow, wallet, amount, rid, spoke, receiver, deadline, min_hf, nonce)

    def _borrow(self, wallet, amount, rid, spoke, receiver, deadline, min_hf, nonce):
        now = self.now()
        need(deadline is None or deadline >= now, "DeadlineExpired")
        pxo = self.proxies.get((wallet, spoke))
        need(pxo is not None, "NoProxy")
        nonce = pxo.nonce if nonce is None else nonce
        need(nonce == pxo.nonce, "BadNonce")
        pxo.nonce += 1
        receiver = receiver or wallet
        need(amount > 0, "ZeroAmount")
        need(wallet not in self.frozen_addresses, "AddressFrozen")
        need(receiver not in self.frozen_addresses and not self.is_protected(receiver), "InvalidReceiver")
        self._rm(rid in self.approved[spoke], "DebtReserveNotApproved")
        sp = self.spokes[spoke]
        need(rid in sp.reserves, "ReserveNotListed")
        self._pre_check(pxo.addr, "borrow", rid)
        asset = DEBT_RIDS[rid]
        b0 = self.ledger.balance(asset, pxo.addr)
        sp.borrow(pxo.addr, rid, amount, pxo.addr)
        got = self.ledger.balance(asset, pxo.addr) - b0
        h = self._post_health_check(pxo.addr, min_hf)
        recv = self._send(asset, pxo.addr, receiver, got)
        return dict(hf=sp.health_factor(pxo.addr), hf_ex=h, debt=sp.user_debt(pxo.addr, rid), received=recv)

    # ------------------------------------------------------------------ repay (never reads the registry)
    def repay(self, wallet, max_spend, rid=GHO_RID, spoke=CDP, repay_all=False, deadline=None, payer=None):
        return self.tx(self.locked, self._repay, wallet, max_spend, rid, spoke, repay_all, deadline, payer)

    def _repay(self, wallet, max_spend, rid, spoke, repay_all, deadline, payer):
        """REP-002..010 (Q-212, Q-260, Q-269, Q-271): any payer; zero debt returns 0; repay-all pulls the cap and
        refunds the unused part; amounts measured by balance delta."""
        payer = payer or wallet
        pxo = self.proxies.get((wallet, spoke))
        need(pxo is not None, "NoProxy")
        need(deadline is None or deadline >= self.now(), "DeadlineExpired")
        sp = self.spokes[spoke]
        D = sp.user_debt(pxo.addr, rid) if rid in sp.reserves else 0
        if D == 0:
            return dict(paid=0, debt=0, refund=0, pulled=0)
        if repay_all:
            need(D <= max_spend, f"RepayExceedsMax({D}, {max_spend})")
            x = max_spend
        else:
            need(max_spend > 0, "ZeroAmount")
            x = min(max_spend, D)
        asset = DEBT_RIDS[rid]
        b_before = self.ledger.balance(asset, pxo.addr)
        received = self._send(asset, payer, pxo.addr, x)
        g0 = self.ledger.balance(asset, pxo.addr)
        sp.repay(pxo.addr, rid, received, pxo.addr)
        spent = g0 - self.ledger.balance(asset, pxo.addr)
        refund = self._send(asset, pxo.addr, payer, received - spent)
        need(self.ledger.balance(asset, pxo.addr) == b_before, "BalanceDeltaMismatch")
        if repay_all:
            need(sp.user_debt(pxo.addr, rid) == 0, "DebtRemaining")
        self.events.append(("Repaid", payer, wallet, rid, spent))
        return dict(paid=spent, debt=sp.user_debt(pxo.addr, rid), refund=refund, pulled=x, received=received)

    # ------------------------------------------------------------------ withdrawal, partial removal
    def withdraw(self, wallet, token_id, spoke=CDP, deadline=None, min_hf=0):
        return self.tx(self.locked, self._withdraw, wallet, token_id, spoke, deadline, min_hf)

    def _withdraw(self, wallet, token_id, spoke, deadline, min_hf):
        need(deadline is None or deadline >= self.now(), "DeadlineExpired")
        rec = self.records.get(token_id)
        pxo = self.proxies.get((wallet, spoke))
        need(rec is not None and rec.status == "active" and pxo is not None and rec.depositor == wallet
             and rec.proxy == pxo.addr, "NotDepositor")
        m, mk, sp = rec.market, self.markets[rec.market], self.spokes[spoke]
        gap0 = self.gap(m)
        reconciled = self._reconcile(pxo.addr, m)
        units = rec.credited
        has_debt = sp.account_data(pxo.addr)["n_borrow"] > 0          # Q-260: debt-free read from Aave only
        if units > 0:
            if has_debt:
                need(wallet not in self.frozen_addresses, "AddressFrozen")
                self._pre_check(pxo.addr, "withdraw")
            b0 = self.ledger.balance(mk.vt, pxo.addr)
            sp.withdraw(pxo.addr, mk.rid, units, pxo.addr)
            need(self.ledger.balance(mk.vt, pxo.addr) - b0 == units, "WithdrawIncomplete")
            if sp.up(pxo.addr, mk.rid).supplied_shares == 0:
                sp.set_using_as_collateral(pxo.addr, mk.rid, False, pxo.addr)
            self.vt_burn(mk, pxo.addr, units)
        self._release(rec, rec.credited)
        rec.status = "closed"
        if units > 0 and has_debt:
            self._post_health_check(pxo.addr, min_hf)
        self.nfpm.transfer_from(LPVAULT, LPVAULT, rec.depositor, token_id)
        self._backing_check(m, gap0 + 0)
        self.events.append(("CollateralReleased", wallet, token_id, units))
        return dict(units=units, had_debt=has_debt, reconciled=reconciled)

    def remove_liquidity(self, wallet, token_id, units, spoke=CDP, min0=0, min1=0, deadline=None, min_hf=0):
        return self.tx(self.locked, self._remove_liquidity, wallet, token_id, units, spoke, min0, min1, deadline,
                       min_hf)

    def _remove_liquidity(self, wallet, token_id, units, spoke, min0, min1, deadline, min_hf):
        """Q-254: remove 0 < units < credited; principal to the depositor; checks of a withdraw-with-debt."""
        need(deadline is None or deadline >= self.now(), "DeadlineExpired")
        rec = self.records.get(token_id)
        pxo = self.proxies.get((wallet, spoke))
        need(rec is not None and rec.status == "active" and pxo is not None and rec.depositor == wallet
             and rec.proxy == pxo.addr, "NotDepositor")
        m, mk, sp = rec.market, self.markets[rec.market], self.spokes[spoke]
        gap0 = self.gap(m)
        self._reconcile(pxo.addr, m)
        need(0 < units < rec.credited, "InvalidUnits")
        has_debt = sp.account_data(pxo.addr)["n_borrow"] > 0
        if has_debt:
            need(wallet not in self.frozen_addresses, "AddressFrozen")
            self._pre_check(pxo.addr, "withdraw")
            left_usd = (rec.credited - units) * self.accepted_price(m) // 10 ** mk.d
            self._rm(left_usd >= self.p.min_pledge_usd, "RecordBelowMinPledge")
        b0 = self.ledger.balance(mk.vt, pxo.addr)
        sp.withdraw(pxo.addr, mk.rid, units, pxo.addr)
        need(self.ledger.balance(mk.vt, pxo.addr) - b0 == units, "WithdrawIncomplete")
        self.vt_burn(mk, pxo.addr, units)
        self._release(rec, units)
        got = self._unwind(token_id, units, wallet, min0, min1)
        if has_debt:
            self._post_health_check(pxo.addr, min_hf)
        self._backing_check(m, gap0)
        return dict(units=units, got=got, had_debt=has_debt)

    # ------------------------------------------------------------------ fees (direct LPVault call)
    def collect_fees(self, wallet, token_id):
        return self.tx(self.locked, self._collect_fees, wallet, token_id)

    def _collect_fees(self, wallet, token_id):
        rec = self.records.get(token_id)
        need(rec is not None and rec.status == "active", "NoRecord")
        need(rec.depositor == wallet, "NotDepositor")
        pos = self.nfpm.positions[token_id]
        f0, f1, liq = pos.fees0, pos.fees1, pos.liquidity
        c0, c1 = self.nfpm.collect(LPVAULT, token_id, rec.depositor, U128, U128)
        need(pos.liquidity == liq, "LiquidityChanged")
        return dict(c0=c0, c1=c1, f0=f0, f1=f1)

    # ------------------------------------------------------------------ deficit coverage (Coverage Spokes, Q-236)
    def cover_deficit(self, asset=GHO, spoke=CDP, max_amount=U256):
        return self.tx(self._cover_deficit, asset, spoke, max_amount)

    def _cover_deficit(self, asset, spoke, max_amount):
        """SPEC-FLR-001: amount = min(maxAmount, ceil(deficit), fundedBalance), in the deficit's own asset."""
        sd = self.hub.assets[asset].spokes[spoke]
        amount = min(max_amount, cdiv(sd.deficit_ray, RAY), self.funded_balance(asset))
        need(amount > 0, "NothingToCover")
        sh, elim = self.hub.eliminate_deficit(asset, COV[asset], amount, spoke)
        return dict(shares=sh, eliminated=elim)

    # ------------------------------------------------------------------ misc actions
    def donate_liquidity(self, donor, token_id, liq):
        def f():
            pos = self.nfpm.positions[token_id]
            mk = next(x for x in self.markets if x.pool is pos.pool)
            a0, a1 = position_amounts(mk.pool.sqrt_p, liq, mk.pool.spacing, True)
            self.fund(donor, mk.t0, a0)
            self.fund(donor, mk.t1, a1)
            self.nfpm.increase_liquidity(token_id, donor, liq)
        return self.tx(f)

    def donate(self, frm, token, to, amount):
        """A plain transfer of dust to an Avana address (no protocol function credits it)."""
        def f():
            self.fund(frm, token, amount)
            got = self._send(token, frm, to, amount)
            self.dust[(token, to)] = self.dust.get((token, to), 0) + got
        return self.tx(f)

    def accrue_pool_fees(self, m, f0, f1):
        mk = self.markets[m]
        return self.tx(self.nfpm.credit_fees, mk.pool, ARB, f0, f1)

    def poke(self, m, gas_ok=True):
        return self.markets[m].oracle.poke(self.now(), gas_ok)

    def remove_keeper(self, k):
        def f():
            need(k in self.keepers, "NotKeeper")
            need(len(self.unfrozen_keepers() - {k}) >= self.p.keeper_floor, "KeeperFloor")
            self.keepers.discard(k)
        return self.tx(f)

    def claim_escrow(self, borrower, token, recipient):
        return self.tx(self._claim_escrow, borrower, token, recipient)

    def _claim_escrow(self, borrower, token, recipient):
        need(recipient not in (None, ESCROW), "InvalidRecipient")
        amt = self.escrow_claimable.get((token, borrower), 0)
        need(amt > 0, "NothingToClaim")
        self.escrow_claimable[(token, borrower)] = 0
        self.escrow_total[token] -= amt
        self.escrow_claimed[(token, borrower)] = self.escrow_claimed.get((token, borrower), 0) + amt
        self.ledger.transfer(token, ESCROW, recipient, amt)
        return amt
