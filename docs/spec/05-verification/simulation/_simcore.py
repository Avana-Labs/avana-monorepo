# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Shared engine for the Avana economic stress simulations (prefix SIM).

Plain Python 3.9, standard library only (numpy is not installed in .venv and is
not added). All randomness comes from random.Random(seed): every script is
reproducible. Running this module directly runs the engine self-tests
SIM-00A (float liquidation sizing == integer Aave V4 reference in
z3/aave-risk/_v4ref.py) and SIM-00B (same seed -> identical results).

What the engine models (launch values from docs/spec/01-architecture/05-parameters.md):
  * Markets: full-range Uniswap v3 stable pools USDC/USDT, USDC/GHO, USDT/GHO,
    DAI/USDC. A position is measured in par units (1 unit = $1 of LP value at
    peg); value = units * sqrt(v0 * v1) with v = min(quote, $1) (Q-177).
  * Accounts hold one or two markets and debt in GHO (Aave's fixed $1 source,
    Q-100) and optionally USDC, priced by a DebtOracle (Q-248).
  * LPOracle per market and DebtOracle for USDC (2.10): primary route (hourly
    heartbeat, Q-274), alternate route TOKEN/X x X/USD (no intermediate shared
    within a pool, Q-176), standby route switched in by a guardian (Q-248).
    Failover, agreement tolerance (Q-184), TWAP guard, USD band (Q-275), Cached
    from the first failed read for cachedWindow (Q-183), Expired, the
    disagreement pause and expiry (Q-162, Q-199, Q-208), the alternate held to
    its borrow age for liquidation (Q-274), served price by state (Q-247:
    Expired = worthless, disagreement = lower routes; DebtOracle Expired =
    accepted x (1 + debtStressRiseBps)), grace from source-timestamp evidence
    (Q-129, Q-154, Q-264).
  * Liquidation gated per seized market and repaid reserve (Q-247); Aave V4
    sizing over every reserve of the account; LPVaultSwap with effective
    slippage (Q-159, Q-235), recovery floor (Q-198), per-leg oracle minimum
    (Q-250), caller shortfall top-up (Q-251), Avana fee from oracle value
    (Q-256), SettlementBudget caps and per-market sub-caps (Q-267), shortfall
    reports and automatic in-kind (Q-251), manual in-kind at the short delay
    (Q-228), in-kind cap and split (Q-133), backup routes outside the market's
    own pool (Q-273), permissionless fallback (Q-213).
  * Circuit breakers and pause reasons affect only new borrowing and
    non-rescue top-ups (Q-241, Q-252); rescue top-ups restore HF 1.10.
"""
from __future__ import annotations

import math
import os
import random
import sys
from collections import deque
from dataclasses import dataclass, field, replace

H = 3600
DAY = 86400
YEAR = 365 * DAY

MARKETS = {
    'USDC/USDT': ('USDC', 'USDT'),
    'USDC/GHO': ('USDC', 'GHO'),
    'USDT/GHO': ('USDT', 'GHO'),
    'DAI/USDC': ('DAI', 'USDC'),
}
MARKET_WEIGHTS = {'USDC/USDT': 0.40, 'USDC/GHO': 0.25, 'USDT/GHO': 0.15, 'DAI/USDC': 0.20}
TOKENS = ('USDC', 'USDT', 'DAI', 'GHO')
RESERVES = ('GHO', 'USDC')

# Chainlink legs: (deviation threshold, heartbeat seconds). Primary legs publish at least hourly (Q-274).
PRIMARY = {'USDC': (0.0025, 3600), 'USDT': (0.0025, 3600), 'DAI': (0.0025, 3600), 'GHO': (0.01, 3600)}
# Alternate route TOKEN/X x X/USD; the two tokens of a pool never share X (Q-176).
INTERMEDIATE = {'USDC': 'ETH', 'USDT': 'BTC', 'DAI': 'BTC', 'GHO': 'LINK'}
ALT_TOKEN_LEG = {t: (0.01, 86400) for t in TOKENS}
X_LEG = {'ETH': (0.005, 3600), 'BTC': (0.005, 3600), 'LINK': (0.01, 3600)}
X_DAILY_VOL = {'ETH': 0.03, 'BTC': 0.025, 'LINK': 0.05}
STANDBY = {t: (0.005, 3600) for t in TOKENS}
AGE_MARGIN, BORROW_AGE_CAP = 600, 4200       # Q-274
EXPIRED_PX = 5e-9                            # 1 unit of 1e-8 USD per whole vault token = 2 par units (Q-247)

STATES = ('Live', 'Drifting', 'Cached', 'Expired')
BLOCK_REASONS = ('stale', 'disagree', 'alt_age', 'debt_stale', 'grace', 'keeper_down', 'route', 'floor',
                 'buy', 'flash', 'unprofitable', 'keeper_gho')


@dataclass
class Params:
    # --- risk configuration ---
    prf: float = 0.40                 # poolRiskFactor, at most 0.40 (Q-186)
    cf_token: float = 0.78            # Core Hub CF of each pool token (ASSUMED, all equal)
    max_bonus: float = 0.05           # maxLiquidationBonus - 1 (ASSUMED)
    min_bonus: float = 0.02           # minLiquidationBonus 200 bps (Q-179, Q-196)
    hf_for_max_bonus: float = 0.90    # ASSUMED
    target_hf: float = 1.10           # aaveTargetHealthFactor (Q-185)
    min_open_hf: float = 1.10         # minOpeningHealthFactor (Q-018)
    dust_usd: float = 1000.0          # Aave V4 DUST_LIQUIDATION_THRESHOLD
    slippage: float = 0.01            # slippageAllowanceBps 100 (Q-196)
    flash_fee: float = 0.0            # maxFlashFeeBps 0 (Q-135)
    buy_slippage: float = 0.003       # buySlippageAllowanceBps for USDC debt, 30 (ASSUMED listing value)
    floor_rounding: float = 1.0       # floorRoundingAllowanceGho 1 GHO (Q-198)
    avana_share: float = 0.20         # avanaFeeShareBps 2,000 (Q-256)
    max_shortfall_bps: float = 0.10   # maxShortfallBps 1,000 (Q-251)
    keeper_topup: bool = True         # keepers answer a floor failure with a top-up (keeper agreement, LIQ-077)
    # --- oracle ---
    cached_window: int = 3600         # Q-183, measured from the first failed read
    dis_pause_max: int = 3600         # disagreementPauseMax (Q-183)
    agree_margin: float = 0.005       # feedAgreementMarginBps 50 (Q-184)
    tol_override: object = None       # None = the on-chain lower bound per token (Q-184)
    grace: int = 1800                 # graceDuration (Q-196)
    grace_hf: float = 0.95            # graceHealthFactor (Q-196)
    twap_window: int = 1800           # Q-196
    twap_ticks: int = 50              # twapToleranceTicks (Q-196)
    band_low: float = 0.90            # usdBandLow, uncapped quotes (Q-275)
    band_high: float = 1.02           # usdBandHigh, capped prices (Q-275)
    debt_stress: float = 0.05         # debtStressRiseBps 500 for USDC (Q-247, Q-248)
    standby_route_delay: object = None  # guardian useStandbyRoute delay after a seizure block; None = never
    pool_arb_speed: float = 0.7       # fraction of pool-vs-market gap closed per 5-minute step
    # --- funding / reserves ---
    credit_line: float = 2_000_000.0  # Q-006
    drawn: float = 1.0
    first_loss: float = 400_000.0     # firstLossReserveMinimum GHO: coverageRatioBps x 2M drawCap (Q-196, DEF-019)
    budget_balance: float = 20_000.0  # SettlementBudget funding (Q-167)
    budget_per_call: float = 25.0     # Q-196
    budget_per_day: float = 500.0     # Q-196
    min_market_cap: float = 100.0     # MIN_MARKET_WINDOW_CAP (Q-267)
    flash_cap: float = 2_000_000.0    # flash liquidity per tx, the Aave V3 Pool's idle debt asset (ASSUMED)
    # --- conversion routes ---
    gsm_fee: float = 0.001            # GSM sell fee 0% or 0.10%
    gsm_buy_fee: float = 0.002        # GSM buy fee (USDC debt buy leg), ASSUMED
    gsm_band: tuple = (0.99, 1.01)    # GSM oracle freezer
    gsm_unfreeze: tuple = (0.995, 1.005)
    gsm_headroom: dict = field(default_factory=lambda: {'USDC': 20e6, 'USDT': 24e6})
    gsm_cap: dict = field(default_factory=lambda: {'USDC': 50e6, 'USDT': 50e6})
    gsm_arb_rate: float = 10e6        # $/hour of outside arbitrage into the GSM below 1 - fee
    psm_headroom: float = 100e6
    dex_depth: dict = field(default_factory=lambda: {'USDC': 5e6, 'USDT': 3e6, 'DAI': 3e6})  # $ for 1% impact
    dex_fee: float = 0.0005
    dex_stress: float = 0.25          # depth multiplier while the token is > 1% off peg
    dex_drain: dict = field(default_factory=dict)   # extra depth multiplier per token
    dex_revert: dict = field(default_factory=dict)  # token -> True: backup route reverts (route gone)
    dex_discount: dict = field(default_factory=dict)  # token -> backup route price below market (dislocation)
    inkind_trigger: bool = True       # inKindAutoTrigger approved at listing (Q-251)
    inkind_auto_delay: int = 6 * H    # inKindAutoDelay (Q-251)
    inkind_manual_delay: object = 12 * H  # enableInKind at the short delay (Q-228); None = never
    inkind_expiry: int = 24 * H       # inKindExpiry (Q-196)
    keeper_gho: float = 1_000_000.0   # GHO keepers hold for in-kind
    # --- keepers and gas ---
    gwei: float = 20.0
    eth_usd: float = 3000.0
    gas_base: int = 650_000
    gas_gsm_leg: int = 250_000
    gas_dex_leg: int = 180_000
    gas_psm_leg: int = 120_000
    gas_buy_leg: int = 220_000
    gas_inkind: int = 600_000
    gas_topup: int = 40_000
    keeper_mode: str = 'obliged'      # 'obliged' (keeper agreement, reimbursed) or 'rational'
    primary_down: object = None       # (start_s, end_s): primary keepers stalled
    standby_keeper_delay: object = 15 * 60  # standby keeper acts this long after the stall; None = no standby
    permissionless: bool = True       # Q-213 fallback: rational searchers, routed only, no budget
    # --- borrowers ---
    n_accounts: int = 200
    active_share: float = 0.30
    react_delay: tuple = (1 * H, 12 * H)
    warn_hf: float = 1.03
    react_target_hf: float = 1.25
    topup_share: float = 0.5          # reacting borrowers who add collateral instead of repaying
    apr: float = 0.08
    small_share: float = 0.25
    small_range: tuple = (100.0, 1500.0)
    drifted_share: float = 0.10
    multi_share: float = 0.20         # accounts holding two markets
    usdc_debt_share: float = 0.0      # accounts with half their debt in USDC (0: GHO debt only, one example of the approved set)
    # --- incident controls ---
    pause: object = None              # (start, end, reason) with reason 'General' or 'MintPathSuspect' (Q-252)
    breaker_trip: object = None       # (start, end) manual market breaker trip on every market (Q-241)
    # --- simulation ---
    step: int = 300
    attack: object = None             # dict(start, usd): opportunistic stale-price borrower

    @property
    def cf(self):
        return math.floor(self.cf_token * self.prf * 10_000) / 10_000

    def bonus(self, hf):
        if hf <= self.hf_for_max_bonus:
            return self.max_bonus
        return self.min_bonus + (self.max_bonus - self.min_bonus) * (1 - hf) / (1 - self.hf_for_max_bonus)

    def tolerance(self, tok):
        if self.tol_override is not None:
            return self.tol_override
        x = INTERMEDIATE[tok]
        return PRIMARY[tok][0] + ALT_TOKEN_LEG[tok][0] + X_LEG[x][0] + self.agree_margin

    def s_eff(self, b, cbuy=0.0):
        """SPEC-LIQ-016 (SPEC-LIQ-003 when cbuy = 0), in fractions."""
        bn = 1 + b
        num = bn - (1 + self.flash_fee) * (1 + cbuy)
        if num <= 0:
            return 0.0
        return min(self.slippage, math.floor(1e4 * num / bn) / 1e4)


# ---------------------------------------------------------------------------
# Price paths
# ---------------------------------------------------------------------------

def piecewise(points, horizon_h, step, rng=None, noise=0.0, base_noise=0.0002):
    """Linear interpolation through [(hour, price)], flat after the last point.
    Noise: price *= 1 + N(0, base_noise + noise*|1-price|) per step (seeded)."""
    n = int(horizon_h * H / step) + 1
    out = []
    j = 0
    for i in range(n):
        h = i * step / H
        while j + 1 < len(points) and points[j + 1][0] <= h:
            j += 1
        if j + 1 < len(points):
            (h0, v0), (h1, v1) = points[j], points[j + 1]
            v = v0 + (v1 - v0) * (h - h0) / (h1 - h0) if h >= h0 else v0
        else:
            v = points[-1][1]
        if rng is not None:
            v *= 1 + rng.gauss(0, base_noise + noise * abs(1 - v))
        out.append(max(v, 0.001))
    return out


def flat_paths(horizon_h, step, rng=None):
    return {t: piecewise([(0, 1.0)], horizon_h, step, rng) for t in TOKENS}


USDC_MAR2023 = [(0, 1.0), (2, 0.995), (6, 0.97), (10, 0.92), (14, 0.88), (16, 0.87), (20, 0.89),
                (28, 0.91), (36, 0.92), (44, 0.95), (50, 0.97), (56, 0.985), (68, 0.995), (72, 0.998)]


def dai_from_usdc(usdc_path):
    """DAI tracked USDC in March 2023 (low ~0.897 vs ~0.87): DAI = 1 - 0.77*(1-USDC)."""
    return [1 - 0.77 * (1 - u) for u in usdc_path]


# ---------------------------------------------------------------------------
# Accounts
# ---------------------------------------------------------------------------

@dataclass
class Account:
    aid: int
    coll: dict
    debt: dict
    debt0: float
    active: bool
    delay: float
    topup: bool = False
    pending_at: object = None
    attacker: bool = False
    closed: bool = False


def make_accounts(p: Params, rng: random.Random, px=1.0):
    n = p.n_accounts
    total = p.credit_line * p.drawn
    n_small = int(p.small_share * n)
    lo, hi = p.small_range
    small = [math.exp(rng.uniform(math.log(lo), math.log(hi))) for _ in range(n_small)]
    rest = [min(max(rng.lognormvariate(math.log(6000), 1.0), 1000), 0.05 * total) for _ in range(n - n_small)]
    target = total - sum(small)
    for _ in range(50):
        s = sum(rest)
        rest = [min(max(d * target / s, 1000), 0.075 * total) for d in rest]
        if abs(sum(rest) - target) < 1:
            break
    debts = small + rest
    rng.shuffle(debts)
    names = list(MARKET_WEIGHTS)
    weights = [MARKET_WEIGHTS[k] for k in names]
    accts = []
    for i, d in enumerate(debts):
        u = rng.random()
        if u < p.drifted_share:
            hf = rng.uniform(1.02, 1.10)
        elif u < p.drifted_share + 0.30:
            hf = rng.uniform(1.10, 1.15)
        elif u < p.drifted_share + 0.60:
            hf = rng.uniform(1.15, 1.35)
        else:
            hf = rng.uniform(1.35, 2.5)
        mkt = rng.choices(names, weights)[0]
        units = d * hf / (p.cf * px)
        coll = {mkt: units}
        if rng.random() < p.multi_share:
            other = rng.choices([k for k in names if k != mkt], [MARKET_WEIGHTS[k] for k in names if k != mkt])[0]
            w = rng.uniform(0.2, 0.8)
            coll = {mkt: units * w, other: units * (1 - w)}
        debt = {'GHO': d}
        if rng.random() < p.usdc_debt_share:
            debt = {'GHO': d / 2, 'USDC': d / 2}
        accts.append(Account(i, coll, debt, d, rng.random() < p.active_share, rng.uniform(*p.react_delay),
                             topup=rng.random() < p.topup_share))
    return accts


def token_exposure(accts, cf, open_hf=1.10):
    """Cap charge per token: each pledge charges its full LP value at opening to both tokens' counters
    (tokenUsdCap, Q-249). Value at opening = debt x openHF / CF for accounts opened at the opening floor."""
    ex = {t: 0.0 for t in TOKENS}
    for a in accts:
        tot = sum(a.coll.values())
        val_now = tot
        val_open = max(val_now, sum(a.debt.values()) * open_hf / cf) if tot > 0 else 0.0
        for m, u in a.coll.items():
            for t in MARKETS[m]:
                ex[t] += val_open * u / tot
    return ex


# ---------------------------------------------------------------------------
# Chainlink legs and routes
# ---------------------------------------------------------------------------

class Leg:
    __slots__ = ('dev', 'hb', 'answer', 'updated', 'failing', 'gap', 'missed')

    def __init__(self, dev, hb, value, rng):
        self.dev, self.hb = dev, hb
        self.answer = value
        self.updated = -rng.uniform(0, hb * 0.9)
        self.failing = False
        self.gap = None
        self.missed = False

    @property
    def max_age(self):
        return self.hb + AGE_MARGIN                  # feedMaxAge = liquidationPriceMaxAge (Q-274)

    @property
    def borrow_age(self):
        return min(self.hb + AGE_MARGIN, BORROW_AGE_CAP)

    def tick(self, t, value, mode, wrong=None):
        if mode == 'fail':
            self.failing = True
            self.missed = True
            return
        self.failing = False
        if mode == 'silent':
            self.missed = True
            return
        if mode == 'wrong':
            value = wrong
        if abs(value - self.answer) > self.dev * self.answer or t - self.updated >= self.hb:
            # rounds between ticks are not modelled; a gap exists only where the feed missed rounds
            if self.missed and t - self.updated > self.max_age:
                self.gap = (self.updated + self.max_age + 1, t)
            self.missed = False
            self.answer, self.updated = value, t

    def valid(self, t):
        return not self.failing and t - self.updated <= self.max_age


class Route:
    def __init__(self, legs):
        self.legs = legs

    def value(self):
        v = 1.0
        for lg in self.legs:
            v *= lg.answer
        return v

    def ts(self):
        return min(lg.updated for lg in self.legs)

    def valid(self, t):
        return all(lg.valid(t) for lg in self.legs)

    def stale_only(self, t):
        return all(not lg.failing for lg in self.legs) and not self.valid(t)

    def stale_from(self, t):
        return min(lg.updated + lg.max_age for lg in self.legs if not lg.valid(t)) + 1

    def stale_interval(self, t):
        """SPEC-ORC-014 stale interval S_r: Stale route -> [staleFrom, now]; valid route -> union of the
        legs' last gaps if they overlap, else the gap with the later end."""
        if self.valid(t):
            gaps = [lg.gap for lg in self.legs if lg.gap is not None and lg.gap[0] < lg.gap[1]]
            if not gaps:
                return None
            gaps.sort()
            if len(gaps) == 2 and gaps[1][0] <= gaps[0][1]:
                return (gaps[0][0], max(gaps[0][1], gaps[1][1]))
            return max(gaps, key=lambda g: g[1])
        if self.stale_only(t):
            return (self.stale_from(t), t)
        return None


class TokenEval:
    __slots__ = ('q', 'tq', 'on_alt', 'vp', 'va', 'p', 'b', 'stale_both', 'stale_at', 'disagree',
                 'alt_past', 'borrow_ok', 'liq_ok_age', 'B')


# ---------------------------------------------------------------------------
# Engine
# ---------------------------------------------------------------------------

class Sim:
    def __init__(self, p: Params, paths: dict, seed: int, accounts=None, outage=None, gwei_path=None):
        """outage: dict or list of dicts(start, end, mode 'fail'|'silent'|'wrong', tokens=None|iterable,
        routes=None|{'primary','alternate','standby'}, wrong=value)."""
        self.p = p
        self.paths = paths
        self.n = len(paths['USDC'])
        self.accts = accounts if accounts is not None else make_accounts(p, random.Random(seed))
        self.outages = [] if outage is None else (outage if isinstance(outage, list) else [outage])
        self.gwei_path = gwei_path
        frng = random.Random(seed * 7919 + 3)
        self.xpx = {x: 1.0 for x in X_LEG}
        self.xrng = random.Random(seed * 31 + 7)
        self.prim = {t: Route([Leg(*PRIMARY[t], 1.0, frng)]) for t in TOKENS}
        self.xleg = {x: Leg(*X_LEG[x], 1.0, frng) for x in X_LEG}
        self.alt = {t: Route([Leg(*ALT_TOKEN_LEG[t], 1.0, frng), self.xleg[INTERMEDIATE[t]]]) for t in TOKENS}
        self.stby = {t: Route([Leg(*STANDBY[t], 1.0, frng)]) for t in TOKENS}
        self.slot = {t: {'primary': self.prim[t], 'alternate': self.alt[t]} for t in TOKENS}
        self.version = {t: 0 for t in TOKENS}
        self.blocked_since = {t: None for t in TOKENS}
        self.switched = {t: None for t in TOKENS}
        self.pool = {k: 1.0 for k in MARKETS}
        self.twap_buf = {k: deque() for k in MARKETS}
        # LPOracle storage per market, DebtOracle storage for USDC
        self.o = {k: dict(failed_since=None, dis_since=None, A=1.0, A_t=-1e9, latched=False, rec=None,
                          seen_ver={}, cp=(1.0, 0.0), st='Live') for k in MARKETS}
        self.do = dict(failed_since=None, dis_since=None, A=1.0, A_t=-1e9, latched=False, rec=None,
                       seen_ver=0, st='Live')
        self.spx = {k: 1.0 for k in MARKETS}
        self.dpx = {'GHO': 1.0, 'USDC': 1.0}
        self.liq_ok = {k: True for k in MARKETS}
        self.block_kind = {k: None for k in MARKETS}
        self.borrow_ok = {k: True for k in MARKETS}
        self.debt_liq_ok = True
        self.in_grace = {k: False for k in MARKETS}
        self.debt_grace = False
        self.gsm_head = dict(p.gsm_headroom)
        self.gsm_frozen = {k: False for k in p.gsm_headroom}
        self.budget = p.budget_balance
        self.draws = deque()          # (t, market, amount) within 24h
        self.reserve = {'GHO': p.first_loss, 'USDC': p.first_loss}
        self.keeper_gho = p.keeper_gho
        # in-kind and breakers
        self.short_since = {k: None for k in MARKETS}
        self.short_last = {k: None for k in MARKETS}
        self.inkind_until = {k: -1 for k in MARKETS}
        self.inkind_how = {k: None for k in MARKETS}
        self.manual_at = {k: None for k in MARKETS}
        self.first_fail = {k: None for k in MARKETS}
        self.route_fail_t = {k: deque() for k in MARKETS}
        self.seized_t = {k: deque() for k in MARKETS}
        self.latch_until = {k: -1 for k in MARKETS}
        self.hub_deficit = {'GHO': 0.0, 'USDC': 0.0}
        self.r = dict(deficit=0.0, reserve_draw=0.0, uncovered=0.0, budget_draw=0.0, budget_refused=0, liq=0,
                      inkind=0, perm_liq=0, borrower_loss=0.0, keeper_pnl=0.0, keeper_gross=0.0, gas=0.0,
                      avana_fee=0.0, reimburse=0.0, repaid_by_borrowers=0.0, topups=0, topups_refused=0,
                      attack_borrow=0.0, attack_cost=0.0, shortfall_paid=0.0, topup_calls=0, reports=0,
                      reports_failed=0, auto_inkind=0, manual_inkind=0, first_inkind=None, standby_switches=0,
                      forced_healthy=0, forced_healthy_loss=0.0,
                      state_steps={k: {s: 0 for s in STATES} for k in MARKETS},
                      paused_steps={k: 0 for k in MARKETS}, dis_steps={k: 0 for k in MARKETS},
                      blocked_steps={b: 0 for b in BLOCK_REASONS}, blocked_accts={b: set() for b in BLOCK_REASONS},
                      liq_hf=[], liq_repay=[], liq_t=[], keeper_pnl_each=[], max_true_underwater_h=0.0,
                      routes={}, budget_draws_n=0, budget_by_mkt={k: 0.0 for k in MARKETS},
                      borrow_stale_steps={k: 0 for k in MARKETS}, borrow_below_band_steps={k: 0 for k in MARKETS},
                      grace_starts=0, max_mkt_window=0.0,
                      cached_entries=0, skipped_cached=0, debt_states={s: 0 for s in STATES}, first_liq_mkt={})
        self.underwater_since = {}
        self.cf = p.cf
        self.open = list(self.accts)
        self.prev_state = {k: 'Live' for k in MARKETS}

    # --- outages -------------------------------------------------------------
    def _mode(self, t, tok, slot):
        for o in self.outages:
            if o['start'] <= t < o['end'] and (o.get('tokens') is None or tok in o['tokens']) \
                    and slot in (o.get('routes') or ('primary', 'alternate', 'standby')):
                return o['mode'], o.get('wrong')
        return None, None

    def _xmode(self, t):
        for o in self.outages:
            if o['start'] <= t < o['end'] and o.get('tokens') is None \
                    and 'alternate' in (o.get('routes') or ('primary', 'alternate', 'standby')):
                return o['mode']
        return None

    # --- oracle --------------------------------------------------------------
    def _token_eval(self, t, tok):
        p = self.p
        e = TokenEval()
        rp, ra = self.slot[tok]['primary'], self.slot[tok]['alternate']
        e.vp, e.va = rp.valid(t), ra.valid(t)
        e.p, e.b = rp.value(), ra.value()
        e.on_alt = False
        if e.vp:
            e.q, e.tq, use = e.p, rp.ts(), rp
        elif e.va:
            e.q, e.tq, use, e.on_alt = e.b, ra.ts(), ra, True
        else:
            e.q, e.tq, use = None, None, None
        e.stale_both = rp.stale_only(t) and ra.stale_only(t)
        e.stale_at = max(rp.stale_from(t), ra.stale_from(t)) if e.stale_both else None
        T = p.tolerance(tok)
        e.disagree = e.vp and e.va and abs(e.p - e.b) > T * min(e.p, e.b)
        e.alt_past = e.on_alt and any(t - lg.updated > lg.borrow_age for lg in ra.legs)
        e.borrow_ok = use is not None and all(t - lg.updated <= lg.borrow_age for lg in use.legs)
        # recovery evidence (SPEC-ORC-014): both-stale interval of the two routes
        sp, sa = rp.stale_interval(t), ra.stale_interval(t)
        e.B = None
        if sp and sa:
            lo, hi = max(sp[0], sa[0]), min(sp[1], sa[1])
            if hi > lo:
                e.B = (lo, hi)
        return e

    def _grace_update(self, o, evs, t, fresh_ts):
        p = self.p
        best = None
        for e in evs:
            if e.B and e.B[1] - e.B[0] >= p.cached_window and (o['rec'] is None or e.B[1] > o['rec']):
                best = e.B[1] if best is None else max(best, e.B[1])
        if best is not None:
            o['rec'] = min(best, t)
            o['latched'] = False
            self.r['grace_starts'] += 1
        elif o['latched']:
            o['rec'] = min(max(fresh_ts), t)          # Q-264
            o['latched'] = False
            self.r['grace_starts'] += 1

    def _failed_state(self, o, evs, t):
        p = self.p
        sts = [e.stale_at for e in evs if e.q is None and e.stale_both]
        s_ts = min(sts) if sts else None
        if o['failed_since'] is None:
            o['failed_since'] = min(s_ts, t) if s_ts is not None else t
            self.r['cached_entries'] += 1
        start = min(x for x in (s_ts, o['failed_since'], t) if x is not None)
        if s_ts is not None and t >= s_ts + p.cached_window:
            o['latched'] = True                        # Q-154: only from source timestamps
        return 'Cached' if t < start + p.cached_window else 'Expired'

    def _update_oracles(self, t, m):
        p = self.p
        tev = {tok: self._token_eval(t, tok) for tok in TOKENS}
        self.tev = tev
        k = max(1, int(p.twap_window / p.step))
        tick_tol = p.twap_ticks * math.log(1.0001)
        for mkt, (a, b) in MARKETS.items():
            o = self.o[mkt]
            ea, eb = tev[a], tev[b]
            buf = self.twap_buf[mkt]
            if ea.q is None or eb.q is None:
                st = self._failed_state(o, (ea, eb), t)
                o['dis_since'] = None
                served = o['A'] if st == 'Cached' else EXPIRED_PX
                liq_ok, kind, b_ok = False, 'stale', False
            else:
                o['failed_since'] = None
                self._grace_update(o, (ea, eb), t, (ea.tq, eb.tq))
                ver = (self.version[a], self.version[b])
                if o['seen_ver'].get('v') != ver:
                    o['seen_ver']['v'] = ver
                    o['dis_since'] = None                # REQ-ORACLE-095
                dis = ea.disagree or eb.disagree
                if dis:
                    if o['dis_since'] is None:
                        o['dis_since'] = t
                else:
                    o['dis_since'] = None
                twap = sum(buf) / len(buf)
                twap_bad = abs(twap - math.log(ea.q / eb.q)) > tick_tol
                band_bad = math.sqrt(ea.q * eb.q) < p.band_low or \
                    math.sqrt(min(ea.q, 1.0) * min(eb.q, 1.0)) > p.band_high
                st = 'Drifting' if (dis or twap_bad or band_bad) else 'Live'
                fresh = math.sqrt(min(ea.q, 1.0) * min(eb.q, 1.0))
                if st == 'Live':
                    served = fresh
                    if min(ea.tq, eb.tq) > o['A_t']:
                        o['A'], o['A_t'] = fresh, min(ea.tq, eb.tq)
                elif dis:
                    w = [min(min(e.p, e.b), 1.0) if (e.vp and e.va) else min(e.q, 1.0) for e in (ea, eb)]
                    served = min(math.sqrt(w[0] * w[1]), o['A'])
                else:
                    served = min(fresh, o['A'])
                alt_past = ea.alt_past or eb.alt_past
                liq_ok = not dis and not alt_past
                kind = 'disagree' if dis else ('alt_age' if alt_past else None)
                b_ok = st == 'Live' and ea.borrow_ok and eb.borrow_ok
                if dis:
                    self.r['dis_steps'][mkt] += 1
            if st == 'Expired' and self.prev_state[mkt] not in ('Cached', 'Expired'):
                self.r['skipped_cached'] += 1
            self.prev_state[mkt] = st
            if not liq_ok:
                self.r['paused_steps'][mkt] += 1
            o['st'] = st
            if t >= o['cp'][1] + H:
                o['cp'] = (o['A'], t)                    # hourly checkpoint of the accepted price
            self.spx[mkt] = served
            self.liq_ok[mkt] = liq_ok
            self.block_kind[mkt] = kind
            self.borrow_ok[mkt] = b_ok
            self.in_grace[mkt] = o['rec'] is not None and o['rec'] <= t < o['rec'] + p.grace
            self.r['state_steps'][mkt][st] += 1
        # DebtOracle (USDC): one token, no pool, no ceiling, stress price once Expired (SPEC-ORC-018)
        e, d = tev['USDC'], self.do
        if e.q is None:
            st = self._failed_state(d, (e,), t)
            d['dis_since'] = None
            self.dpx['USDC'] = d['A'] if st == 'Cached' else math.ceil(d['A'] * (1 + p.debt_stress) * 1e8) / 1e8
            self.debt_liq_ok = False
        else:
            d['failed_since'] = None
            self._grace_update(d, (e,), t, (e.tq,))
            if d['seen_ver'] != self.version['USDC']:
                d['seen_ver'] = self.version['USDC']
                d['dis_since'] = None
            if e.disagree:
                st = 'Drifting'
                if d['dis_since'] is None:
                    d['dis_since'] = t
                self.dpx['USDC'] = max(e.p, e.b, d['A'])
            else:
                st = 'Live'
                d['dis_since'] = None
                self.dpx['USDC'] = e.q
                if e.tq > d['A_t']:
                    d['A'], d['A_t'] = e.q, e.tq
            self.debt_liq_ok = st == 'Live' and not e.alt_past
        d['st'] = st
        self.debt_grace = d['rec'] is not None and d['rec'] <= t < d['rec'] + p.grace
        self.r['debt_states'][st] += 1

    def _guardian(self, t):
        """useStandbyRoute (Q-248): once a token's markets have had seizure blocked by that token's routes
        for standby_route_delay, and its standby route is valid, a guardian swaps the broken slot."""
        p = self.p
        if p.standby_route_delay is None:
            return
        for tok in TOKENS:
            e = self.tev[tok]
            broken = e.q is None or e.disagree or e.alt_past
            if not broken:
                self.blocked_since[tok] = None
                continue
            if self.blocked_since[tok] is None:
                self.blocked_since[tok] = t
            sb = self.stby[tok]
            if self.switched[tok] or t - self.blocked_since[tok] < p.standby_route_delay or not sb.valid(t):
                continue
            if e.disagree:
                tol = p.tolerance(tok)
                slot = 'primary' if abs(e.p - sb.value()) > tol * min(e.p, sb.value()) else 'alternate'
            elif e.q is None or e.alt_past:
                slot = 'primary'
            self.slot[tok][slot] = sb
            self.version[tok] += 1
            self.switched[tok] = (t, slot)
            self.r['standby_switches'] += 1

    def _update_market(self, t, m):
        p = self.p
        k = max(1, int(p.twap_window / p.step))
        for mkt, (a, b) in MARKETS.items():
            tgt = m[a] / m[b]
            self.pool[mkt] += min(1.0, p.pool_arb_speed * p.step / 300) * (tgt - self.pool[mkt])
            buf = self.twap_buf[mkt]
            buf.append(math.log(self.pool[mkt]))
            if len(buf) > k:
                buf.popleft()
        sd = math.sqrt(p.step / DAY)
        for x in self.xpx:
            self.xpx[x] *= math.exp(self.xrng.gauss(0, X_DAILY_VOL[x] * sd))
        xm = self._xmode(t)
        for x, lg in self.xleg.items():
            lg.tick(t, self.xpx[x], xm)
        for tok in TOKENS:
            mp, wp = self._mode(t, tok, 'primary')
            self.prim[tok].legs[0].tick(t, m[tok], mp, wp)
            ma, wa = self._mode(t, tok, 'alternate')
            self.alt[tok].legs[0].tick(t, m[tok] / self.xpx[INTERMEDIATE[tok]], ma,
                                       None if wa is None else wa / self.xpx[INTERMEDIATE[tok]])
            ms, ws = self._mode(t, tok, 'standby')
            self.stby[tok].legs[0].tick(t, m[tok], ms, ws)
        self._update_oracles(t, m)
        self._guardian(t)
        self.tpx = {k: math.sqrt(m[a] * m[b]) for k, (a, b) in MARKETS.items()}
        for u in self.gsm_head:
            f = self.prim[u].legs[0].answer
            if self.gsm_frozen[u]:
                if p.gsm_unfreeze[0] <= f <= p.gsm_unfreeze[1]:
                    self.gsm_frozen[u] = False
            elif not (p.gsm_band[0] <= f <= p.gsm_band[1]):
                self.gsm_frozen[u] = True
            if not self.gsm_frozen[u]:
                flow = p.gsm_arb_rate * p.step / H
                if m[u] / m['GHO'] < 1 - p.gsm_fee:
                    self.gsm_head[u] = max(0.0, self.gsm_head[u] - flow)
                elif m[u] / m['GHO'] > 1 + p.gsm_fee:
                    self.gsm_head[u] = min(p.gsm_cap[u], self.gsm_head[u] + flow)
        # breakers (borrow side only, Q-241): latched counters age out
        for mk in MARKETS:
            for dq in (self.route_fail_t[mk], self.seized_t[mk]):
                while dq and dq[0][0] <= t - H:
                    dq.popleft()
        while self.draws and self.draws[0][0] <= t - DAY:
            self.draws.popleft()

    def breaker(self, mkt, t):
        p = self.p
        if p.breaker_trip and p.breaker_trip[0] <= t < p.breaker_trip[1]:
            return True
        if t < self.latch_until[mkt]:
            return True
        o = self.o[mkt]
        cp, at = o['cp']
        if t - at <= 2 * H and self.spx[mkt] * 1e4 < cp * (1e4 - 300):
            return True
        if o['st'] != 'Live':
            return True
        return self.hub_deficit['GHO'] > 1000.0

    def pause_reason(self, t):
        pz = self.p.pause
        return pz[2] if pz and pz[0] <= t < pz[1] else None

    def borrow_open(self, mkt, t):
        return self.borrow_ok[mkt] and not self.breaker(mkt, t) and self.pause_reason(t) is None

    # --- routes -------------------------------------------------------------
    def _dex(self, tok, q, m):
        p = self.p
        if p.dex_revert.get(tok):
            return None
        depth = p.dex_depth[tok] * p.dex_drain.get(tok, 1.0)
        if abs(1 - m[tok]) > 0.01:
            depth *= p.dex_stress
        if depth <= 1.0:
            return None
        impact = 0.01 * q * m[tok] / depth
        if impact >= 0.5:
            return None
        return q * m[tok] / m['GHO'] * (1 - p.dex_fee - impact) * (1 - p.dex_discount.get(tok, 0.0))

    def _primary(self, tok, q, head):
        p = self.p
        if tok == 'DAI':
            if q <= p.psm_headroom and not self.gsm_frozen['USDC'] and q <= head['USDC']:
                return q * (1 - p.gsm_fee), p.gas_psm_leg + p.gas_gsm_leg, 'psm+gsm', ('USDC', q)
            return None, p.gas_psm_leg, 'psm+gsm', None
        if not self.gsm_frozen[tok] and q <= head[tok]:
            return q * (1 - p.gsm_fee), p.gas_gsm_leg, 'gsm', (tok, q)
        return None, p.gas_gsm_leg, 'gsm', None

    def _leg(self, tok, q, m, head, min_out):
        """Primary then backup, each against the leg's oracle minimum (Q-250). Returns (out, gas, route,
        primary_failed) with out None when neither route delivers min_out."""
        p = self.p
        out, gas, route, use = self._primary(tok, q, head)
        if out is not None and out >= min_out:
            head[use[0]] -= use[1]
            return out, gas, route, False
        out2 = self._dex(tok, q, m)
        gas += p.gas_dex_leg
        if out2 is not None and out2 >= min_out:
            return out2, gas, 'dex', True
        return None, gas, 'none', True

    def _probe_leg(self, tok, q, m, head):
        out, _, _, use = self._primary(tok, q, head)
        if out is not None:
            head[use[0]] -= use[1]
            return out
        return self._dex(tok, q, m)

    def _buy(self, D, m, bound):
        """Buy leg for USDC debt: GSM buy then DEX, each within maxGhoIn = bound (SPEC-LIQ-015)."""
        p = self.p
        if not self.gsm_frozen['USDC'] and D <= self.gsm_head['USDC']:
            g = D * (1 + p.gsm_buy_fee)
            if g <= bound:
                return g
        depth = p.dex_depth['USDC'] * (p.dex_stress if abs(1 - m['USDC']) > 0.01 else 1.0)
        g = D * m['USDC'] / m['GHO'] * (1 + p.dex_fee + 0.01 * D / depth)
        return g if g <= bound else None

    # --- liquidation ----------------------------------------------------------
    def hf(self, a, px=None, dpx=None):
        px = self.spx if px is None else px
        dpx = self.dpx if dpx is None else dpx
        td = 0.0
        for r_, d in a.debt.items():
            td += d * dpx[r_]
        if td <= 0:
            return float('inf')
        cv = 0.0
        for k, u in a.coll.items():
            cv += u * px[k]
        return cv * self.cf / td

    def size(self, a, mkt, res):
        """Aave V4 sizing over every reserve of the account (LiquidationLogic @a3ef63e), in USD."""
        p, cf = self.p, self.cf
        TD = sum(d * self.dpx[r] for r, d in a.debt.items())
        hfv = sum(u * self.spx[k] for k, u in a.coll.items()) * cf / TD
        b = p.bonus(hfv)
        LB = 1 + b
        pd = self.dpx[res]
        debt_v = a.debt[res] * pd
        C = a.coll[mkt] * self.spx[mkt]
        to_target = TD * (p.target_hf - hfv) / (p.target_hf - LB * cf)
        repay = min(to_target, debt_v)
        if debt_v - repay < p.dust_usd:
            repay = debt_v
        seize = repay * LB
        empty = False
        if seize >= C:
            seize, repay, empty = C, C / LB, True
        elif C - seize < p.dust_usd and repay < debt_v:
            if C / LB <= debt_v:
                seize, repay, empty = C, C / LB, True
            else:
                repay, seize = debt_v, debt_v * LB
        return b, repay / pd, seize, empty, hfv

    def gas_usd(self, gas, t_idx):
        g = self.gwei_path[t_idx] if self.gwei_path else self.p.gwei
        return gas * g * 1e-9 * self.p.eth_usd

    def _block(self, a, reason):
        self.r['blocked_steps'][reason] += 1
        self.r['blocked_accts'][reason].add(a.aid)

    def _budget_room(self, mkt, t):
        p = self.p
        used = sum(x for _, _, x in self.draws)
        used_m = sum(x for _, mk, x in self.draws if mk == mkt)
        sub = max(p.min_market_cap, math.floor(p.budget_per_day / len(MARKETS)))
        return max(0.0, min(p.budget_per_call, p.budget_per_day - used, sub - used_m, self.budget))

    def _route_failure(self, mkt, t):
        dq = self.route_fail_t[mkt]
        dq.append((t, 1))
        if len(dq) >= 3:
            self.latch_until[mkt] = t + 6 * H

    def _attempt(self, a, mkt, res, t, i, m, extra, perm):
        """One routed liquidation call. Returns a dict or a failure reason string."""
        p = self.p
        b, D, seize, empty, hfv = self.size(a, mkt, res)
        px, pd = self.spx[mkt], self.dpx[res]
        if D * pd > p.flash_cap:
            return 'flash'
        units = seize / px
        V = seize                       # oracle value of the seized units in GHO (Pgho = 1)
        cbuy = p.buy_slippage if res == 'USDC' else 0.0
        s = p.s_eff(b, cbuy)
        gas = p.gas_base
        if res == 'USDC':
            bound = D * pd * (1 + cbuy)
            G = self._buy(D, m, bound)
            gas += p.gas_buy_leg
            if G is None:
                return 'buy'
            Gcov = min(G, bound)
        else:
            G = Gcov = D
        tok0, tok1 = MARKETS[mkt]
        P = self.pool[mkt]
        x, y = units / 2 / math.sqrt(P), units / 2 * math.sqrt(P)
        ev = self.tev
        legs = [(tok, q, q * min(ev[tok].q, 1.0)) for tok, q in ((tok0, x), (tok1, y))]
        n = sum(1 for tok, q, _ in legs if tok != 'GHO')
        s_leg = min(0.9999, s + (min(p.max_shortfall_bps, extra) if extra else 0.0))
        head = dict(self.gsm_head)
        R, used, prim_fail = 0.0, [], False
        for tok, q, vleg in legs:
            if tok == 'GHO':
                R += q
                continue
            mo = max(1e-18, vleg * (1 - s_leg) - p.floor_rounding / n)
            out, g, route, pf = self._leg(tok, q, m, head, mo)
            gas += g
            prim_fail = prim_fail or pf
            if out is None:
                return 'route' if extra else 'floor'
            R += out
            used.append(route)
        min_gho = max(0.0, V * (1 - s) - p.floor_rounding)
        shortfall = max(0.0, min_gho - R)
        if shortfall > extra * V + 1e-9:
            return 'floor'
        Rp = R + shortfall
        Bd = max(0.0, Gcov - Rp)
        K = 0.0
        if Bd > 0:
            room = 0.0 if (perm or s == 0) else self._budget_room(mkt, t)
            if Bd > room:
                K, Bd = Bd, 0.0         # the caller adds its own GHO (keeperGho) instead
        S = max(0.0, Rp - G)
        A = min(math.floor(max(0.0, V - Gcov) * p.avana_share * 1e18) / 1e18, S)
        keeper_out = K + Rp + Bd - G - A
        if keeper_out < -1e-9:
            return 'floor'
        if shortfall > 0:
            gas += p.gas_topup
        return dict(b=b, D=D, seize=seize, empty=empty, units=units, V=V, R=R, Rp=Rp, Bd=Bd, K=K, A=A,
                    G=G, shortfall=shortfall, keeper_out=keeper_out, gas=gas, head=head, used=used,
                    prim_fail=prim_fail, x=x, y=y, hf=hfv)

    def _probe(self, a, mkt, res, m):
        """reportRecoveryShortfall: liquidation at minOut = 1; None if a route reverts (no evidence)."""
        p = self.p
        b, D, seize, empty, _ = self.size(a, mkt, res)
        units = seize / self.spx[mkt]
        cbuy = p.buy_slippage if res == 'USDC' else 0.0
        s = p.s_eff(b, cbuy)
        if res == 'USDC' and self._buy(D, m, D * self.dpx[res] * (1 + cbuy)) is None:
            return None
        tok0, tok1 = MARKETS[mkt]
        P = self.pool[mkt]
        head = dict(self.gsm_head)
        R = 0.0
        for tok, q in ((tok0, units / 2 / math.sqrt(P)), (tok1, units / 2 * math.sqrt(P))):
            if tok == 'GHO':
                R += q
                continue
            out = self._probe_leg(tok, q, m, head)
            if out is None:
                return None
            R += out
        return R, max(0.0, seize * (1 - s) - p.floor_rounding)

    def inkind_open(self, mkt, t):
        return t < self.inkind_until[mkt]

    def _report(self, a, mkt, res, t, m):
        p = self.p
        pr = self._probe(a, mkt, res, m)
        if pr is None or pr[0] >= pr[1]:
            self.r['reports_failed'] += 1
            return
        self.r['reports'] += 1
        if self.short_since[mkt] is None or self.short_last[mkt] + H < t:
            self.short_since[mkt] = t
        self.short_last[mkt] = t
        self._route_failure(mkt, t)
        if p.inkind_trigger and t - self.short_since[mkt] >= p.inkind_auto_delay and not self.inkind_open(mkt, t):
            self.inkind_until[mkt] = t + p.inkind_expiry
            self.r['auto_inkind'] += 1
            if self.r['first_inkind'] is None:
                self.r['first_inkind'] = t

    def _manual_inkind(self, mkt, t):
        p = self.p
        if p.inkind_manual_delay is None:
            return
        if self.manual_at[mkt] is None:
            self.manual_at[mkt] = t + p.inkind_manual_delay
        elif t >= self.manual_at[mkt] and not self.inkind_open(mkt, t):
            self.inkind_until[mkt] = t + p.inkind_expiry
            self.manual_at[mkt] = None
            self.r['manual_inkind'] += 1
            if self.r['first_inkind'] is None:
                self.r['first_inkind'] = t

    def liquidate(self, a, mkt, res, t, i, m, perm=False):
        p = self.p
        out = self._attempt(a, mkt, res, t, i, m, 0.0, perm)
        if isinstance(out, str) and out == 'floor' and p.keeper_topup:
            out = self._attempt(a, mkt, res, t, i, m, p.max_shortfall_bps, perm)
            if isinstance(out, dict):
                self.r['topup_calls'] += 1
        if isinstance(out, str):
            if perm:
                return False
            if out in ('route', 'floor'):
                self._route_failure(mkt, t)
                if self.inkind_open(mkt, t):
                    return self._inkind(a, mkt, res, t, i, m)
                self._report(a, mkt, res, t, m)
                self._manual_inkind(mkt, t)
            self._block(a, out)
            return False
        gas_cost = self.gas_usd(out['gas'], i)
        pnl = out['keeper_out'] - out['shortfall'] - out['K'] - gas_cost
        if (perm or p.keeper_mode == 'rational') and pnl < 0:
            if not perm:
                self._block(a, 'unprofitable')
            return False
        if out['K']:
            self.r['budget_refused'] += 1
        if out['Bd']:
            self.draws.append((t, mkt, out['Bd']))
            self.budget -= out['Bd']
            self.r['budget_draw'] += out['Bd']
            self.r['budget_draws_n'] += 1
            self.r['budget_by_mkt'][mkt] += out['Bd']
            self.r['max_mkt_window'] = max(self.r['max_mkt_window'],
                                           sum(x for _, mk, x in self.draws if mk == mkt))
        self.gsm_head = out['head']
        for route in out['used']:
            self.r['routes'][route] = self.r['routes'].get(route, 0) + 1
        if out['prim_fail']:
            self._route_failure(mkt, t)
        self.short_since[mkt] = None             # REQ-SWAP-103: a routed liquidation clears the run
        self.manual_at[mkt] = None
        tok0, tok1 = MARKETS[mkt]
        mkt_value = out['x'] * m[tok0] + out['y'] * m[tok1]
        self._commit(a, mkt, res, t, out['D'], out['units'], out['empty'], mkt_value, m, out['hf'])
        self.r['avana_fee'] += out['A']
        self.r['shortfall_paid'] += out['shortfall']
        self.r['keeper_gross'] += out['keeper_out']
        self.r['gas'] += gas_cost
        self.r['keeper_pnl'] += pnl
        self.r['keeper_pnl_each'].append(pnl)
        if perm:
            self.r['perm_liq'] += 1
        elif pnl < 0:
            self.r['reimburse'] += -pnl
        return True

    def _inkind(self, a, mkt, res, t, i, m):
        p = self.p
        b, D, seize, empty, hfv = self.size(a, mkt, res)
        cost = D * (m['USDC'] / m['GHO'] if res == 'USDC' else 1.0)
        if self.keeper_gho < cost:
            self._block(a, 'keeper_gho')
            return False
        units = seize / self.spx[mkt]
        tok0, tok1 = MARKETS[mkt]
        P = self.pool[mkt]
        x, y = units / 2 / math.sqrt(P), units / 2 * math.sqrt(P)
        val = x * min(self.tev[tok0].q, 1.0) + y * min(self.tev[tok1].q, 1.0)
        cap = D * self.dpx[res] * (1 + b)
        share = 1.0 if val <= cap else cap / val
        gas_cost = self.gas_usd(p.gas_inkind, i)
        kept = (x * m[tok0] + y * m[tok1]) * share
        pnl = kept - cost - gas_cost
        if p.keeper_mode == 'rational' and pnl < 0:
            self._block(a, 'unprofitable')
            return False
        self.keeper_gho -= cost
        self._commit(a, mkt, res, t, D, units * share, empty, kept, m, hfv, remainder=units * (1 - share))
        self.r['inkind'] += 1
        self.r['gas'] += gas_cost
        self.r['keeper_pnl'] += pnl
        self.r['keeper_pnl_each'].append(pnl)
        if pnl < 0:
            self.r['reimburse'] += -pnl
        return True

    def _commit(self, a, mkt, res, t, D, units, empty, mkt_value, m, hfv, remainder=0.0):
        self.r['liq'] += 1
        self.r['first_liq_mkt'].setdefault(mkt, t)
        self.r['liq_hf'].append(hfv)
        self.r['liq_repay'].append(D)
        self.r['liq_t'].append(t)
        dm = m['USDC'] / m['GHO'] if res == 'USDC' else 1.0
        loss = mkt_value - D * dm * m['GHO']
        self.r['borrower_loss'] += loss
        thf = self.hf(a, {k: self.tpx[k] for k in MARKETS}, {'GHO': m['GHO'], 'USDC': m['USDC']})
        if thf >= 1.0:
            self.r['forced_healthy'] += 1
            self.r['forced_healthy_loss'] += max(0.0, loss)
        a.debt[res] -= D
        a.coll[mkt] -= units + remainder
        if empty or a.coll[mkt] < 1e-9:
            a.coll[mkt] = 0.0
        sd = self.seized_t[mkt]
        sd.append((t, units))
        if sum(u for _, u in sd) > 0.2 * max(1e-9, sum(x.coll.get(mkt, 0.0) for x in self.open)):
            self.latch_until[mkt] = t + 6 * H
        if all(u <= 1e-9 for u in a.coll.values()):
            for r_, d in a.debt.items():
                if d > 1e-9:
                    self.r['deficit'] += d
                    self.hub_deficit[r_] += d
                    c = min(d, self.reserve[r_])
                    self.reserve[r_] -= c
                    self.r['reserve_draw'] += c
                    self.r['uncovered'] += d - c
                a.debt[r_] = 0.0
        for r_ in a.debt:
            if a.debt[r_] < 1e-9:
                a.debt[r_] = 0.0
        if all(d <= 0 for d in a.debt.values()):
            a.closed = True

    # --- actors -------------------------------------------------------------
    def keepers_up(self, t):
        pd = self.p.primary_down
        if pd is None or not (pd[0] <= t < pd[1]):
            return True
        sd = self.p.standby_keeper_delay
        return sd is not None and t >= pd[0] + sd

    def _view_hf(self, a):
        px = {k: self.o[k]['A'] for k in MARKETS}
        return self.hf(a, px, {'GHO': 1.0, 'USDC': self.do['A']})

    def _borrowers(self, t, m):
        p = self.p
        reason = self.pause_reason(t)
        for a in self.open:
            if a.closed or not a.active or a.attacker:
                continue
            hf = self._view_hf(a)
            if a.pending_at is None:
                if hf < p.warn_hf:
                    a.pending_at = t + a.delay
                continue
            if t < a.pending_at:
                continue
            if hf >= p.warn_hf:
                a.pending_at = None
                continue
            mkt = max(a.coll, key=lambda k: a.coll[k])
            if a.topup and a.coll[mkt] > 0:
                st = self.o[mkt]['st']
                if st not in ('Live', 'Drifting') or reason == 'MintPathSuspect':
                    self.r['topups_refused'] += 1
                    continue                                 # retries next step
                rescue_only = reason == 'General' or self.breaker(mkt, t)
                target = p.min_open_hf if rescue_only else p.react_target_hf
                td = a.debt.get('GHO', 0.0) + a.debt.get('USDC', 0.0) * self.do['A']
                a.coll[mkt] += (target - hf) * td / self.cf / self.o[mkt]['A']
                self.r['topups'] += 1
                a.pending_at = None
                continue
            a.pending_at = None
            scale = 1 - hf / p.react_target_hf
            for r_ in a.debt:
                x = a.debt[r_] * scale
                a.debt[r_] -= x
                self.r['repaid_by_borrowers'] += x * (m['USDC'] if r_ == 'USDC' else 1.0)
            if all(d <= 1e-9 for d in a.debt.values()):
                a.closed = True

    def _attack(self, t, m):
        at = self.p.attack
        if not at or at.get('done') or t < at['start']:
            return
        p = self.p
        headroom = p.credit_line - sum(sum(a.debt.values()) for a in self.accts if not a.closed)
        for mkt in at.get('markets', MARKETS):
            if not self.borrow_open(mkt, t) or headroom <= 0:
                continue
            px, tp = self.spx[mkt], self.tpx[mkt]
            per_usd = px * p.cf / p.min_open_hf / tp
            if per_usd <= 1.0:
                continue
            spend = min(at['usd'], headroom / per_usd)
            units = spend / tp
            debt = units * px * p.cf / p.min_open_hf
            self.accts.append(Account(10_000 + len(self.accts), {mkt: units}, {'GHO': debt}, debt, False, 0,
                                      attacker=True))
            self.r['attack_borrow'] += debt
            self.r['attack_cost'] += spend
            headroom -= debt
            at['done'] = True

    def _targets(self, a):
        mk = [k for k, u in a.coll.items() if u > 0]
        rs = [r_ for r_ in ('GHO', 'USDC') if a.debt.get(r_, 0) > 0]
        return mk, rs

    def _keepers(self, t, i, m):
        p = self.p
        up = self.keepers_up(t)
        for a in self.open:
            if a.closed:
                continue
            for _ in range(4):
                if a.closed or self.hf(a) >= 1:
                    break
                mk, rs = self._targets(a)
                ok_m = [k for k in mk if self.liq_ok[k]]
                ok_r = [r_ for r_ in rs if r_ == 'GHO' or self.debt_liq_ok]
                if not ok_m or not ok_r:
                    if not ok_m:
                        kinds = [self.block_kind[k] for k in mk]
                        self._block(a, 'disagree' if 'disagree' in kinds else
                                    ('alt_age' if 'alt_age' in kinds else 'stale'))
                    else:
                        self._block(a, 'debt_stale')
                    break
                grace = any(self.in_grace[k] for k in mk) or ('USDC' in rs and self.debt_grace)
                if grace and self.hf(a) >= p.grace_hf:
                    self._block(a, 'grace')
                    break
                mkt = max(ok_m, key=lambda k: a.coll[k] * self.spx[k])
                res = ok_r[0]
                if up:
                    if not self.liquidate(a, mkt, res, t, i, m):
                        break
                elif p.permissionless:
                    if not self.liquidate(a, mkt, res, t, i, m, perm=True):
                        self._block(a, 'keeper_down')
                        break
                else:
                    self._block(a, 'keeper_down')
                    break

    def _accrue(self):
        g = math.exp(self.p.apr * self.p.step / YEAR)
        self.open = [a for a in self.accts if not a.closed]
        for a in self.open:
            for r_ in a.debt:
                a.debt[r_] *= g

    def _track(self, t, m):
        tpx = self.tpx
        mu, mg = m['USDC'], m['GHO']
        uw = self.underwater_since
        for a in self.open:
            if a.closed:
                uw.pop(a.aid, None)
                continue
            val = 0.0
            for k, u in a.coll.items():
                val += u * tpx[k]
            dv = 0.0
            for r_, d in a.debt.items():
                dv += d * (mu if r_ == 'USDC' else mg)
            if val < dv:
                s = uw.setdefault(a.aid, t)
                if (t - s) / H > self.r['max_true_underwater_h']:
                    self.r['max_true_underwater_h'] = (t - s) / H
            else:
                uw.pop(a.aid, None)
        for mkt in MARKETS:
            if self.borrow_open(mkt, t):
                if self.spx[mkt] > 1.01 * self.tpx[mkt]:
                    self.r['borrow_stale_steps'][mkt] += 1
                if self.tpx[mkt] < self.p.band_low - 0.01:
                    self.r['borrow_below_band_steps'][mkt] += 1

    def run(self):
        p = self.p
        m = None
        for i in range(self.n):
            t = i * p.step
            m = {tok: self.paths[tok][i] for tok in TOKENS}
            self._update_market(t, m)
            self._accrue()
            self._attack(t, m)
            self._borrowers(t, m)
            self._keepers(t, i, m)
            self._track(t, m)
        r = self.r
        open_short = 0.0
        for a in self.accts:
            if not a.closed:
                val = sum(u * self.tpx[k] for k, u in a.coll.items())
                dv = sum(d * (m['USDC'] / m['GHO'] if r_ == 'USDC' else 1.0) for r_, d in a.debt.items())
                open_short += max(0.0, dv - val / m['GHO'])
        r['unrecorded'] = open_short
        r['bad_debt'] = r['deficit'] + open_short
        r['blocked_n'] = {k: len(v) for k, v in r['blocked_accts'].items()}
        r['blocked_any'] = len(set().union(*r['blocked_accts'].values()))
        r['debt_end'] = sum(sum(a.debt.values()) for a in self.accts if not a.closed)
        r['debt_start'] = sum(a.debt0 for a in self.accts)
        return r


# ---------------------------------------------------------------------------
# Running, aggregation, output, checks
# ---------------------------------------------------------------------------

SEEDS = (11, 22, 33)
SUM_KEYS = ('deficit', 'reserve_draw', 'uncovered', 'budget_draw', 'budget_refused', 'liq', 'inkind', 'perm_liq',
            'borrower_loss', 'keeper_pnl', 'gas', 'avana_fee', 'reimburse', 'repaid_by_borrowers', 'blocked_any',
            'attack_borrow', 'attack_cost', 'unrecorded', 'max_true_underwater_h', 'budget_draws_n',
            'shortfall_paid', 'topup_calls', 'reports', 'reports_failed', 'auto_inkind', 'manual_inkind',
            'standby_switches', 'topups', 'topups_refused', 'forced_healthy', 'forced_healthy_loss',
            'grace_starts', 'cached_entries', 'skipped_cached')


def run_many(p: Params, path_fn, seeds=SEEDS, outage=None, gwei_fn=None, accounts_fn=None):
    """path_fn(rng) -> paths. Returns means over seeds plus worst-seed bad debt."""
    outs = []
    for s in seeds:
        paths = path_fn(random.Random(s * 1000 + 1))
        gp = gwei_fn(len(paths['USDC'])) if gwei_fn else None
        accts = accounts_fn(p, random.Random(s)) if accounts_fn else None
        pp = replace(p, attack=dict(p.attack) if p.attack else None)
        outs.append(Sim(pp, paths, s, accounts=accts, outage=outage, gwei_path=gp).run())
    agg = {k: sum(o[k] for o in outs) / len(outs) for k in SUM_KEYS}
    agg['bad_debt'] = sum(o['bad_debt'] for o in outs) / len(outs)
    agg['bad_debt_max'] = max(o['bad_debt'] for o in outs)
    agg['debt_start'] = outs[0]['debt_start']
    agg['blocked_n'] = {b: sum(o['blocked_n'][b] for o in outs) / len(outs) for b in BLOCK_REASONS}
    agg['blocked_h'] = {b: sum(o['blocked_steps'][b] for o in outs) / len(outs) * p.step / H for b in BLOCK_REASONS}
    pnl = [x for o in outs for x in o['keeper_pnl_each']]
    agg['keeper_pnl_min'] = min(pnl) if pnl else 0.0
    lt = [min(o['liq_t']) for o in outs if o['liq_t']]
    agg['first_liq_days'] = min(lt) / DAY if lt else float('nan')
    agg['liq_hf_min'] = min([x for o in outs for x in o['liq_hf']] or [float('nan')])
    agg['routes'] = {}
    for o in outs:
        for k, v in o['routes'].items():
            agg['routes'][k] = agg['routes'].get(k, 0) + v / len(outs)
    agg['state_steps'] = outs[0]['state_steps']
    agg['paused_h'] = {k: sum(o['paused_steps'][k] for o in outs) / len(outs) * p.step / H for k in MARKETS}
    agg['dis_h'] = {k: sum(o['dis_steps'][k] for o in outs) / len(outs) * p.step / H for k in MARKETS}
    agg['borrow_stale_h'] = {k: max(o['borrow_stale_steps'][k] for o in outs) * p.step / H for k in MARKETS}
    agg['borrow_below_band_h'] = {k: max(o['borrow_below_band_steps'][k] for o in outs) * p.step / H for k in MARKETS}
    agg['budget_by_mkt_max'] = max(max(o['budget_by_mkt'].values()) for o in outs)
    agg['max_mkt_window'] = max(o['max_mkt_window'] for o in outs)
    fi = [o['first_inkind'] for o in outs if o['first_inkind'] is not None]
    agg['first_inkind_h'] = min(fi) / H if fi else float('nan')
    agg['debt_states'] = outs[0]['debt_states']
    agg['first_liq_mkt_h'] = {k: min([o['first_liq_mkt'][k] for o in outs if k in o['first_liq_mkt']] or
                                     [float('nan')]) / H for k in MARKETS}
    agg['n'] = len(outs)
    return agg


def blk_summary(agg):
    parts = [f"{k}:{agg['blocked_n'][k]:.0f}" for k in BLOCK_REASONS if agg['blocked_n'][k] > 0]
    return ' '.join(parts) if parts else '-'


STD_HEAD = ['bad_debt', 'bad_max', 'deficit', 'reserve', 'budget', 'liq', 'inkind', 'perm', 'blk_accts',
            'blocked_by_reason', 'borr_loss', 'keeper_pnl', 'reimb']


def std_row(agg):
    return [f"{agg['bad_debt']:,.0f}", f"{agg['bad_debt_max']:,.0f}", f"{agg['deficit']:,.0f}",
            f"{agg['reserve_draw']:,.0f}", f"{agg['budget_draw']:,.2f}", f"{agg['liq']:.1f}",
            f"{agg['inkind']:.1f}", f"{agg['perm_liq']:.1f}", f"{agg['blocked_any']:.1f}", blk_summary(agg),
            f"{agg['borrower_loss']:,.0f}", f"{agg['keeper_pnl']:,.0f}", f"{agg['reimburse']:,.0f}"]


def table(headers, rows, title=None):
    if title:
        print(f"\n{title}")
    w = [max(len(str(h)), *(len(str(r[i])) for r in rows)) for i, h in enumerate(headers)]
    print('  '.join(str(h).rjust(w[i]) for i, h in enumerate(headers)))
    print('  '.join('-' * w[i] for i in range(len(headers))))
    for r in rows:
        print('  '.join(str(c).rjust(w[i]) for i, c in enumerate(r)))


PRFS = (0.20, 0.30, 0.40)


class Checks:
    def __init__(self, name):
        self.name = name
        self.bad = []
        self.counts = {'Holds': 0, 'Counterexample': 0}

    def check(self, pid, text, holds, expect='Holds', detail=''):
        res = 'Holds' if holds else 'Counterexample'
        self.counts[res] += 1
        mark = 'ok' if res == expect else 'UNEXPECTED'
        print(f"[{pid}] {res} (expected {expect}, {mark}) - {text}" + (f"\n    {detail}" if detail else ''))
        if res != expect:
            self.bad.append(pid)

    def finish(self):
        c = self.counts
        print(f"\n{self.name}: {c['Holds']} Holds, {c['Counterexample']} Counterexample")
        if self.bad:
            print(f"{self.name}: results differ from README for {', '.join(self.bad)}")
            sys.exit(1)
        print(f"{self.name}: all results match README.")


# ---------------------------------------------------------------------------
# Self-tests
# ---------------------------------------------------------------------------

def _selftest():
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(here, '..', 'z3', 'aave-risk'))
    ck = Checks('_simcore')
    try:
        import _v4ref as v4
    except Exception as e:  # pragma: no cover
        print(f'cannot import z3/aave-risk/_v4ref.py ({e})')
        v4 = None
    worst = 0.0
    branches = {}
    if v4 is not None:
        rng = random.Random(5)
        WAD, RAY, BPS = 10**18, 10**27, 10**4
        for _ in range(600):
            prf = rng.choice((0.10, 0.20, 0.30, 0.40))
            p = Params(prf=prf, min_bonus=rng.choice([0.0, 0.005, 0.01, 0.02, 0.03]),
                       max_bonus=rng.choice([0.03, 0.05, 0.08]), target_hf=rng.choice([1.05, 1.10, 1.20]))
            debt = rng.uniform(1000, 200_000)
            hf_t = rng.uniform(0.80, 0.999) if rng.random() < 0.7 else rng.uniform(0.5, 1.3) * p.cf
            px = rng.uniform(0.85, 1.0)
            units = debt * hf_t / (p.cf * px)
            price8 = round(px * 1e8)
            px_i = price8 / 1e8
            sim = Sim.__new__(Sim)
            sim.p, sim.cf = p, p.cf
            sim.spx, sim.dpx = {'USDC/USDT': px_i}, {'GHO': 1.0}
            acct = Account(0, {'USDC/USDT': units}, {'GHO': debt}, debt, False, 0)
            b, repay, seize, empty, _ = Sim.size(sim, acct, 'USDC/USDT', 'GHO')
            cf_bps = round(p.cf * BPS)
            units_w = int(units * 1e18)
            debt_w = int(debt * 1e18)
            coll_val = units_w * price8
            tdv = debt_w * RAY * 10**8
            hf_w = (cf_bps * coll_val * (WAD // BPS)) * RAY // tdv
            lbf = round(p.min_bonus / p.max_bonus * BPS) if p.max_bonus else 0
            out = v4.liquidation_amounts(hub=v4.Hub(10**30, 10**30), supplied_shares=units_w, cdec=18,
                                         cprice=price8, ds=debt_w, prem_ray=0, idx=RAY, tdv_ray=tdv, ddec=18,
                                         dprice=10**8, cover=10**40, cf=cf_bps,
                                         hf_for_max=int(p.hf_for_max_bonus * WAD), lbf=lbf,
                                         max_lb=round((1 + p.max_bonus) * BPS), thf=int(p.target_hf * WAD),
                                         hf=hf_w)
            ref_repay = out['paid'] / 1e18
            ref_seize = out['coll_shares'] / 1e18 * px_i
            rel = max(abs(ref_repay - repay) / debt, abs(ref_seize - seize) / debt)
            branches[out['branch']] = branches.get(out['branch'], 0) + 1
            worst = max(worst, rel)
    # SIM-00A verifies: Q-072, Q-152, Q-179, Q-185
    ck.check('SIM-00A', 'float Aave V4 sizing (repay, seized value) matches the integer reference '
             'z3/aave-risk/_v4ref.py within 0.05% of debt on 600 random cases', v4 is not None and worst < 5e-4,
             detail=f'worst relative difference {worst:.2e}; reference branches hit {branches}')
    p = Params(n_accounts=60, usdc_debt_share=0.3)
    mk = lambda rng: {**flat_paths(24, p.step, rng), 'USDT': piecewise([(0, 1), (6, 0.8)], 24, p.step, rng, 0.05)}
    a1 = run_many(p, mk, seeds=(1,))
    a2 = run_many(p, mk, seeds=(1,))
    same = all(a1[k] == a2[k] for k in ('bad_debt', 'liq', 'borrower_loss', 'keeper_pnl', 'blocked_any'))
    # SIM-00B verifies: Q-152
    ck.check('SIM-00B', 'same seed gives identical results (reproducibility)', same,
             detail=f"liq={a1['liq']}, borrower_loss={a1['borrower_loss']:.4f}")
    ck.finish()


if __name__ == '__main__':
    _selftest()
